(*XXX
Patterns:
  => loops should avoid absorbing the whole continuation...
     (detect when the continuation does not loop anymore and close
      the loop at this point)
  => should have special code for switches that include the preceding
     if statement when possible
  => if e1 then {if e2 then P else Q} else {if e3 then P else Q}
  => if e then return e1; return e2
  => if e then var x = e1; else var x = e2;
  => while (true) {.... if (e) continue; break; }

- CLEAN UP!!!

- Inlining? (Especially of functions that are used only once!)

- Can we avoid spurious conversions from boolean to integers???
  ===> explicit conversion to boolean; specialized "if" that operates
       on booleans directly

- scalable generation of caml_apply functions
  ==> use curry functions as the ocaml compilers does
  ==> we could generate explit closures in the code
*)

let compact = false

(****)

open Util
open Code
module J = Javascript

(****)

let rec list_group_rec f l b m n =
  match l with
    [] ->
      List.rev ((b, List.rev m) :: n)
  | a :: r ->
      let fa = f a in
      if fa = b then
        list_group_rec f r b (a :: m) n
      else
        list_group_rec f r fa [a] ((b, List.rev m) :: n)

let list_group f l =
  match l with
    []     -> []
  | a :: r -> list_group_rec f r (f a) [a] []

(****)

module Ctx = struct
  type t =
    { var_stream : Var.stream;
      mutable blocks : Code.block Util.IntMap.t;
      live : int array;
      mutated_vars : Freevars.VarSet.t Util.IntMap.t }

  let fresh_var ctx =
    let (x, stream) = Var.next ctx.var_stream in
    (x, {ctx with var_stream = stream})

  let initial b l v =
    { var_stream = Var.make_stream (); blocks = b; live = l; mutated_vars = v }

  let used_once ctx x = ctx.live.(Var.idx x) <= 1
end

let add_names = Hashtbl.create 101

let var x = J.EVar (Var.to_string x)
let int n = J.ENum (float n)
let one = int 1
let zero = int 0
let addr pc =
  if not compact then
    Format.sprintf "f%d" pc
  else begin
    try
      Hashtbl.find add_names pc
    with Not_found ->
      let x = Var.to_string (Var.fresh ()) in
      Hashtbl.replace add_names pc x;
      x
  end
let bool e = J.ECond (e, one, zero)
let boolnot e = J.ECond (e, zero, one)

(****)

let same_custom x y =
  Obj.field x 0 = Obj.field (Obj.repr y) 0

let rec constant x =
  if Obj.is_block x then begin
    let tag = Obj.tag x in
    if tag = Obj.string_tag then
      J.ENew (J.EVar ("MlString"), Some [J.EStr (Obj.magic x : string)])
    else if tag = Obj.double_tag then
      J.ENum (Obj.magic x : float)
    else if tag = Obj.double_array_tag then begin
      let a = (Obj.magic x : float array) in
      J.EArr (Some (int Obj.double_array_tag) ::
              Array.to_list (Array.map (fun f -> Some (J.ENum f)) a))
    end else if tag = Obj.custom_tag && same_custom x 0l then
      J.ENum (Int32.to_float (Obj.magic x : int32))
    else if tag = Obj.custom_tag && same_custom x 0n then
      J.ENum (Nativeint.to_float (Obj.magic x : nativeint))
    else if tag = Obj.custom_tag && same_custom x 0L then
      J.ENum (Int64.to_float (Obj.magic x : int64))
    else if tag < Obj.no_scan_tag then begin
      let a = Array.init (Obj.size x) (fun i -> Obj.field x i) in
      J.EArr (Some (int tag) ::
              Array.to_list (Array.map (fun x -> Some (constant x)) a))
    end else
      assert false
  end else
    int (Obj.magic x : int)

(****)

(*
Some variables are constant:   x = 1
Some may change after effectful operations : x = y[z]

There can be at most one effectful operations in the queue at once

let (e, expr_queue) = ... in
flush_queue expr_queue e
*)

let const_p = 0
let mutable_p = 1
let mutator_p = 2
let flush_p = 3
let or_p p q = max p q
let is_mutable p = p >= mutable_p
let is_mutator p = p >= mutator_p

let access_queue queue x =
  try
    let res = List.assoc x queue in
    (res, List.remove_assoc x queue)
  with Not_found ->
    ((const_p, var x), queue)

let flush_queue expr_queue all l =
  let (instrs, expr_queue) =
    if all then (expr_queue, []) else
    List.partition (fun (y, (p, _)) -> is_mutable p) expr_queue
  in
  let instrs =
    List.map (fun (x, (_, ce)) ->
                J.Variable_statement
                  [Var.to_string x, Some ce]) instrs
  in
  (List.rev_append instrs l, expr_queue)

let flush_all expr_queue l = fst (flush_queue expr_queue true l)

let enqueue expr_queue prop x ce =
  let (instrs, expr_queue) =
    if is_mutator prop then begin
      flush_queue expr_queue (prop >= flush_p) []
    end else
      [], expr_queue
  in
  (instrs, (x, (prop, ce)) :: expr_queue)

(****)

type state =
  { all_succs : (int, IntSet.t) Hashtbl.t;
    succs : (int, int list) Hashtbl.t;
    backs : (int, IntSet.t) Hashtbl.t;
    preds : (int, int) Hashtbl.t;
    mutable loops : IntSet.t;
    mutable visited_blocks : IntSet.t;
    mutable interm_idx : int;
    ctx : Ctx.t; mutable blocks : Code.block Util.IntMap.t }

let get_preds st pc = try Hashtbl.find st.preds pc with Not_found -> 0
let incr_preds st pc = Hashtbl.replace st.preds pc (get_preds st pc + 1)
let decr_preds st pc = Hashtbl.replace st.preds pc (get_preds st pc - 1)

let (>>) x f = f x

(* This as to be kept in sync with the way we build conditionals
   and switches! *)
let fold_children blocks pc f accu =
  let block = IntMap.find pc blocks in
  match block.branch with
    Return _ | Raise _ | Stop ->
      accu
  | Branch (pc', _) | Poptrap (pc', _) ->
      f pc' accu
  | Cond (_, _, (pc1, _), (pc2, _)) | Pushtrap ((pc1, _), _, (pc2, _), _) ->
      accu >> f pc1 >> f pc2
  | Switch (_, a1, a2) ->
      let normalize a =
        a >> Array.to_list
          >> List.sort compare
          >> list_group (fun x -> x)
          >> List.map fst
          >> Array.of_list
      in
      accu >> Array.fold_right (fun (pc, _) accu -> f pc accu) (normalize a1)
           >> Array.fold_right (fun (pc, _) accu -> f pc accu) (normalize a2)

let rec build_graph st pc anc =
  if not (IntSet.mem pc st.visited_blocks) then begin
    st.visited_blocks <- IntSet.add pc st.visited_blocks;
    let anc = IntSet.add pc anc in
    let s = Code.fold_children st.blocks pc IntSet.add IntSet.empty in
    Hashtbl.add st.all_succs pc s;
    let backs = IntSet.inter s anc in
    Hashtbl.add st.backs pc backs;

    let s = fold_children st.blocks pc (fun x l -> x :: l) [] in
    let succs = List.filter (fun pc -> not (IntSet.mem pc anc)) s in
    Hashtbl.add st.succs pc succs;
    IntSet.iter (fun pc' -> st.loops <- IntSet.add pc' st.loops) backs;
    List.iter (fun pc' -> build_graph st pc' anc) succs;
    List.iter (fun pc' -> incr_preds st pc') succs
  end

let rec dominance_frontier_rec st pc visited grey =
  let n = get_preds st pc in
  let v = try IntMap.find pc visited with Not_found -> 0 in
  if v < n then begin
    let v = v + 1 in
    let visited = IntMap.add pc v visited in
    if v = n then begin
      let grey = IntSet.remove pc grey in
      let s = Hashtbl.find st.succs pc in
      List.fold_right
        (fun pc' (visited, grey) ->
           dominance_frontier_rec st pc' visited grey)
        s (visited, grey)
    end else begin
      (visited, if v = 1 then IntSet.add pc grey else grey)
    end
  end else
    (visited, grey)

let dominance_frontier st pc =
  snd (dominance_frontier_rec st pc IntMap.empty IntSet.empty)

(* Block of code that never continues (either returns, throws an exception
   or loops back) *)
let never_continue st (pc, _) frontier interm =
  not (IntSet.mem pc frontier || IntMap.mem pc interm)
    &&
  IntSet.is_empty (dominance_frontier st pc)

let rec resolve_node interm pc =
  try
    resolve_node interm (fst (IntMap.find pc interm))
  with Not_found ->
    pc

let resolve_nodes interm s =
  IntSet.fold (fun pc s' -> IntSet.add (resolve_node interm pc) s')
    s IntSet.empty

(****)

module VarSet = Set.Make (Code.Var)

let rec visit visited prev s m x l =
  if not (VarSet.mem x visited) then begin
    let visited = VarSet.add x visited in
    let y = Subst.VarMap.find x m in
    if Code.Var.compare x y = 0 then
      (visited, None, l)
    else if VarSet.mem y prev then begin
      let t = Code.Var.fresh () in
      (visited, Some (y, t), (x, t) :: l)
    end else if VarSet.mem y s then begin
      let (visited, aliases, l) = visit visited (VarSet.add x prev) s m y l in
      match aliases with
        Some (a, b) when Code.Var.compare a x = 0 ->
          (visited, None, (b, a) :: (x, y) :: l)
      | _ ->
          (visited, aliases, (x, y) :: l)
    end else
      (visited, None, (x, y) :: l)
  end else
    (visited, None, l)

let visit_all params args =
  let m = Subst.build_mapping params args in
  let s = List.fold_left (fun s x -> VarSet.add x s) VarSet.empty params in
  let (_, l) =
    VarSet.fold
      (fun x (visited, l) ->
         let (visited, _, l) = visit visited VarSet.empty s m x l in
         (visited, l))
      s (VarSet.empty, [])
  in
  l

let parallel_renaming ctx params args continuation queue =
  let l = List.rev (visit_all params args) in
  List.fold_left
    (fun continuation (y, x) ->
       fun queue ->
       let ((px, cx), queue) = access_queue queue x in
       let (st, queue) =
         let idx = Var.idx y in
         let len = Array.length ctx.Ctx.live in
         match if idx >= len then 2 else ctx.Ctx.live.(Var.idx y) with
           0 -> assert false
         | 1 -> enqueue queue px y cx
         | _ -> flush_queue queue (px >= flush_p)
                  [J.Variable_statement [Var.to_string y, Some cx]]
       in
       st @ continuation queue)
    continuation l queue

(****)

let prim_kinds = ["caml_int64_float_of_bits", const_p]

let rec translate_expr ctx queue e =
  match e with
    Const i ->
      (int i, const_p, queue)
  | Apply (x, l) ->
      let (args, prop, queue) =
        List.fold_right
          (fun x (args, prop, queue) ->
             let ((prop', cx), queue) =
               access_queue queue x in (cx :: args, or_p prop prop', queue))
          (x :: l) ([], mutator_p, queue)
      in
      (J.ECall (J.EVar (Format.sprintf "caml_call_%d" (List.length l)), args),
       prop, queue)
  | Direct_apply (x, l) ->
      let ((px, cx), queue) = access_queue queue x in
      let (args, prop, queue) =
        List.fold_right
          (fun x (args, prop, queue) ->
             let ((prop', cx), queue) =
               access_queue queue x in (cx :: args, or_p prop prop', queue))
          l ([], or_p px mutator_p, queue)
      in
      (J.ECall (cx, args), prop, queue)
  | Block (tag, a) ->
      let (contents, prop, queue) =
        List.fold_right
          (fun x (args, prop, queue) ->
             let ((prop', cx), queue) = access_queue queue x in
             (Some cx :: args, or_p prop prop', queue))
          (Array.to_list a) ([], const_p, queue)
      in
      (J.EArr (Some (int tag) :: contents), prop, queue)
  | Field (x, n) ->
      let ((px, cx), queue) = access_queue queue x in
      (J.EAccess (cx, int (n + 1)), or_p px mutable_p, queue)
  | Closure (args, ((pc, _) as cont)) ->
      let vars =
        Util.IntMap.find pc ctx.Ctx.mutated_vars
        >> Freevars.VarSet.elements
        >> List.map Var.to_string
      in
      let cl =
        J.EFun (None, List.map Var.to_string args,
                compile_closure ctx cont)
      in
      let cl =
        if vars = [] then cl else
        J.ECall (J.EFun (None, vars,
                         [J.Statement (J.Return_statement (Some cl))]),
                 List.map (fun x -> J.EVar x) vars)
      in
      (cl, flush_p, queue)
  | Constant c ->
      (constant c, const_p, queue)
  | Prim (p, l) ->
      begin match p, l with
        Vectlength, [x] ->
          let ((px, cx), queue) = access_queue queue x in
          (J.EBin (J.Minus, J.EDot (cx, "length"), one), px, queue)
      | Array_get, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EAccess (cx, J.EBin (J.Plus, cy, one)),
           or_p mutable_p (or_p px py), queue)
      | C_call
            ("caml_array_get_addr"|"caml_array_get"|"caml_array_unsafe_get"),
            [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EAccess (cx, J.EBin (J.Plus, cy, one)),
                      or_p (or_p px py) mutable_p, queue)
      | C_call "caml_string_get", [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.ECall (J.EDot (cx, "charAt"), [cy]),
           or_p (or_p px py) mutable_p, queue)
      | C_call "caml_ml_string_length", [x] ->
          let ((px, cx), queue) = access_queue queue x in
          (J.EDot (cx, "length"), px, queue)
      | C_call name, l ->
Code.add_reserved_name name;  (*XXX HACK *)
          let prim_kind =
            try List.assoc name prim_kinds with Not_found -> mutator_p in
          let (args, prop, queue) =
            List.fold_right
              (fun x (args, prop, queue) ->
                 let ((prop', cx), queue) = access_queue queue x in
                 (cx :: args, or_p prop prop', queue))
              l ([], prim_kind, queue)
          in
          (J.ECall (J.EVar name, args), prop, queue)
      | Not, [x] ->
          let ((px, cx), queue) = access_queue queue x in
          (J.EBin (J.Minus, one, cx), px, queue)
      | Neg, [x] ->
          let ((px, cx), queue) = access_queue queue x in
          (J.EUn (J.Neg, cx), px, queue)
      | Add, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Plus, cx, cy), or_p px py, queue)
      | Sub, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Minus, cx, cy), or_p px py, queue)
      | Mul, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Mul, cx, cy), or_p px py, queue)
      | Div, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Div, cx, cy), or_p px py, queue)
      | Mod, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Mod, cx, cy), or_p px py, queue)
      | Offset n, [x] ->
          let ((px, cx), queue) = access_queue queue x in
          if n > 0 then
            (J.EBin (J.Plus, cx, int n), px, queue)
          else
            (J.EBin (J.Minus, cx, int (-n)), px, queue)
      | Lsl, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Lsl, cx, cy), or_p px py, queue)
      | Lsr, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Lsr, cx, cy), or_p px py, queue)
      | Asr, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Asr, cx, cy), or_p px py, queue)
      | Lt, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (bool (J.EBin (J.Lt, cx, cy)), or_p px py, queue)
      | Le, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (bool (J.EBin (J.Le, cx, cy)), or_p px py, queue)
      | Eq, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (bool (J.EBin (J.EqEqEq, cx, cy)), or_p px py, queue)
      | Neq, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (bool (J.EBin (J.NotEqEq, cx, cy)), or_p px py, queue)
      | IsInt, [x] ->
          let ((px, cx), queue) = access_queue queue x in
          (boolnot (J.EBin(J.InstanceOf, var x, J.EVar ("Array"))), px, queue)
      | And, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Band, cx, cy), or_p px py, queue)
      | Or, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Bor, cx, cy), or_p px py, queue)
      | Xor, [x; y] ->
          let ((px, cx), queue) = access_queue queue x in
          let ((py, cy), queue) = access_queue queue y in
          (J.EBin (J.Bxor, cx, cy), or_p px py, queue)
      | Ult, [x; y] ->
(*XXX*)
Format.eprintf "Primitive [ULT] not implemented!!!@.";
         (J.EQuote "ult", const_p, queue)
      | (Vectlength | Array_get | Not | Neg | IsInt | Add | Sub |
         Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr | Eq |
         Neq | Lt | Le | Ult | Offset _), _ ->
          assert false
      end
  | Variable x ->
      let ((px, cx), queue) = access_queue queue x in
(*XXXX??? mutable? *)
      (cx, or_p mutator_p px, queue)

and translate_instr ctx expr_queue instr =
  match instr with
    [] ->
      ([], expr_queue)
  | i :: rem ->
      let (st, expr_queue) =
        match i with
          Let (x, e) ->
            let (ce, prop, expr_queue) = translate_expr ctx expr_queue e in
            begin match ctx.Ctx.live.(Var.idx x) with
              0 -> flush_queue expr_queue (prop >= flush_p)
                     [J.Expression_statement ce]
            | 1 -> enqueue expr_queue prop x ce
            | _ -> flush_queue expr_queue (prop >= flush_p)
                     [J.Variable_statement [Var.to_string x, Some ce]]
            end
        | Set_field (x, n, y) ->
            let ((px, cx), expr_queue) = access_queue expr_queue x in
            let ((py, cy), expr_queue) = access_queue expr_queue y in
            flush_queue expr_queue false
              [J.Expression_statement
                 (J.EBin (J.Eq, J.EAccess (cx, int (n + 1)), cy))]
        | Offset_ref (x, n) ->
            let ((px, cx), expr_queue) = access_queue expr_queue x in
            flush_queue expr_queue false
              [J.Expression_statement
                 (J.EBin (J.PlusEq, (J.EAccess (cx, J.ENum 1.)), int n))]
        | Array_set (x, y, z) ->
            let ((px, cx), expr_queue) = access_queue expr_queue x in
            let ((py, cy), expr_queue) = access_queue expr_queue y in
            let ((pz, cz), expr_queue) = access_queue expr_queue z in
            flush_queue expr_queue false
              [J.Expression_statement
                 (J.EBin (J.Eq, J.EAccess (cx, J.EBin(J.Plus, cy, one)),
                          cz))]
      in
      let (instrs, expr_queue) = translate_instr ctx expr_queue rem in
      (st @ instrs, expr_queue)

and compile_block st queue pc frontier interm =
if queue <> [] && IntSet.mem pc st.loops then
  flush_all queue (compile_block st [] pc frontier interm)
else begin
  if pc >= 0 then begin
    if IntSet.mem pc st.visited_blocks then begin
      Format.eprintf "!!!! %d@." pc; assert false
    end;
    st.visited_blocks <- IntSet.add pc st.visited_blocks
  end;
  if IntSet.mem pc st.loops then Format.eprintf "@[<2>while (1) {@,";
  Format.eprintf "block %d;" pc;
  let succs = Hashtbl.find st.succs pc in
  let backs = Hashtbl.find st.backs pc in
  let grey =
    List.fold_right
      (fun pc grey -> IntSet.union (dominance_frontier st pc) grey)
      succs IntSet.empty
  in
  let new_frontier = resolve_nodes interm grey in
  let block = IntMap.find pc st.blocks in
  let (seq, queue) = translate_instr st.ctx queue block.body in
  let body =
    seq @
    match block.branch with
      Code.Pushtrap ((pc1, args1), x, (pc2, args2), pc3) ->
  (* FIX: document this *)
        let grey =  dominance_frontier st pc2 in
        let grey' = resolve_nodes interm grey in
        let limit_body =
          IntSet.is_empty grey' && pc3 >= 0 in
        let inner_frontier =
          if limit_body then IntSet.add pc3 grey' else grey'
        in
        if limit_body then incr_preds st pc3;
        assert (IntSet.cardinal inner_frontier <= 1);
        Format.eprintf "@[<2>try {@,";
        let body =
          compile_branch st [] (pc1, args1)
            None IntSet.empty inner_frontier interm
        in
        Format.eprintf "} catch {@,";
        let handler =
(*XXXXXXXXXX This is wrong (argument passing already done) *)
          compile_block st [] pc2 inner_frontier interm
(*
  compile_branch
            st [] (pc2, args2) None IntSet.empty inner_frontier interm
*)
        in
        let x =
          let block2 = IntMap.find pc2 st.blocks in
          let m = Subst.build_mapping args2 block2.params in
          try Subst.VarMap.find x m with Not_found -> x
        in
        Format.eprintf "}@]";
        if limit_body then decr_preds st pc3;
        flush_all queue
          (J.Try_statement (Js_simpl.statement_list body,
                            Some (Var.to_string x,
                                  Js_simpl.statement_list handler),
                            None) ::
           if IntSet.is_empty inner_frontier then [] else begin
             let pc = IntSet.choose inner_frontier in
             if IntSet.mem pc frontier then [] else
               compile_block st [] pc frontier interm
           end)
    | _ ->
        let (new_frontier, new_interm) =
          if IntSet.cardinal new_frontier > 1 then begin
            let x = Code.Var.fresh () in
            let a = Array.of_list (IntSet.elements new_frontier) in
            Format.eprintf "@ var %a;" Code.Var.print x;
            let idx = st.interm_idx in
            st.interm_idx <- idx - 1;
            let cases = Array.map (fun pc -> (pc, [])) a in
            let switch =
              if Array.length cases > 2 then
                Code.Switch (x, cases, [||])
              else
                Code.Cond (IsTrue, x, cases.(1), cases.(0))
            in
            st.blocks <-
              IntMap.add idx
                { params = []; handler = None; body = []; branch = switch }
              st.blocks;
            IntSet.iter (fun pc -> incr_preds st pc) new_frontier;
            Hashtbl.add st.succs idx (IntSet.elements new_frontier);
            Hashtbl.add st.all_succs idx new_frontier;
            Hashtbl.add st.backs idx IntSet.empty;
            (IntSet.singleton idx,
             Array.fold_right
               (fun (pc, i) interm -> (IntMap.add pc (idx, (x, i)) interm))
               (Array.mapi (fun i pc -> (pc, i)) a) interm)
          end else
            (new_frontier, interm)
        in
        assert (IntSet.cardinal new_frontier <= 1);
        (* Beware evaluation order! *)
        let cond =
          compile_conditional
            st queue pc block.branch block.handler
            backs new_frontier new_interm in
        cond @
        if IntSet.cardinal new_frontier = 0 then [] else begin
          let pc = IntSet.choose new_frontier in
          if IntSet.mem pc frontier then [] else
          compile_block st [] pc frontier interm
        end
  in
  if IntSet.mem pc st.loops then begin
    [J.For_statement
       (None, None, None,
        Js_simpl.block
          (if IntSet.cardinal new_frontier > 0 then begin
             Format.eprintf "@ break; }@]";
             body @ [J.Break_statement None]
           end else begin
             Format.eprintf "}@]";
             body
           end))]
  end else
    body
end

and compile_conditional st queue pc last handler backs frontier interm =
  let succs = Hashtbl.find st.succs pc in
  List.iter (fun pc -> if IntMap.mem pc interm then decr_preds st pc) succs;
  Format.eprintf "@[<2>switch{";
  let res =
  match last with
    Return x ->
      let ((px, cx), queue) = access_queue queue x in
      flush_all queue [J.Return_statement (Some cx)]
  | Raise x ->
      let ((px, cx), queue) = access_queue queue x in
      flush_all queue [J.Throw_statement cx]
  | Stop ->
      flush_all queue []
  | Branch cont ->
      compile_branch st queue cont handler backs frontier interm
  | Cond (c, x, cont1, cont2) ->
      let ((px, cx), queue) = access_queue queue x in
      let e =
        match c with
          IsTrue         -> cx
        | CEq n          -> J.EBin (J.EqEqEq, int n, cx)
        | CLt n          -> J.EBin (J.Lt, int n, cx)
        | CUlt n         -> J.EBin (J.Or, J.EBin (J.Lt, cx, int 0),
                                          J.EBin (J.Lt, int n, cx))
        | CLe n          -> J.EBin (J.Le, int n, cx)
      in
      (* Some changes here may require corresponding changes
         in function [fold_children] above. *)
      let iftrue = compile_branch st [] cont1 handler backs frontier interm in
      let iffalse = compile_branch st [] cont2 handler backs frontier interm in
      flush_all queue
        (if never_continue st cont1 frontier interm then
           Js_simpl.if_statement e (Js_simpl.block iftrue) None ::
           iffalse
         else if never_continue st cont2 frontier interm then
           Js_simpl.if_statement
             (Js_simpl.enot e) (Js_simpl.block iffalse) None ::
           iftrue
         else
           [Js_simpl.if_statement e (Js_simpl.block iftrue)
              (Some (Js_simpl.block iffalse))])
  | Switch (x, a1, a2) ->
      (* Some changes here may require corresponding changes
         in function [fold_children] above. *)
      let build_switch e a =
        let a = Array.mapi (fun i cont -> (i, cont)) a in
        Array.stable_sort (fun (_, cont1) (_, cont2) -> compare cont1 cont2) a;
        let l = Array.to_list a in
        let l = list_group snd l in
        let l =
          List.sort
            (fun (_, l1) (_, l2) ->
               - compare (List.length l1) (List.length l2)) l in
        match l with
          [] ->
            assert false
        | [(cont, _)] ->
            Js_simpl.block
              (compile_branch st [] cont handler backs frontier interm)
        | (cont, l') :: rem ->
            let l =
              List.flatten
                (List.map
                   (fun (cont, l) ->
                      match List.rev l with
                        [] ->
                          assert false
                      | (i, _) :: r ->
                          List.rev
                            ((J.ENum (float i),
                              Js_simpl.statement_list
                                (compile_branch
                                   st [] cont handler backs frontier interm @
                                 if never_continue st cont frontier interm then
                                   []
                                 else
                                   [J.Break_statement None]))
                               ::
                             List.map
                             (fun (i, _) -> (J.ENum (float i), [])) r))
                   rem)
            in
            J.Switch_statement
              (e, l,
               Some (Js_simpl.statement_list
                       (compile_branch
                          st [] cont handler backs frontier interm)))
      in
      let (st, queue) =
        if Array.length a1 = 0 then
          let ((px, cx), queue) = access_queue queue x in
          ([build_switch (J.EAccess(cx, J.ENum 0.)) a2], queue)
        else if Array.length a2 = 0 then
          let ((px, cx), queue) = access_queue queue x in
          ([build_switch cx a1], queue)
        else
          ([Js_simpl.if_statement
              (J.EBin(J.InstanceOf, var x, J.EVar ("Array")))
              (build_switch (J.EAccess(var x, J.ENum 0.)) a2)
              (Some (build_switch (var x) a1))],
           queue)
      in
      flush_all queue st
  | Pushtrap _ ->
      assert false
  | Poptrap cont ->
      flush_all queue (compile_branch st [] cont None backs frontier interm)
  in
  Format.eprintf "}@.";
  res

and compile_argument_passing ctx queue (pc, args) continuation =
  if args = [] then
    continuation queue
  else begin
    let block = IntMap.find pc ctx.Ctx.blocks in
    parallel_renaming ctx block.params args continuation queue
  end
(*
  match args with
    [] ->
      continuation queue
  | xl ->
(*XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
XXXX Make sure that we do not miscompile x = y; y = e
      match IntMap.find pc ctx.Ctx.blocks with
        (Some y, _, _) ->


          let ((px, cx), queue) = access_queue queue x in
          let (st, queue) =
            match ctx.Ctx.live.(Var.idx y) with
              0 -> assert false
            | 1 -> enqueue queue px y cx
            | _ -> flush_queue queue (px >= flush_p) (Some y)
                     [J.Variable_statement [Var.to_string y, Some cx]]
          in
          st @ continuation queue
      | _ ->
*)
          assert false
*)
and compile_exn_handling ctx queue (pc, args) handler continuation =
  if pc < 0 then
    continuation queue
  else
    let block = IntMap.find pc ctx.Ctx.blocks in
    match block.handler with
      None ->
        continuation queue
    | Some (x0, (h_pc, h_args)) ->
        let old_args =
          match handler with
            Some (y, (old_pc, old_args)) ->
              assert (Var.compare x0 y = 0 && old_pc = h_pc &&
                      List.length old_args = List.length h_args);
              old_args
          | None ->
              []
        in
        let m = Subst.build_mapping block.params args in
        let h_block = IntMap.find h_pc ctx.Ctx.blocks in
        let rec loop continuation old args params queue =
          match args, params with
            [], [] ->
              continuation queue
          | x :: args, y :: params ->
(*Format.eprintf "ZZZ@.";*)
              let (z, old) =
                match old with [] -> (None, []) | z :: old -> (Some z, old)
              in
              let x' =
                try Some (Subst.VarMap.find x m) with Not_found -> Some x in
              if Var.compare x x0 = 0 || x' = z then
                loop continuation old args params queue
              else begin
               let ((px, cx), queue) = access_queue queue x in
(*Format.eprintf "%a := %a@." Var.print y Var.print x;*)
               let (st, queue) =
                 match 2 (*ctx.Ctx.live.(Var.idx y)*) with
                   0 -> assert false
                 | 1 -> enqueue queue px y cx
                 | _ -> flush_queue queue (px >= flush_p)
                          [J.Variable_statement [Var.to_string y, Some cx]]
               in
               st @ loop continuation old args params queue
              end
          | _ ->
              assert false
        in
(*
Format.eprintf "%d ==> %d/%d/%d@." pc (List.length h_args) (List.length h_block.params) (List.length old_args);
*)
        loop continuation old_args h_args h_block.params queue

and compile_branch st queue ((pc, _) as cont) handler backs frontier interm =
  compile_argument_passing st.ctx queue cont (fun queue ->
  compile_exn_handling st.ctx queue cont handler (fun queue ->
  if IntSet.mem pc backs then begin
    Format.eprintf "@ continue;";
    flush_all queue [J.Continue_statement None]
  end else if IntSet.mem pc frontier || IntMap.mem pc interm then begin
    Format.eprintf "@ (br %d)" pc;
    flush_all queue (compile_branch_selection pc interm)
  end else
    compile_block st queue pc frontier interm))

and compile_branch_selection pc interm =
  try
    let (pc, (x, i)) = IntMap.find pc interm in
    Format.eprintf "@ %a=%d;" Code.Var.print x i;
    J.Variable_statement [Var.to_string x, Some (int i)] ::
    compile_branch_selection pc interm
  with Not_found ->
    []

and compile_closure ctx (pc, args) =
  let st =
    { visited_blocks = IntSet.empty; loops = IntSet.empty;
      all_succs = Hashtbl.create 17; succs = Hashtbl.create 17;
      backs = Hashtbl.create 17; preds = Hashtbl.create 17;
      interm_idx = -1; ctx = ctx; blocks = ctx.Ctx.blocks }
  in
  build_graph st pc IntSet.empty;
  let current_blocks = st.visited_blocks in
  st.visited_blocks <- IntSet.empty;
  Format.eprintf "@[<2>closure{";
  let res =
    compile_branch st [] (pc, args) None IntSet.empty IntSet.empty IntMap.empty
  in
  if
    IntSet.cardinal st.visited_blocks <> IntSet.cardinal current_blocks
  then begin
    Format.eprintf "Some blocks not compiled!@."; assert false
  end;
  Format.eprintf "}@]";
  Js_simpl.source_elements res

let compile_program ctx pc =
  let res = compile_closure ctx (pc, []) in Format.eprintf "@.@."; res

(**********************)

let f ((pc, blocks, _) as p) live_vars =
  let mutated_vars = Freevars.f p in
  let ctx = Ctx.initial blocks live_vars mutated_vars in
  let p = compile_program ctx pc in
  if compact then Format.set_margin 999999998;
  Format.printf "%a" Js_output.program p