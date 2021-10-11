(* 
  Generates P4 externs from json config file. 
  - entry event trigger table
  - exit event action table
*)

module CL = Caml.List
module BS = Batteries.String
open MiscUtils
open Printf
open Format
open Core
module DBG = BackendLogging
open Yojson.Basic.Util
open P4ExternSyntax

let outc = ref None
let dprint_endline = ref DBG.no_printf
let start_log () = DBG.start_mlog __FILE__ outc dprint_endline
exception Error of string
let error s = raise (Error s)

(* pragma in the harness that gets replaced 
   with the code generated by this module. *)
let obj_pragma = "ENTRY_OBJECTS"
let call_pragma = "ENTRY_CALL"
let json_block_name = "entry" 
let tname = "entry_table"

(* internal representation of json event spec block *)
type field_val = 
  | FVInt of int 
  | FVBool of bool
type event_spec = {
  name : string;
  conditions : (string * field_val list) list; (* (p4 field, list of matching values) *)
  arguments : (string * string) list;(* (event parameter, p4 field) *)
}
let string_of_fieldval fv = 
  match fv with 
    | FVInt i -> string_of_int i
    | FVBool b -> string_of_bool b 
;;
let dbg_print_event_spec event_spec =   
  (* print an event spec *)
  print_endline ("event: "^event_spec.name);
  CL.iter (
    fun (f, vs) -> 
    print_endline ("field: "^f);
    print_endline ("values: ");
    CL.iter (fun v -> string_of_fieldval v |> print_endline) vs;
  ) event_spec.conditions;
  print_endline ("arguments: ");
  CL.iter (
    fun (a, f) -> 
    print_endline (event_spec.name^"."^a^" : "^f);
  ) event_spec.arguments;
;;
(* convert from json to internal representation *)
let extract_field_val (v : Yojson.Basic.t) : field_val = 
      match v with 
      | `Bool v -> FVBool v
      | `Int v -> FVInt v
      | _ -> error "[JsonExterns.extract_event_spec] json parsing error: field values must be integers or booleans."
;;

let extract_event_spec json_spec = 
  (* extract an event_spec from its json representation *)
  let name = member "event" json_spec |> to_string in 
  let guard_json = member "conditions" json_spec |> to_assoc in 
  let args_json = member "inputs" json_spec |> to_assoc in 
  let extract_condition_field (field, vals) = 
    (* extract a single field's triggering values *)
    let vals = convert_each extract_field_val vals in 
    (field, vals)
  in 
  let process_arg (ev_param, field) = 
    (* extract a single event argument -> field mapping *)
    let field = to_string field in 
    (ev_param, field)
  in 
  let conditions = CL.map extract_condition_field guard_json in 
  let arguments = CL.map process_arg args_json in  
  {name=name; conditions=conditions; arguments=arguments;}
;; 

let extract_event_specs configfn = 
  In_channel.read_all configfn 
    |> Yojson.Basic.from_string (* parse from string *)
    |> member json_block_name (* find triggers block *)
    |> convert_each extract_event_spec (* convert each item in triggers into an ev spec *)
;;

(**** event spec to action / table translators ****)

let argument_to_command ev_name (param, field) = 
  sprintf "%s.%s.%s = %s;" LLConstants.md_instance_prefix ev_name param field
let arguments_to_commands ev_name a_s = CL.map (argument_to_command ev_name) a_s


(* convert the conditions to invoke an action, of the form: 
    x=a && y=(b || c) && z=(d || e || f)
   into guards, where each guard is a disjunction and the list of 
   guards is a conjunction: 
    (x=a && y=b && z=d) || (x=a && y=b && z=e) || ... || (x=a && y=c && z=f)
*)
let conditions_to_guards (conditions:(string * field_val list) list) = 
  (* 
    example: 
      conditions: 
        "foo" : [1; 2]
        "bar" : [3; 4]
  *)
  let pattern_fields = CL.map fst conditions in (* ["foo"; "bar"] *)
  let pattern_values_lists = all_combinations (CL.map snd conditions) in (* [[1; 3]; [1; 4]; [2; 3]; [2; 4]] *)
  let patterns_lists = CL.map 
    (fun pattern_values -> CL.combine pattern_fields pattern_values) 
    pattern_values_lists 
  in (* [[(foo, 1); (bar, 3)]; [(foo, 1); (bar, 4)]; [(foo, 2); (bar, 3)]; [(foo, 2); (bar, 4)]] *)
  let guard_of_tuples si_s = 
    let pattern_of_tuple (s, (i:field_val)) = 
      {field = s; 
        value = match i with 
          | FVInt i -> VInt i
          | FVBool b -> VBool b
        ;
      }
    in 
    CL.map pattern_of_tuple si_s 
  in  
  (* the list of guards. Each guard is for a different rule. *) 
  let guards = CL.map guard_of_tuples patterns_lists in 
  guards 
;;

let event_const_id = LLOp.TofinoStructs.defname_from_evname
;;

let event_field = sprintf 
  "%s.%s.%s" 
  LLConstants.md_instance_prefix 
  LLConstants.dpt_meta_str 
  LLConstants.handle_selector_str
;;
let set_event_type_cmd ename = 
  sprintf "%s=%s;" event_field (event_const_id ename)
;;

(* accumulate actions and rules for event specs. *)
let event_spec_to_action_rules_accumulator (acns, rules) e = 
  let acn = {
    aname = ("trigger_"^e.name);
    aparams = [];
    acmds = (set_event_type_cmd e.name)::(arguments_to_commands e.name e.arguments);
    } 
  in 
  let guards = conditions_to_guards e.conditions in 
  let new_rules = CL.map (fun guard -> {guard = guard; action = acn; action_args = [];}) guards in 
  (acns@[acn], rules@new_rules)
;;
let event_specs_to_action_rules es = 
  CL.fold_left event_spec_to_action_rules_accumulator ([], []) es
;;

(* generate the entry trigger table. *)
let generate configfn =
  let _ = configfn in  
  (* print_endline ("TriggerTable.generate reading config file: "^(configfn)); *)
  let event_specs = extract_event_specs configfn in 

  let actions, rules = event_specs_to_action_rules event_specs in 
  let rules = normalize_rules rules in 
  let keys = all_fields_of_rules rules |> CL.map (fun field -> {kfield=field; ktype=Ternary;}) in 
  let table = {
    tname = tname;
    tkeys = keys;
    tactions = actions;
    trules = rules;
    }
  in 
  let actions_string = actions_to_string actions in 
  let table_string = table_to_string table in 
(*   print_endline ("------- actions -------");
  print_endline (actions_string);
  print_endline ("------- table   -------");
  print_endline (table_string); *)
  (* print_endline "\ndone."; *)
  let obj_string = actions_string^"\n"^table_string in 
  let call = sif (eqtest_to_bexpr event_field "0") (scall table) in 
  let call_str = stmt_to_string call in 

  [(obj_pragma, obj_string); (call_pragma, call_str)]
;;
