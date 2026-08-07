module Error = struct
  type t =
    | Gone of { last_resource_version : string }
    | Http of string
    | Decode of string

  let to_string = function
    | Gone { last_resource_version } ->
      Printf.sprintf "410 Gone (resourceVersion=%s too old)" last_resource_version
    | Http s -> s
    | Decode s -> "decode error: " ^ s
end

type t =
  { piaf : Piaf.Client.t
  ; headers : (string * string) list
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

let create ~sw env ~base_url ?token ?ca_cert ?(insecure = false) () =
  let headers =
    ("accept", "application/json")
    :: (match token with
        | Some tok -> [ "authorization", "Bearer " ^ tok ]
        | None -> [])
  in
  let config = { Piaf.Config.default with cacert = ca_cert; allow_insecure = insecure } in
  match Piaf.Client.create ~config ~sw env (Uri.of_string base_url) with
  | Error e -> Error (Error.Http (Piaf.Error.to_string e))
  | Ok piaf ->
    Eio.Switch.on_release sw (fun () -> Piaf.Client.shutdown piaf);
    Ok { piaf; headers }

let of_env ~sw env =
  match in_cluster_config () with
  | Some (base_url, token, ca_cert) -> create ~sw env ~base_url ?token ?ca_cert ()
  | None ->
    (* Fall back to `kubectl proxy`, which handles authentication for us
       on 127.0.0.1:8001, so no token/TLS is required by default. *)
    create ~sw env ~base_url:"http://127.0.0.1:8001" ()

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
       then Error (Error.Http (Printf.sprintf "%s: %s" (Piaf.Status.to_string status) body))
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
      Error (Error.Http (Printf.sprintf "%s: %s" (Piaf.Status.to_string status) body)))
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
