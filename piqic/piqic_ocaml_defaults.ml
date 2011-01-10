(*pp camlp4o -I $PIQI_ROOT/camlp4 pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)


(*
 * This module generates default values for all OCaml types generated by
 * Piqic_ocaml_types
 *)

open Piqi_common
open Piqic_common
open Iolist


(* reuse several functions *)
open Piqic_ocaml_types
open Piqic_ocaml_out


(* generate a default value for one of built-in types *)
let gen_builtin_value wire_type t =
  let gen_obj code x =
    match x with
      | #T.piqdef | `any -> assert false (* already processed below *)
      | `int -> Piqobj_to_wire.gen_int code 0L ?wire_type
      | `float -> Piqobj_to_wire.gen_float code 0.0 ?wire_type
      | `bool -> Piqobj_to_wire.gen_bool code false
      | `string | `binary | `text | `word ->
          Piqobj_to_wire.gen_string code ""
  in
  let str = Piqirun.gen_binobj gen_obj t in
  iod " " [
    ios "(Piqirun.parse_default"; ioq (String.escaped str); ios ")";
  ]


let gen_default_type ocaml_type wire_type x =
  match x with
    | `any ->
        if !top_modname = "Piqtype"
        then ios "default_any ()"
        else ios "Piqtype.default_any ()"
    | (#T.piqdef as x) ->
        let modname = gen_parent x in
        modname ^^ ios "default_" ^^ ios (piqdef_mlname x) ^^ ios "()"
    | _ -> (* gen parsers for built-in types *)
        iol [
            ios "Piqirun.";
            ios (gen_ocaml_type_name x ocaml_type);
            ios "_of_";
            ios (W.get_wire_type_name x wire_type);
            gen_builtin_value wire_type x;
        ]


let gen_default_typeref ?ocaml_type ?wire_type (t:T.typeref) =
  gen_default_type ocaml_type wire_type (piqtype t)


let gen_field_cons rname f =
  let open Field in
  let fname = mlname_of_field f in
  let ffname = (* fully-qualified field name *)
    iol [ios rname; ios "."; ios fname]
  in 
  let value =
    match f.mode with
      | `required -> gen_default_typeref (some_of f.typeref)
      | `optional when f.typeref = None -> ios "false" (* flag *)
      | `optional when f.default <> None ->
          let default = some_of f.default in
          let default_str = String.escaped (some_of default.T.Any.binobj) in
          iod " " [
            Piqic_ocaml_in.gen_parse_typeref (some_of f.typeref);
              ios "(Piqirun.parse_default"; ioq default_str; ios ")";
          ]

      | `optional -> ios "None"
      | `repeated -> ios "[]"
  in
  (* field construction code *)
  iod " " [ ffname; ios "="; value; ios ";" ] 


let gen_record r =
  (* fully-qualified capitalized record name *)
  let rname = capitalize (some_of r.R#ocaml_name) in
  let fields = r.R#wire_field in
  let fconsl = (* field constructor list *)
    List.map (gen_field_cons rname) fields
  in (* fake_<record-name> function delcaration *)
  iod " "
    [
      ios "default_" ^^ ios (some_of r.R#ocaml_name); ios "() =";
      ios "{"; iol fconsl; ios "}";
    ]


let gen_enum e =
  let open Enum in
  (* there must be at least one option *)
  let const = List.hd e.option in
  iod " "
    [
      ios "default_" ^^ ios (some_of e.ocaml_name); ios "() =";
        gen_pvar_name (some_of const.O#ocaml_name)
    ]


let rec gen_option varname o =
  let open Option in
  match o.ocaml_name, o.typeref with
    | Some mln, None ->
        gen_pvar_name mln
    | None, Some ((`variant _) as t) | None, Some ((`enum _) as t) ->
        iod " " [
            ios "("; gen_default_typeref t; ios ":>"; ios varname; ios ")"
        ]
    | _, Some t ->
        let n = mlname_of_option o in
        iod " " [
              gen_pvar_name n;
              ios "("; gen_default_typeref t; ios ")";
        ]
    | None, None -> assert false


let gen_variant v =
  let open Variant in
  (* there must be at least one option *)
  let opt = gen_option (some_of v.ocaml_name) (List.hd v.option) in
  iod " "
    [
      ios "default_" ^^ ios (some_of v.ocaml_name); ios "() ="; opt;
    ]


let gen_alias a =
  let open Alias in
  iod " "
    [
      ios "default_" ^^ ios (some_of a.ocaml_name); ios "() =";
      gen_default_typeref
        a.typeref ?ocaml_type:a.ocaml_type ?wire_type:a.wire_type;
    ]


let gen_list l =
  let open L in
  iod " "
    [
      ios "default_" ^^ ios (some_of l.ocaml_name); ios "() = []";
    ]


let gen_def = function
  | `record t -> gen_record t
  | `variant t -> gen_variant t
  | `enum t -> gen_enum t
  | `list t -> gen_list t
  | `alias t -> gen_alias t


let gen_alias a = 
  let open Alias in
  if a.typeref = `any && not !depends_on_piq_any
  then []
  else [gen_alias a]


let gen_def = function
  | `alias x -> gen_alias x
  | x -> [gen_def x]


let gen_defs (defs:T.piqdef list) =
  let defs = flatmap gen_def defs in
  if defs = []
  then iol []
  else iod " "
    [
      ios "let rec"; iod " and " defs;
      ios "\n";
    ]


let gen_piqi (piqi:T.piqi) =
  gen_defs piqi.P#resolved_piqdef
