module Error = struct
  type t =
    | Gone of { last_resource_version : string }
    | Api_error of Status.t
    | Http of string
    | Decode of string

  let to_string = function
    | Gone { last_resource_version } ->
      Printf.sprintf "410 Gone (resourceVersion=%s too old)" last_resource_version
    | Api_error (s : Status.t) ->
      Printf.sprintf "%s%s%s" (Option.value s.reason ~default:s.status)
        (match s.code with Some c -> Printf.sprintf " (%d)" c | None -> "")
        (match s.message with Some m -> ": " ^ m | None -> "")
    | Http s -> s
    | Decode s -> "decode error: " ^ s
end

(* Every non-2xx response's body, in practice, is a meta/v1.Status object
   -- that's what the server sends for essentially every API error. Parse
   it structurally when possible so callers can match on [reason]/[code]
   (see [Reconcile_error.of_client_error]) instead of string-matching a
   formatted message; fall back to the raw body when it isn't one (a
   misbehaving proxy, an HTML error page, ...). *)
let error_of_response piaf_status body =
  let status_line = Piaf.Status.to_string piaf_status in
  let fallback () = Error.Http (Printf.sprintf "%s: %s" status_line body) in
  match (try Some (Yojson.Safe.from_string body) with _ -> None) with
  | None -> fallback ()
  | Some json -> (
    match Status.of_json json with
    | Some s -> Error.Api_error s
    | None -> fallback ())

type t =
  { piaf : Piaf.Client.t
  ; headers : (string * string) list
  ; base_url : string
  ; ca_cert : Piaf.Cert.t option
  ; insecure : bool
  }

let read_file_opt path =
  match
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  with
  | contents -> Some (String.trim contents)
  | exception Sys_error _ -> None

(* Standard "in-cluster config": the env vars and ServiceAccount files
   client-go and kubectl use when running inside a Pod. See:
   https://kubernetes.io/docs/tasks/run-application/access-api-from-pod/ *)
let in_cluster_config () =
  match
    ( Sys.getenv_opt "KUBERNETES_SERVICE_HOST"
    , (match Sys.getenv_opt "KUBERNETES_SERVICE_PORT_HTTPS" with
       | Some _ as p -> p
       | None -> Sys.getenv_opt "KUBERNETES_SERVICE_PORT") )
  with
  | Some host, Some port ->
    let sa_dir = "/var/run/secrets/kubernetes.io/serviceaccount" in
    let ca_path = sa_dir ^ "/ca.crt" in
    Some
      ( Printf.sprintf "https://%s:%s" host port
      , read_file_opt (sa_dir ^ "/token")
      , (if Sys.file_exists ca_path then Some (Piaf.Cert.Filepath ca_path) else None) )
  | _ -> None

let connect ~sw env ~base_url ~headers ~ca_cert ~insecure =
  let config = { Piaf.Config.default with cacert = ca_cert; allow_insecure = insecure } in
  match Piaf.Client.create ~config ~sw env (Uri.of_string base_url) with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok piaf ->
    Eio.Switch.on_release sw (fun () ->
      (* Bounded defensively: an HTTP/2-level graceful close (GOAWAY, then
         waiting for the read/write loops to finish) could in principle
         take a while to complete against a slow or unresponsive peer, and
         since [Switch.on_release] hooks run in series, that would delay
         every other resource still being released after this one. The
         process is exiting either way, so there's no reason to wait long:
         abandon the connection — the OS reclaims the socket regardless —
         if it doesn't close promptly. *)
      try Eio.Time.with_timeout_exn env#clock 3.0 (fun () -> Piaf.Client.shutdown piaf) with
      | Eio.Time.Timeout -> ());
    Ok { piaf; headers; base_url; ca_cert; insecure }

let create ~sw env ~base_url ?token ?ca_cert ?(insecure = false) () =
  let headers =
    ("accept", "application/json")
    :: (match token with
        | Some tok -> [ "authorization", "Bearer " ^ tok ]
        | None -> [])
  in
  connect ~sw env ~base_url ~headers ~ca_cert ~insecure

let of_env ~sw env =
  match in_cluster_config () with
  | Some (base_url, token, ca_cert) -> create ~sw env ~base_url ?token ?ca_cert ()
  | None ->
    (* Fall back to `kubectl proxy`, which handles authentication for us
       on 127.0.0.1:8001, so no token/TLS is required by default. *)
    create ~sw env ~base_url:"http://127.0.0.1:8001" ()

let clone ~sw env t = connect ~sw env ~base_url:t.base_url ~headers:t.headers ~ca_cert:t.ca_cert ~insecure:t.insecure

let shutdown t = Piaf.Client.shutdown t.piaf

(* ---------------------------------------------------------------------- *)
(* REST path / query-string construction                                  *)
(* ---------------------------------------------------------------------- *)

let rest_path (type a) (module R : Resource.S with type t = a) ~namespace =
  let ({ group; version; _ } : Gvk.t) = R.gvk in
  let base =
    if String.equal group "" then Printf.sprintf "/api/%s" version
    else Printf.sprintf "/apis/%s/%s" group version
  in
  match namespace, R.namespaced with
  | Some ns, true -> Printf.sprintf "%s/namespaces/%s/%s" base ns R.plural
  | _ -> Printf.sprintf "%s/%s" base R.plural

let query_params ?label_selector ?field_selector ?(watch = false) ?resource_version () =
  List.filter_map Fun.id
    [ Option.map (fun s -> "labelSelector", s) label_selector
    ; Option.map (fun s -> "fieldSelector", s) field_selector
    ; (if watch then Some ("watch", "1") else None)
    ; (if watch then Some ("allowWatchBookmarks", "true") else None)
    ; Option.map (fun rv -> "resourceVersion", rv) resource_version
    ]

let target ~path ~params = Uri.of_string path |> (fun u -> Uri.add_query_params' u params) |> Uri.to_string

(* ---------------------------------------------------------------------- *)
(* LIST                                                                   *)
(* ---------------------------------------------------------------------- *)

let decode_items (type a) (module R : Resource.S with type t = a) items =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      (match R.of_json item with
       | Ok x -> go (x :: acc) rest
       | Error msg -> Error (Error.Decode msg))
  in
  go [] items

let list (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace ?label_selector
  ?field_selector () =
  let path = target ~path:(rest_path (module R) ~namespace) ~params:(query_params ?label_selector ?field_selector ()) in
  match Piaf.Client.get t.piaf ~headers:t.headers path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    (match Piaf.Body.to_string (Piaf.Response.body response) with
     | Error e -> Error (Error.Http (Piaf.Error.to_string e))
     | Ok body ->
       if not (Piaf.Status.is_successful status)
       then Error (error_of_response status body)
       else (
         let json = Yojson.Safe.from_string body in
         match Yojson.Safe.Util.(json |> member "metadata" |> member "resourceVersion" |> to_string_option) with
         | None -> Error (Error.Decode "LIST response is missing metadata.resourceVersion")
         | Some rv ->
           let items = Yojson.Safe.Util.(json |> member "items" |> to_list) in
           (match decode_items (module R) items with
            | Error _ as e -> e
            | Ok items -> Ok (items, rv))))

(* ---------------------------------------------------------------------- *)
(* WATCH                                                                  *)
(* ---------------------------------------------------------------------- *)

(* The watch endpoint streams newline-delimited JSON. Chunk boundaries from
   the HTTP layer have no relationship to line boundaries, so partial
   lines are buffered across calls. *)
let line_splitter ~f =
  let buf = Buffer.create 4096 in
  fun chunk ->
    Buffer.add_string buf chunk;
    match List.rev (String.split_on_char '\n' (Buffer.contents buf)) with
    | [] -> ()
    | last_partial_line :: complete_lines_rev ->
      Buffer.clear buf;
      Buffer.add_string buf last_partial_line;
      List.iter (fun line -> if String.length line > 0 then f line) (List.rev complete_lines_rev)

let watch (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace ?label_selector
  ?field_selector ~resource_version ~on_event () =
  let path =
    target
      ~path:(rest_path (module R) ~namespace)
      ~params:(query_params ?label_selector ?field_selector ~watch:true ~resource_version ())
  in
  match Piaf.Client.get t.piaf ~headers:t.headers path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    if Piaf.Status.to_code status = 410
    then Error (Error.Gone { last_resource_version = resource_version })
    else if not (Piaf.Status.is_successful status)
    then (
      let body = match Piaf.Body.to_string (Piaf.Response.body response) with Ok b -> b | Error _ -> "" in
      Error (error_of_response status body))
    else (
      let handle_line line =
        match Yojson.Safe.from_string line with
        | exception _ -> ()
        | json ->
          let event_type = Yojson.Safe.Util.(json |> member "type" |> to_string_option) in
          let obj_json = Yojson.Safe.Util.member "object" json in
          let deliver kind =
            match R.of_json obj_json with
            | Error _ -> ()
            | Ok obj ->
              let request = { Request.namespace = R.namespace obj; name = R.name obj } in
              on_event { Watch_event.kind; object_ = obj; request }
          in
          (match event_type with
           | Some "ADDED" -> deliver Watch_event.Added
           | Some "MODIFIED" -> deliver Watch_event.Modified
           | Some "DELETED" -> deliver Watch_event.Deleted
           | Some "BOOKMARK" -> deliver Watch_event.Bookmark
           | _ -> () (* ERROR events and anything unrecognised are dropped;
                        the HTTP-status checks above already handle the
                        common fatal cases (410, auth failures, ...). *))
      in
      match Piaf.Body.iter_string ~f:(line_splitter ~f:handle_line) (Piaf.Response.body response) with
      | Ok () -> Ok ()
      | Error e -> Error (Error.Http (Piaf.Error.to_string e)))

(* ---------------------------------------------------------------------- *)
(* GET / CREATE                                                          *)
(* ---------------------------------------------------------------------- *)

let get (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace ~name () =
  let path = Printf.sprintf "%s/%s" (rest_path (module R) ~namespace) name in
  match Piaf.Client.get t.piaf ~headers:t.headers path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    (match Piaf.Body.to_string (Piaf.Response.body response) with
     | Error e -> Error (Error.Http (Piaf.Error.to_string e))
     | Ok body ->
       if Piaf.Status.to_code status = 404
       then Ok None
       else if not (Piaf.Status.is_successful status)
       then Error (error_of_response status body)
       else (
         match R.of_json (Yojson.Safe.from_string body) with
         | Ok obj -> Ok (Some obj)
         | Error msg -> Error (Error.Decode msg)))

let create_object (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace (obj : a) =
  let path = rest_path (module R) ~namespace in
  let body = Piaf.Body.of_string (Yojson.Safe.to_string (R.to_json obj)) in
  let headers = ("content-type", "application/json") :: t.headers in
  match Piaf.Client.post t.piaf ~headers ~body path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    (match Piaf.Body.to_string (Piaf.Response.body response) with
     | Error e -> Error (Error.Http (Piaf.Error.to_string e))
     | Ok body ->
       if not (Piaf.Status.is_successful status)
       then Error (error_of_response status body)
       else (
         match R.of_json (Yojson.Safe.from_string body) with
         | Ok obj -> Ok obj
         | Error msg -> Error (Error.Decode msg)))

(* ---------------------------------------------------------------------- *)
(* UPDATE / UPDATE STATUS                                                 *)
(* ---------------------------------------------------------------------- *)

let put_object (type a) t ~resource:(module R : Resource.S with type t = a) ~subresource (obj : a) =
  let base = rest_path (module R) ~namespace:(R.namespace obj) in
  let object_path =
    match subresource with
    | None -> Printf.sprintf "%s/%s" base (R.name obj)
    | Some sub -> Printf.sprintf "%s/%s/%s" base (R.name obj) sub
  in
  let body = Piaf.Body.of_string (Yojson.Safe.to_string (R.to_json obj)) in
  let headers = ("content-type", "application/json") :: t.headers in
  match Piaf.Client.put t.piaf ~headers ~body object_path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    if Piaf.Status.is_successful status
    then Ok ()
    else (
      let body = match Piaf.Body.to_string (Piaf.Response.body response) with Ok b -> b | Error _ -> "" in
      Error (error_of_response status body))

let update t ~resource obj = put_object t ~resource ~subresource:None obj
let update_status t ~resource obj = put_object t ~resource ~subresource:(Some "status") obj

(* ---------------------------------------------------------------------- *)
(* DELETE                                                                 *)
(* ---------------------------------------------------------------------- *)

let delete (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace ~name ?resource_version () =
  let path = Printf.sprintf "%s/%s" (rest_path (module R) ~namespace) name in
  let headers, body =
    match resource_version with
    | None -> t.headers, None
    | Some rv ->
      (* Conditional delete — optimistic concurrency expressed as a DELETE
         body's [preconditions], exactly how a PUT's resourceVersion check
         works: the object is deleted only if its current resourceVersion
         still matches [rv]. A stale caller gets a 409 rather than silently
         deleting an object someone else just updated. Mirrors client-go's
         [DeleteOptions]. Useful for e.g. garbage-collecting a child only
         if it's still the one we think it is. *)
      let preconditions = `Assoc [ "preconditions", `Assoc [ "resourceVersion", `String rv ] ] in
      ("content-type", "application/json") :: t.headers, Some (Piaf.Body.of_string (Yojson.Safe.to_string preconditions))
  in
  match Piaf.Client.delete t.piaf ~headers ?body path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    if Piaf.Status.is_successful status
    then Ok ()
    else (
      let body = match Piaf.Body.to_string (Piaf.Response.body response) with Ok b -> b | Error _ -> "" in
      Error (error_of_response status body))

(* ---------------------------------------------------------------------- *)
(* PATCH                                                                  *)
(* ---------------------------------------------------------------------- *)

let patch (type a) t ~resource:(module R : Resource.S with type t = a) ?namespace ~name ~body () =
  let path = Printf.sprintf "%s/%s" (rest_path (module R) ~namespace) name in
  let headers = ("content-type", "application/merge-patch+json") :: t.headers in
  let body = Piaf.Body.of_string (Yojson.Safe.to_string body) in
  match Piaf.Client.patch t.piaf ~headers ~body path with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    (match Piaf.Body.to_string (Piaf.Response.body response) with
     | Error e -> Error (Error.Http (Piaf.Error.to_string e))
     | Ok resp ->
       if not (Piaf.Status.is_successful status)
       then Error (error_of_response status resp)
       else (
         match R.of_json (Yojson.Safe.from_string resp) with
         | Ok obj -> Ok obj
         | Error msg -> Error (Error.Decode msg)))
