module Request = struct
  type operation =
    [ `Create
    | `Update
    | `Delete
    | `Connect
    | `Other of string
    ]

  type t =
    { uid : string
    ; operation : operation
    ; kind : Gvk.t
    ; namespace : string option
    ; name : string
    ; object_ : Yojson.Safe.t option
    ; old_object : Yojson.Safe.t option
    ; dry_run : bool
    }

  let decode_object (type a) ~(resource : (module Resource.S with type t = a)) (t : t) : (a, string) result =
    let module R = (val resource) in
    match t.object_ with
    | None -> Error "admission request has no object (likely a DELETE)"
    | Some j -> R.of_json j

  let decode_old_object (type a) ~(resource : (module Resource.S with type t = a)) (t : t) : (a, string) result =
    let module R = (val resource) in
    match t.old_object with
    | None -> Error "admission request has no oldObject (likely a CREATE)"
    | Some j -> R.of_json j

  let of_json (review : Yojson.Safe.t) : t =
    let open Yojson.Safe.Util in
    let req = member "request" review in
    let uid = req |> member "uid" |> to_string in
    let operation =
      match req |> member "operation" |> to_string with
      | "CREATE" -> `Create
      | "UPDATE" -> `Update
      | "DELETE" -> `Delete
      | "CONNECT" -> `Connect
      | other -> `Other other
    in
    let kind_j = member "kind" req in
    let kind : Gvk.t =
      { group = kind_j |> member "group" |> to_string
      ; version = kind_j |> member "version" |> to_string
      ; kind = kind_j |> member "kind" |> to_string
      }
    in
    let namespace = req |> member "namespace" |> to_string_option in
    let name = req |> member "name" |> to_string_option |> Option.value ~default:"" in
    let object_ =
      match member "object" req with
      | `Null -> None
      | j -> Some j
    in
    let old_object =
      match member "oldObject" req with
      | `Null -> None
      | j -> Some j
    in
    let dry_run = req |> member "dryRun" |> to_bool_option |> Option.value ~default:false in
    { uid; operation; kind; namespace; name; object_; old_object; dry_run }
end

type decision =
  | Allow
  | Deny of string
  | Allow_with_patch of Yojson.Safe.t

let response_json ~api_version ~kind ~uid (decision : decision) : Yojson.Safe.t =
  let response =
    match decision with
    | Allow -> [ "uid", `String uid; "allowed", `Bool true ]
    | Deny message -> [ "uid", `String uid; "allowed", `Bool false; "status", `Assoc [ "message", `String message ] ]
    | Allow_with_patch patch ->
      let patch_b64 = patch |> Yojson.Safe.to_string |> Base64.encode_string in
      [ "uid", `String uid; "allowed", `Bool true; "patchType", `String "JSONPatch"; "patch", `String patch_b64 ]
  in
  `Assoc [ "apiVersion", `String api_version; "kind", `String kind; "response", `Assoc response ]

(* The API server's own webhook client appends its own query string, e.g.
   "?timeout=5s" (from the WebhookConfiguration's timeoutSeconds) -- found
   by hand against a real cluster: an exact-match comparison against
   [path] rejected every real call as 404 despite curl against the same
   URL (no query string) working fine. *)
let path_without_query target =
  match String.index_opt target '?' with
  | Some i -> String.sub target 0 i
  | None -> target

let handle_request ~path ~(handle : Request.t -> decision) (ctx : _ Piaf.Server.ctx) : Piaf.Response.t =
  let request = ctx.request in
  if path_without_query (Piaf.Request.target request) <> path || Piaf.Request.meth request <> `POST
  then Piaf.Response.of_string ~body:"not found\n" `Not_found
  else (
    match Piaf.Body.to_string (Piaf.Request.body request) with
    | Error _ -> Piaf.Response.of_string ~body:"failed to read request body\n" `Bad_request
    | Ok body_str -> (
      match Yojson.Safe.from_string body_str with
      | exception Yojson.Json_error msg -> Piaf.Response.of_string ~body:(Printf.sprintf "invalid JSON: %s\n" msg) `Bad_request
      | review ->
        let open Yojson.Safe.Util in
        let api_version =
          review |> member "apiVersion" |> to_string_option |> Option.value ~default:"admission.k8s.io/v1"
        in
        let kind = review |> member "kind" |> to_string_option |> Option.value ~default:"AdmissionReview" in
        let req = Request.of_json review in
        let decision = handle req in
        let body = Yojson.Safe.to_string (response_json ~api_version ~kind ~uid:req.uid decision) in
        Piaf.Response.of_string ~headers:(Piaf.Headers.of_list [ "content-type", "application/json" ]) ~body `OK))

let serve ~sw env ~port ~cert ~private_key ~path handle =
  let https_address = `Tcp (Eio.Net.Ipaddr.V4.any, port) in
  let https = Piaf.Server.Config.HTTPS.create ~address:https_address (cert, private_key) in
  (* Piaf.Server.Command.start always binds a *second*, plaintext listener
     at [Config.t]'s own top-level [address] alongside [https.address] --
     there's no config knob to disable it (its own source says as much:
     "TODO: config option to listen only in HTTPS?"). Pointing both at the
     same [port] silently created two listeners racing for the same
     connections instead of erroring, so a TLS ClientHello could get
     routed to the plaintext handler and vice versa -- found by hand
     against a real cluster: curl's TLS handshake failed with a garbled
     "protocol version" alert that turned out to be the plaintext
     handler's HTTP/1.1 "400 Bad Request" bytes arriving where a
     ServerHello was expected. Binding the throwaway plaintext listener to
     an OS-assigned ephemeral port (0) instead of [port] keeps the two
     listeners on genuinely different sockets. *)
  let plaintext_address = `Tcp (Eio.Net.Ipaddr.V4.any, 0) in
  let config = Piaf.Server.Config.create ~https plaintext_address in
  let server = Piaf.Server.create ~config (handle_request ~path ~handle) in
  let (_ : Piaf.Server.Command.t) = Piaf.Server.Command.start ~sw env server in
  ()
