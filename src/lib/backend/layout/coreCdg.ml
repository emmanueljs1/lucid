(* Transform a control flow graph into a control dependency graph *)
open Batteries
open Printf
open InterpHelpers
module CL = Caml.List
open CoreSyntax
open TofinoCore
open MatchAlgebra
open CoreCfg

exception Error of string
let error s = raise (Error s)

(* logging *)
module DBG = BackendLogging
let outc = ref None
let dprint_endline = ref DBG.no_printf
let start_logging () = DBG.start_mlog __FILE__ outc dprint_endline




(***  edge condition propagation ***)
let idom_of_cfg g = 
    let root = match (roots g) with 
        | [root] -> root
        | [] -> error "[idom_of_cfg] unexpected: no root"
        | _ -> error "[idom_of_cfg] unexpected: more than 1 root"
    in (* get the dominator graph *)
    let idom = CfgDom.compute_idom g root in 
    idom
;;


let print_node_in_edges lbl g v =
    !dprint_endline (lbl^"vertex:"^(CoreCfg.summarystr_of_stmt v.stmt true));
    !dprint_endline (lbl^"in edges:");
    Cfg.iter_pred 
        (fun p ->   
            let (s, e, t) = Cfg.find_edge g p v in
            !dprint_endline (lbl^"SRC:"^(CoreCfg.summarystr_of_stmt s.stmt true));
            !dprint_endline (lbl^"DST:"^(CoreCfg.summarystr_of_stmt t.stmt true));
            !dprint_endline (lbl^"in edge:"^(CoreCfg.str_of_edge_condition e))
        )
        g
        v;
;;

let rec precondition_of_vertex orig_v idom g v =
    match (Cfg.pred_e g v) with        
    | [] -> CNone (* no precondition *)
    | [(_, e, _)] -> e (* single predecessor -- the precondition is the edge from pred --> v *)
    | _ -> 

        let d = idom v in 
        !dprint_endline@@"[precondition_of_vertex] FINDING PRECONDITION FOR:"^(CoreCfg.summarystr_of_stmt orig_v.stmt true);
        print_node_in_edges "[precondition_of_vertex] INEDGE:" g v;
        !dprint_endline@@"[precondition_of_vertex] recursing FROM:"^(CoreCfg.summarystr_of_stmt v.stmt true);
        !dprint_endline@@"[precondition_of_vertex] recursing TO:"^(CoreCfg.summarystr_of_stmt d.stmt true);
    precondition_of_vertex orig_v idom g (idom v)
        (* multiple predecessors -- join node. Look 
           at preconditions of the corresponding 
           branch node, ie, the idom. *) 
;; 

let test_edge_condition pc =
    (match pc with
        | CMatch(match_cond) -> (
            match match_cond.pos with
            | None -> 
                !dprint_endline "precondition with no positive branch.";
                error (CoreCfg.str_of_edge_condition pc)
            | _ -> !dprint_endline "has positive branch";
        )
        | _ -> ()
    )
;;


(* propagate edge constraints through the cfg *)
let propagate_edge_constraints g =
    let idom = idom_of_cfg g in 
    (* find the constraints on a vertex and propagate them to 
       all out-edges of the vertex *)
    let process_vertex v g = 
        let pc = precondition_of_vertex v idom g v in 
        !dprint_endline ("------");
        !dprint_endline ("[propagate_edge_constraints] vertex:"^(str_of_cond_stmt v));
        !dprint_endline ("precondition_of_vertex:");
        !dprint_endline ((str_of_edge_condition pc));
        let update_for_outedge (s, e, d) g =
            let new_e = match (pc, e) with
                | (CNone, CNone) -> CNone
                | (_, CNone) -> pc
                | (CNone, _) -> e
                | (CMatch(pc_c), CMatch(e_c)) ->
                    CMatch(MatchAlgebra.and_conditions pc_c e_c)
                | (CExp(_), _) | (_, CExp(_)) -> 
                    error "CExp constraints not implemented. Convert to match"
            in 
            !dprint_endline ("successor node: "^(CoreCfg.summarystr_of_stmt d.stmt true));
            !dprint_endline ("original out edge condition: ");
            !dprint_endline ((str_of_edge_condition e));
            !dprint_endline ("new out edge condition: ");
            !dprint_endline ((str_of_edge_condition new_e));
            let g = Cfg.remove_edge_e g (s, e, d) in 

            Cfg.add_edge_e g (s, new_e, d)
        in 
        !dprint_endline ("-****----");
        let new_g = Cfg.fold_succ_e update_for_outedge g v g in
        !dprint_endline ("-****----");
        !dprint_endline ("------");
        new_g 
    in
    (* iterate over nodes in the first g, updating edges in the second g *)
    CfgTopo.fold process_vertex g g
;;


(* 
    Remove match nodes whose branches have their own nodes in the CFG. 
    The remaining match nodes are "solitary" -- nodes that must remain 
    in the output code. 
    When removing a node v, add an edge from every (pred[v] --> succ[v])
    with the edge condition (v, succ[v]).
 *)



let print_node_in_edges lbl g v =
    !dprint_endline (lbl^"vertex:"^(CoreCfg.summarystr_of_stmt v.stmt true));
    !dprint_endline (lbl^"in edges:");
    Cfg.iter_pred 
        (fun p ->   
            let (s, e, t) = Cfg.find_edge g p v in
            !dprint_endline (lbl^"SRC:"^(CoreCfg.summarystr_of_stmt s.stmt true));
            !dprint_endline (lbl^"DST:"^(CoreCfg.summarystr_of_stmt t.stmt true));
            !dprint_endline (lbl^"in edge:"^(CoreCfg.str_of_edge_condition e))
        )
        g
        v;
;;

let remove_noop_match_nodes g =  
    (* CfgTopo.iter (print_node_in_edges "[BEFORE REMOVE NOOP]" g) g; *)

    let update_for_node v g =
        let add_new_pred_edges pred_v g = 
            let update_for_outedge (_(*v*), succ_v_e, succ_v) g =
                Cfg.add_edge_e g (pred_v, succ_v_e, succ_v)
            in
            (* 1. add edges from every pred_v --> succ_v *)
            let g = Cfg.fold_succ_e update_for_outedge g v g in 
            g
        in
        match v.stmt.s with 
        | SMatch(_, bs) -> (
            (* solitary match node -- we can't delete it. *)
            if (v.solitary) then (g)
            else (
                (* non-solitary, but this is a match statement that does something. 
                   so we don't want to delete it.  *)
                if ((CL.length bs) <> 0) then (g)
                else (
                    let g = Cfg.fold_pred add_new_pred_edges g v g in 
                    Cfg.remove_vertex g v
                )
            )
        )
        (* non match node: no change *)
        | _ -> g
    in 
    (* update for each node in g *)
    let new_g = CfgTopo.fold update_for_node g g in

    (* CfgTopo.iter (print_node_in_edges "[AFTER REMOVE NOOP]" new_g) new_g; *)
    new_g
;;


(* vertex normalization: convert each vertex into a match statement that 
   tests its complete execution conditions. Once normalized, these match 
   statements can be executed in any order, as long as data dependencies 
   are respected. 

    - non-match statements: find precondition for execution, 
        convert that into a match:
        - miss rules --> noop branches
        - hit rule --> stmt branch

*)

let branch_of_pattern p stmt = 
    (CL.split p |> snd, stmt)

let noop_branch_of_pattern p = branch_of_pattern p snoop;;

let noop_branches_of_patterns ps = 
    CL.map noop_branch_of_pattern ps
;;

(* a branch, but with a pattern instead of a pat list *)
type pattern_branch = (pattern * statement)
;;

let pattern_branch_of_branch es (ps, stmt) : pattern_branch = 
    CL.combine es ps, stmt
;;

let branch_of_pattern_branch (p, stmt) : branch =
    CL.split p |> snd, stmt
;;

(* a noop branch *)
let default_branch keys = (CL.map (fun _ -> PWild) keys, snoop) ;;


(* this pass puts each vertex into a normal form. 
    Non-solitary match nodes: do nothing.
    Operation nodes: 

*)
let vertices_in_normal_match_form g =
    let idom = idom_of_cfg g in 
    let normalize_vertex v =
        let pc = precondition_of_vertex v idom g v in 
        match v.stmt.s, v.solitary with
            | SMatch(_, _), false -> v
                (* this node will be deleted in the next pass *)
                (* error "[normalize_vertex] a non-solitary match vertex... these should have been eliminated by now." *)
            | SMatch(keys, branches), true -> (
                match pc with
                | CNone -> v
                | CExp(_) -> error "If path conditions not supported"
                | CMatch(match_cond) -> (
                (* get keys *)
                let all_keys = (keys_of_condition match_cond)@keys |> unique_expr_list in 
                (* operate over pattern branches *)
                let pattern_branches = CL.map (pattern_branch_of_branch keys) branches in 
                (* extend the keys of everything *)
                let match_cond = extend_condition_pats all_keys match_cond in
                let pattern_branches = CL.map 
                    (fun (pat, stmt) -> (extend_pat all_keys pat, stmt)) 
                    pattern_branches 
                in 
                (* compute the cross product: miss branches of the match_cond are noop branches. *)
                let miss_branches = noop_branches_of_patterns match_cond.negs in 
                (* there is one hit branch for every branch in the statement. Its pattern is 
                   the intersection of the precondition's hit branch and the statement branch. *)
                let match_cond_pos = match match_cond.pos with
                    | Some(pos) -> pos
                    | None -> error "[normalize_vertex] precondition of statement vertex in CFG is never true. This should not happen."
                in 
                let hit_branches = 
                    CL.filter_map
                        (fun pattern_branch -> 
                            let (pattern, stmt) = pattern_branch in
                            let hit_pattern = MatchAlgebra.and_patterns match_cond_pos pattern in 
                            match hit_pattern with 
                                | None -> None
                                | Some(pattern) -> Some(pattern, stmt)
                        )
                        pattern_branches
                    |> CL.map branch_of_pattern_branch
                in
                let new_match_branches = miss_branches@hit_branches@[(default_branch all_keys)] in
                let new_s = SMatch(all_keys, new_match_branches) in 
                let new_stmt = {v.stmt with s=new_s;} in
                let res = {v with stmt=new_stmt;} in
                res
                )
            )
            (* scenario: this is a regular statement. We are just adding the condition to it. *)
            | _, _ -> ( 
                match pc with 
                | CMatch(match_cond) -> 
                    let keys = keys_of_condition match_cond in 
                    let miss_branches = noop_branches_of_patterns match_cond.negs in 

                    (* there is no hit branch on this precondition... how does that happen? *)
                    let hit_branch = match match_cond.pos with
                        | None -> [] (* error "no hit branch on a precondition. Double check that this is possible." *)
                            (* Note: a precondition can have no hit. Its just a branch that can never 
                                    be reached in the program. If a precondition has no hit, 
                                    then the match representation of the table also has no hit. 
                                    To optimize, we could remove these branches from the program entirely.
                                example: 
                                if (a || b) {
                                    if (a) {
                                        foo;
                                    } else {bar;}
                                }

                                this expands to: 
                                match (a, b) with 
                                | (true, true) -> ...
                                | (true, false)
                                | (false, true) -> {
                                    match (a) with 
                                    | true -> foo; // this branch right here can never be reached.
                                    | false -> bar;
                                }
                                | (false, false)
                            *)
                        | Some pos -> [branch_of_pattern pos v.stmt]
                    in 
                    let new_stmt = {v.stmt with s = SMatch(keys, miss_branches@hit_branch@[default_branch keys])} in
                    !dprint_endline ("ORIGINAL VERTEX:"^(CoreCfg.summarystr_of_stmt v.stmt true));
                    print_node_in_edges "[NODE IN EDGES]" g v;
                    !dprint_endline ("INPUT PC:"^(CoreCfg.str_of_edge_condition pc));
                    !dprint_endline ("NORMALIZED VERTEX:"^(CoreCfg.summarystr_of_stmt new_stmt true));
                    {v with stmt = new_stmt;}
                | CNone -> 
                    (* there is no precondition on this node... so its a match with only a default rule *)
                    let match_s = SMatch([], [([], v.stmt)]) in 
                    let new_stmt = {v.stmt with s = match_s;} in 
                    !dprint_endline ("NORMALIZED NO CONDITION VERTEX:"^(CoreCfg.summarystr_of_stmt new_stmt true));
                    {v with stmt = new_stmt;}
                | CExp(_) -> error "If path conditions not supported"
            )
    in 
    Cfg.map_vertex normalize_vertex g
;;


let to_control_dependency_graph g =
    let g = propagate_edge_constraints g 
    |> vertices_in_normal_match_form
    |> remove_noop_match_nodes 
    in  
    (* CoreCfg.print_cfg ((!BackendLogging.graphLogDir)^"/cdg_noops_gone.dot") g; *)
    g
;;