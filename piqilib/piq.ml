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

(* Piq stream *)


module C = Piqi_common  
open C


exception EOF

(* piq stream object *)
type obj =
  | Piqtype of string
  | Typed_piqobj of Piqobj.obj
  | Piqobj of Piqobj.obj
  | Piqi of T.piqi


let open_piq fname =
  trace "opening .piq file: %s\n" fname;
  let ch = Piqi_main.open_input fname in
  let piq_parser = Piq_parser.init_from_channel fname ch in
  piq_parser


let read_piq_ast piq_parser :T.ast = 
  let res = Piq_parser.read_next piq_parser in
  match res with
    | Some ast -> ast
    | None -> raise EOF


let default_piqtype = ref None


let check_piqtype n =
  if not (Piqi_name.is_valid_typename n)
  then error n ("invalid type name: " ^ quote n)
  else ()


let find_piqtype ?(check=false) typename =
  if check
  then check_piqtype typename;

  try Piqi_db.find_piqtype typename
  with Not_found ->
    error typename ("unknown type: " ^ typename)


let process_default_piqtype ?check typename =
  let piqtype = find_piqtype ?check typename in
  (* NOTE: silently overriding previous value *)
  default_piqtype := Some piqtype


let piqi_of_piq fname ast =
  let piqi = Piqi.load_piqi_ast fname ast in
  piqi


let rec load_piq_obj piq_parser :obj =
  let ast = read_piq_ast piq_parser in
  let fname, _ = piq_parser in (* TODO: improve getting a filename from parser *)
  match ast with
    | `typed {T.Typed.typename = "piqtype";
              T.Typed.value = {T.Any.ast = Some (`word typename)}} ->
        (* :piqtype <typename> *)
        process_default_piqtype typename;
        Piqtype typename
    | `typed {T.Typed.typename = "piqtype"} ->
        error ast "invalid piqtype specification"
    | `typed {T.Typed.typename = "piqi";
              T.Typed.value = {T.Any.ast = Some ((`list _) as ast)}} ->
        (* :piqi <piqi-spec> *)
        let piqi = piqi_of_piq fname ast in
        Piqi piqi
    | `typed {T.Typed.typename = "piqi"} ->
        error ast "invalid piqi specification"
    | `typename x ->
        error x "invalid piq object"
    | `typed _ ->
        let obj = Piqobj_of_piq.parse_typed_obj ast in
        Typed_piqobj obj
    | _ ->
        match !default_piqtype with
          | Some piqtype ->
              let obj = Piqobj_of_piq.parse_obj piqtype ast in
              Piqobj obj
          | None ->
              error ast "type of object is unknown"


let make_piqtype typename =
  `typed {
    T.Typed.typename = "piqtype";
    T.Typed.value = {
      T.Any.ast = Some (`word typename);
      T.Any.binobj = None;
    }
  }


let original_piqi piqi =
  let orig_piqi = some_of piqi.P#original_piqi in
  (* make sure that the module's name is set *)
  P#{orig_piqi with modname = piqi.P#modname}


let piqi_to_piq piqi =
  let piqi_ast = Piqi_pp.piqi_to_ast (original_piqi piqi) ~simplify:true in
  `typed {
    T.Typed.typename = "piqi";
    T.Typed.value = {
      T.Any.ast = Some piqi_ast;
      T.Any.binobj = None;
    }
  }


let write_piq ch (obj:obj) =
  let ast =
    match obj with
      | Piqtype typename ->
          make_piqtype typename
      | Piqi piqi ->
          piqi_to_piq piqi
      | Typed_piqobj obj ->
          Piqobj_to_piq.gen_typed_obj obj
      | Piqobj obj ->
          Piqobj_to_piq.gen_obj obj
  in
  Piq_gen.to_channel ch ast;
  (* XXX: add one extra newline for better readability *)
  Pervasives.output_char ch '\n'


let open_wire fname =
  trace "opening .wire file: %s\n" fname;
  let ch = Piqi_main.open_input fname in
  let buf = Piqirun.IBuf.of_channel ch in
  buf


let read_wire_field buf =
  (* TODO: handle runtime wire read errors *)
  if Piqirun.is_empty buf
  then raise EOF
  else Piqirun.parse_field buf


let piqtypes = ref []

let add_piqtype code piqtype =
  if code = 1 (* default piqtype *)
  then
    (* NOTE: silently overriding previous value *)
    default_piqtype := Some piqtype
  else
    let code = (code+1)/2 in
    piqtypes := (code, piqtype) :: !piqtypes


let find_piqtype_by_code code =
  try
    let (_,piqtype) =
      List.find
        (function (code',_) when code = code' -> true | _ -> false)
        !piqtypes
    in piqtype
  with
    Not_found ->
      (* TODO: add stream position info *)
      piqi_error
        ("invalid field code when reading .wire: " ^ string_of_int code)


(* using max code value as a wire code for Piqi
 *
 * XXX: alternatively, we could use an invalid value like 0, or lowest possible
 * code, i.e. 1 *)
let piqi_spec_wire_code = (1 lsl 29) - 1


let piqi_to_wire piqi =
  T.gen_piqi piqi_spec_wire_code (original_piqi piqi)

let piqi_to_pb piqi =
  (* -1 means don't generate wire code *)
  T.gen_piqi (-1) (original_piqi piqi)


let piqi_of_wire bin =
  let piqi = T.parse_piqi bin in
  let fname = "" in (* XXX *)
  Piqi.process_piqi fname piqi; (* NOTE: caching the loaded module *)
  piqi


let process_piqtype code typename =
  let piqtype =
    try Piqi_db.find_piqtype typename
    with Not_found ->
      (* TODO: add stream position info *)
      piqi_error ("unknown type: " ^ typename)
  in
  add_piqtype code piqtype


let rec load_wire_obj buf :obj =
  let field_code, field_obj = read_wire_field buf in
  match field_code with
    | c when c = piqi_spec_wire_code -> (* embedded Piqi spec *)
        let piqi = piqi_of_wire field_obj in
        Piqi piqi
    | c when c mod 2 = 1 ->
        let typename = Piqirun.parse_string field_obj in
        process_piqtype c typename;
        if c = 1
        then
          (* :piqtype <typename> *)
          Piqtype typename
        else
          (* we've just read type-code binding information;
             proceed to the next stream object *)
          load_wire_obj buf
    | 2 ->
        (match !default_piqtype with
          | Some piqtype ->
              let obj = Piqobj_of_wire.parse_obj piqtype field_obj in
              Piqobj obj
          | None ->
              (* TODO: add stream position info *)
              piqi_error "default type for piq wire object is unknown"
        )
    | c -> (* the code is even which means typed piqobj *)
        let piqtype = find_piqtype_by_code (c/2) in
        let obj = Piqobj_of_wire.parse_obj piqtype field_obj in
        Typed_piqobj obj


let out_piqtypes = ref []
let next_out_code = ref 2


let gen_piqtype code typename =
  Piqirun.gen_string code typename


let write_piqtype ch code typename =
  let data = gen_piqtype code typename in
  Piqirun.to_channel ch data


let find_add_piqtype_code ch name =
  try 
    let (_, code) =
      List.find
        (function (name',_) when name = name' -> true | _ -> false)
        !out_piqtypes
    in code
  with Not_found ->
    let code = !next_out_code * 2 in
    incr next_out_code;
    out_piqtypes := (name, code)::!out_piqtypes;
    write_piqtype ch (code-1) name;
    code

 
let write_wire ch (obj :obj) =
  let data =
    match obj with
      | Piqi piqi ->
          piqi_to_wire piqi
      | Piqtype typename ->
          gen_piqtype 1 typename
      | Piqobj obj ->
          Piqobj_to_wire.gen_obj 2 obj
      | Typed_piqobj obj ->
          let typename = Piqobj_common.full_typename obj in
          let code = find_add_piqtype_code ch typename in
          Piqobj_to_wire.gen_obj code obj
  in
  Piqirun.to_channel ch data


let open_pb fname =
  trace "opening .pb file: %s\n" fname;
  let ch = Piqi_main.open_input fname in
  let buf = Piqirun.init_from_channel ch in
  buf


(* NOTE: this function will be called exactly once *)
let load_pb (piqtype:T.piqtype) wireobj :obj =
  (* TODO: handle runtime wire read errors *)
  if piqtype == !Piqi.piqi_def (* XXX *)
  then
    let piqi = piqi_of_wire wireobj in
    Piqi piqi
  else
    let obj = Piqobj_of_wire.parse_obj piqtype wireobj in
    Typed_piqobj obj


let write_pb ch (obj :obj) =
  let buf =
    match obj with
      | Piqi piqi ->
          piqi_to_pb piqi
      | Typed_piqobj obj | Piqobj obj ->
          let piqtype = Piqobj_common.type_of obj in
          (match unalias piqtype with
            | `record _ | `variant _ | `list _ -> ()
            | _ ->
                piqi_error "only records, variants and lists can be written to .pb"
          );
          Piqobj_to_wire.gen_embedded_obj obj
      | Piqtype _ ->
          (* ignore default type names *)
          Piqirun.OBuf.iol [] (* == empty output *)
  in
  Piqirun.to_channel ch buf


let piqi_of_json json =
  let piqtype = !Piqi.piqi_def in
  let wire_parser = T.parse_piqi in

  (* dont' resolve defaults when reading Json;
   * preseve the original setting *)
  let saved_resolve_defaults = !Piqobj_of_json.resolve_defaults in
  Piqobj_of_json.resolve_defaults := true;

  let piqobj = Piqobj_of_json.parse_obj piqtype json in

  Piqobj_of_json.resolve_defaults := saved_resolve_defaults;

  let piqi = Piqi.mlobj_of_piqobj wire_parser piqobj in

  (* XXX: it appears that we actually don't need the name of the file here *)
  let fname = "" in
  Piqi.process_piqi fname piqi; (* NOTE: caching the loaded module *)
  piqi


let piqi_to_json piqi =
  let piqi = original_piqi piqi in

  let piqtype = !Piqi.piqi_def in
  let wire_generator = T.gen_piqi in

  let piqobj =
    Piqi.mlobj_to_piqobj piqtype wire_generator piqi
  in
  let json = Piqobj_to_json.gen_obj piqobj in
  json


let write_json_obj ch json =
  Piqi_json_gen.pretty_to_channel ch json;
  (* XXX: add a newline for better readability *)
  Pervasives.output_char ch '\n'


let write_piq_json ch (obj:obj) =
  let json =
    match obj with
      | Piqi piqi -> (* embedded Piqi spec *)
          let json = piqi_to_json piqi in
          `Assoc [ "_piqi", json ]
      | Piqtype typename ->
          `Assoc [ "_piqtype", `String typename ]
      | Typed_piqobj obj ->
          Piqobj_to_json.gen_typed_obj obj
      | Piqobj obj ->
          Piqobj_to_json.gen_obj obj
  in
  write_json_obj ch json


let write_json is_piqi_input ch (obj:obj) =
  match obj with
    | Typed_piqobj obj | Piqobj obj ->
        let json = Piqobj_to_json.gen_obj obj in
        write_json_obj ch json
    | Piqi piqi when is_piqi_input ->
        (* output Piqi spec itself if we are converting .piqi *)
        write_json_obj ch (piqi_to_json piqi)
    | Piqtype _ | Piqi _ -> () (* ignore embedded Piqi specs and type hints *)


let read_json_ast json_parser :Piqi_json_common.json =
  let res = Piqi_json.read_json_obj json_parser in
  match res with
    | Some ast -> ast
    | None -> raise EOF


let piqobj_of_json piqtype json :Piqobj.obj =
  Piqobj_of_json.parse_obj piqtype json


let load_json_obj json_parser :obj =
  (* check typenames, as Json parser doesn't do it unlike the Piq parser *)
  let check = true in
  let ast = read_json_ast json_parser in
  match ast with
    | `Assoc [ "_piqtype", `String typename ] ->
        (* :piqtype <typename> *)
        process_default_piqtype typename ~check;
        Piqtype typename
    | `Assoc [ "_piqtype", _ ] ->
        error ast "invalid piqtype specification"
    | `Assoc [ "_piqi", ((`Assoc _) as json_ast) ] ->
        (* :piqi <typename> *)
        let piqi = piqi_of_json json_ast in
        Piqi piqi
    | `Assoc [ "_piqi", _ ] ->
        error ast "invalid piqi specification"
    | `Null () ->
        error ast "invalid toplevel value: null"
    | `Assoc [ "_piqtype", `String typename;
               "_piqobj", ast ] ->
        let piqtype = find_piqtype typename ~check in
        let obj = piqobj_of_json piqtype ast in
        Typed_piqobj obj
    | `Assoc (("_piqtype", _ )::_) ->
        error ast "invalid type object specification"
    | _ ->
        match !default_piqtype with
          | Some piqtype ->
              if piqtype == !Piqi.piqi_def (* XXX *)
              then
                let piqi = piqi_of_json ast in
                Piqi piqi
              else
                let obj = piqobj_of_json piqtype ast in
                Piqobj obj
          | None ->
              error ast "type of object is unknown"
