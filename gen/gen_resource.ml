(* A small, selective CRD-to-OCaml generator — NOT a general OpenAPI
   compiler (see the design discussion this was built from). Reads one CRD
   YAML file's .spec.versions[] (picking the storage version, falling back
   to the first served one, falling back to the first version present) and
   prints an OCaml source implementing K8s.Resource.S for it to stdout.

   Usage: gen_resource.exe path/to/crd.yaml > generated_module.ml

   The emitted module needs `(preprocess (pps ppx_deriving_yojson))` and
   `k8s` + `ppx_deriving_yojson.runtime` in its dune stanza's libraries —
   see generated/dune for the reference wiring.

   Any schema construct this doesn't understand (oneOf/anyOf/allOf, a
   schema-less "object", additionalProperties/maps, ...) becomes a
   [Yojson.Safe.t] passthrough field rather than blocking generation or
   guessing wrong — the generator's job is to save typing on the common
   case, not to achieve 100% schema coverage. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic (in_channel_length ic))

(* ---------------------------------------------------------------------- *)
(* Yaml.value -> Yojson.Safe.t                                            *)
(* ---------------------------------------------------------------------- *)

let rec yaml_to_json (v : Yaml.value) : Yojson.Safe.t =
  match v with
  | `Null -> `Null
  | `Bool b -> `Bool b
  | `Float f ->
    (* Yaml collapses every number into `Float; recover plain integers
       (schema fields like "code"/array indices are always integral in
       practice) so the emitted code sees `Int, not `Float, where it
       matters for readability of intermediate debugging, though nothing
       here actually branches on the distinction. *)
    if Float.is_integer f && Float.abs f < 1e15 then `Int (int_of_float f) else `Float f
  | `String s -> `String s
  | `A l -> `List (List.map yaml_to_json l)
  | `O kvs -> `Assoc (List.map (fun (k, v) -> k, yaml_to_json v) kvs)

let of_yaml_file path =
  match Yaml.of_string (read_file path) with
  | Ok v -> yaml_to_json v
  | Error (`Msg m) -> failwith (Printf.sprintf "failed to parse %s as YAML: %s" path m)

(* ---------------------------------------------------------------------- *)
(* naming                                                                 *)
(* ---------------------------------------------------------------------- *)

(* "readyReplicas" -> "ready_replicas". A heuristic (consecutive
   capitals, e.g. an "HTTPPort"-style field, would come out a bit oddly —
   "h_t_t_p_port" — but Kubernetes CRD/built-in field names in practice
   are simple camelCase, not that). *)
let snake_case name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri
    (fun i c ->
      if c >= 'A' && c <= 'Z'
      then (
        if i > 0 then Buffer.add_char buf '_';
        Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c)
    name;
  Buffer.contents buf

(* ---------------------------------------------------------------------- *)
(* schema walking                                                         *)
(* ---------------------------------------------------------------------- *)

open Yojson.Safe.Util

type ty =
  | Tstring
  | Tint
  | Tfloat
  | Tbool
  | Tlist of ty
  | Trecord of string
  | Tjson (* fallback: Yojson.Safe.t, for anything not understood *)

let rec ty_to_ocaml = function
  | Tstring -> "string"
  | Tint -> "int"
  | Tfloat -> "float"
  | Tbool -> "bool"
  | Tlist t -> ty_to_ocaml t ^ " list"
  | Trecord name -> name
  | Tjson -> "Yojson.Safe.t"

type field =
  { json_key : string
  ; ocaml_name : string
  ; required : bool
  ; ty : ty
  }

let emit_record out name fields =
  Buffer.add_string out (Printf.sprintf "type %s =\n  {" name);
  List.iteri
    (fun i f ->
      let base_ty = ty_to_ocaml f.ty in
      let ty_str = if f.required then base_ty else base_ty ^ " option" in
      let key_attr = if String.equal f.json_key f.ocaml_name then "" else Printf.sprintf " [@key %S]" f.json_key in
      let default_attr = if f.required then "" else " [@default None]" in
      Buffer.add_string out
        (Printf.sprintf "%s %s : %s%s%s" (if i = 0 then "" else "\n  ;") f.ocaml_name ty_str key_attr default_attr))
    fields;
  (* [strict = false]: real Kubernetes objects always carry fields this
     schema-derived record doesn't declare (every object has apiVersion/
     kind at minimum, which nothing here models -- see Type_meta -- plus
     whatever a newer API server version adds); ppx_deriving_yojson's
     default *is* strict, rejecting any JSON key without a matching
     field, so decoding any real object without this would always fail.
     Found by running gen_resource.exe's own output against a real
     cluster: every LIST failed until this was added. *)
  Buffer.add_string out "\n  }\n[@@deriving yojson { strict = false }]\n\n"

(* Emits nested record type declarations (deepest / most-nested first,
   satisfying OCaml's before-use ordering for separate, non-[and]-chained
   type declarations — guaranteed by recursing into every field *before*
   this level calls [emit_record]) into [out]; returns the [ty] for
   [schema] itself. [path] names the record this level would become if
   it turns out to be an object, e.g. "spec" or "spec_container". *)
let rec walk out ~path (schema : Yojson.Safe.t) : ty =
  match schema |> member "type" |> to_string_option with
  | Some "string" -> Tstring
  | Some "integer" -> Tint
  | Some "number" -> Tfloat
  | Some "boolean" -> Tbool
  | Some "array" -> Tlist (walk out ~path:(path ^ "_item") (member "items" schema))
  | Some "object" -> (
    match member "properties" schema with
    | `Assoc (_ :: _ as props) ->
      let required =
        match member "required" schema with
        | `List l -> List.filter_map to_string_option l
        | _ -> []
      in
      let fields =
        List.map
          (fun (json_key, field_schema) ->
            let field_ty = walk out ~path:(path ^ "_" ^ snake_case json_key) field_schema in
            { json_key; ocaml_name = snake_case json_key; required = List.mem json_key required; ty = field_ty })
          props
      in
      emit_record out path fields;
      Trecord path
    | _ -> Tjson (* a map (additionalProperties) or a schema-less object *))
  | _ -> Tjson (* oneOf/anyOf/allOf, missing "type", or anything else unhandled *)

(* ---------------------------------------------------------------------- *)
(* driver                                                                 *)
(* ---------------------------------------------------------------------- *)

let choose_version versions =
  match List.find_opt (fun v -> member "storage" v |> to_bool_option = Some true) versions with
  | Some v -> v
  | None -> (
    match List.find_opt (fun v -> member "served" v |> to_bool_option = Some true) versions with
    | Some v -> v
    | None -> (
      match versions with
      | v :: _ -> v
      | [] -> failwith "CRD has no .spec.versions entries"))

let generate crd_json =
  let spec_crd = member "spec" crd_json in
  let group = spec_crd |> member "group" |> to_string in
  let names = member "names" spec_crd in
  let kind = names |> member "kind" |> to_string in
  let plural = names |> member "plural" |> to_string in
  let namespaced =
    match spec_crd |> member "scope" |> to_string_option with
    | Some "Cluster" -> false
    | _ -> true
  in
  let versions = spec_crd |> member "versions" |> to_list in
  let chosen = choose_version versions in
  let version_name = chosen |> member "name" |> to_string in
  let has_status_subresource =
    match member "subresources" chosen with
    | `Assoc fields -> List.mem_assoc "status" fields
    | _ -> false
  in
  let schema = chosen |> member "schema" |> member "openAPIV3Schema" |> member "properties" in
  let out = Buffer.create 4096 in
  Buffer.add_string out
    (Printf.sprintf
       "(* Generated by gen/gen_resource.ml from a %s/%s CRD (kind=%s) -- do not hand-edit.\n\
       \   If the generator's coverage doesn't handle a field you need, either extend it or\n\
       \   hand-maintain this file directly instead of round-tripping through it again. *)\n\n"
       group version_name kind);
  Buffer.add_string out "open K8s\n\n";
  let (_ : ty) = walk out ~path:"spec" (member "spec" schema) in
  if has_status_subresource
  then (
    let (_ : ty) = walk out ~path:"status" (member "status" schema) in
    ())
  else Buffer.add_string out "type status = unit\n\n";
  Buffer.add_string out "type t =\n  { metadata : Object_meta.t\n  ; spec : spec\n";
  if has_status_subresource then Buffer.add_string out "  ; status : status option [@default None]\n";
  Buffer.add_string out "  }\n[@@deriving yojson { strict = false }]\n\n";
  Buffer.add_string out (Printf.sprintf "let gvk = Gvk.{ group = %S; version = %S; kind = %S }\n" group version_name kind);
  Buffer.add_string out (Printf.sprintf "let plural = %S\n" plural);
  Buffer.add_string out (Printf.sprintf "let namespaced = %B\n\n" namespaced);
  Buffer.add_string out "let of_json = of_yojson\n";
  (* [to_yojson] alone only serializes [t]'s own fields (metadata/spec/
     status) -- apiVersion/kind aren't record fields (nothing decodes
     them; strict=false above means they're simply ignored on the way
     in), so they have to be injected on the way out, same as the
     hand-written examples do. Skipping this doesn't fail to compile —
     it fails at request time instead: found by PUTting a finalizer
     addition and getting a 400 "Object 'Kind' is missing", which is
     exactly what Client.Error.Api_error's now-structured Status.t made
     easy to read at a glance instead of parsing a raw error string. *)
  Buffer.add_string out "let to_json t =\n";
  Buffer.add_string out "  match to_yojson t with\n";
  Buffer.add_string out
    "  | `Assoc fields -> `Assoc ((\"apiVersion\", `String (Gvk.api_version gvk)) :: (\"kind\", `String gvk.kind) :: \
     fields)\n";
  Buffer.add_string out "  | other -> other\n";
  if has_status_subresource
  then (
    Buffer.add_string out "let status_of_json = status_of_yojson\n";
    Buffer.add_string out "let status_to_json = status_to_yojson\n";
    Buffer.add_string out "let status t = t.status\n";
    Buffer.add_string out "let with_status t s = { t with status = Some s }\n")
  else (
    Buffer.add_string out "let status_of_json _ = Ok ()\n";
    Buffer.add_string out "let status_to_json () = `Null\n";
    Buffer.add_string out "let status (_ : t) = None\n";
    Buffer.add_string out "let with_status t () = t\n");
  Buffer.add_string out "let name t = t.metadata.Object_meta.name\n";
  Buffer.add_string out "let namespace t = t.metadata.Object_meta.namespace\n";
  Buffer.add_string out "let resource_version t = t.metadata.Object_meta.resource_version\n";
  Buffer.add_string out "let uid t = t.metadata.Object_meta.uid\n";
  Buffer.add_string out "let deletion_timestamp t = t.metadata.Object_meta.deletion_timestamp\n";
  Buffer.add_string out "let finalizers t = t.metadata.Object_meta.finalizers\n";
  Buffer.contents out

let () =
  match Sys.argv with
  | [| _; crd_path |] -> print_string (generate (of_yaml_file crd_path))
  | _ ->
    prerr_endline "usage: gen_resource.exe path/to/crd.yaml > generated_module.ml";
    exit 1
