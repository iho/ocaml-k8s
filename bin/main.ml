(* k8s_watch — minimal Kubernetes client: LIST pods, then WATCH them.

   OCaml 5 + Eio, using Piaf (https://github.com/anmonteiro/piaf) as the
   HTTP/1.1 / HTTP/2 + TLS client. Everything is direct-style: no Lwt, no
   Async, no monadic [let*] binds — blocking calls just block the current
   fiber, and Eio's scheduler runs other fibers while they wait.

   Build:   dune build
   Run:     dune exec bin/main.exe -- [options]
   See README.md for full usage against `kubectl proxy` or a real cluster. *)

open Eio

(* ---------------------------------------------------------------------- *)
(* Authentication / connection settings                                   *)
(* ---------------------------------------------------------------------- *)

type auth =
  { base_url : string (* e.g. "https://10.96.0.1:443" or "http://127.0.0.1:8001" *)
  ; token : string option (* bearer token, sent as [Authorization: Bearer ...] *)
  ; ca_cert : Piaf.Cert.t option (* CA used to verify the API server's certificate *)
  ; insecure : bool (* skip TLS verification entirely (testing only) *)
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

(* Standard "in-cluster config": the same environment variables and
   ServiceAccount files that client-go and kubectl use when running inside a
   Pod. See:
   https://kubernetes.io/docs/tasks/run-application/access-api-from-pod/ *)
let in_cluster_auth () =
  match
    ( Sys.getenv_opt "KUBERNETES_SERVICE_HOST"
    , (match Sys.getenv_opt "KUBERNETES_SERVICE_PORT_HTTPS" with
       | Some _ as p -> p
       | None -> Sys.getenv_opt "KUBERNETES_SERVICE_PORT") )
  with
  | Some host, Some port ->
    let sa_dir = "/var/run/secrets/kubernetes.io/serviceaccount" in
    Some
      { base_url = Printf.sprintf "https://%s:%s" host port
      ; token = read_file_opt (sa_dir ^ "/token")
      ; ca_cert =
          (let ca_path = sa_dir ^ "/ca.crt" in
           if Sys.file_exists ca_path then Some (Piaf.Cert.Filepath ca_path) else None)
      ; insecure = false
      }
  | _ -> None

(* ---------------------------------------------------------------------- *)
(* CLI                                                                    *)
(* ---------------------------------------------------------------------- *)

type cli =
  { mutable namespace : string option
  ; mutable server : string option
  ; mutable token : string option
  ; mutable token_file : string option
  ; mutable ca_cert_path : string option
  ; mutable insecure : bool
  }

let parse_cli () =
  let cli =
    { namespace = None
    ; server = None
    ; token = None
    ; token_file = None
    ; ca_cert_path = None
    ; insecure = false
    }
  in
  let spec =
    [ ( "-n"
      , Arg.String (fun s -> cli.namespace <- Some s)
      , "NAMESPACE   Watch this namespace only (default: all namespaces)" )
    ; ( "--server"
      , Arg.String (fun s -> cli.server <- Some s)
      , "URL   API server base URL, e.g. https://host:6443, or \
         http://127.0.0.1:8001 for `kubectl proxy`. Defaults to in-cluster \
         config if KUBERNETES_SERVICE_HOST is set, else \
         http://127.0.0.1:8001" )
    ; "--token", Arg.String (fun s -> cli.token <- Some s), "TOKEN   Bearer token"
    ; ( "--token-file"
      , Arg.String (fun s -> cli.token_file <- Some s)
      , "PATH   Read the bearer token from this file" )
    ; ( "--ca-cert"
      , Arg.String (fun s -> cli.ca_cert_path <- Some s)
      , "PATH   PEM file used to verify the API server's certificate" )
    ; ( "--insecure"
      , Arg.Unit (fun () -> cli.insecure <- true)
      , "        Skip TLS certificate verification (testing only)" )
    ]
  in
  Arg.parse spec (fun _ -> ()) "k8s_watch [options]";
  cli

let resolve_auth (cli : cli) =
  let local ~server =
    { base_url = server
    ; token =
        (match cli.token with
         | Some _ as t -> t
         | None -> Option.bind cli.token_file read_file_opt)
    ; ca_cert = Option.map (fun p -> Piaf.Cert.Filepath p) cli.ca_cert_path
    ; insecure = cli.insecure
    }
  in
  match cli.server with
  | Some server -> local ~server
  | None ->
    (match in_cluster_auth () with
     | Some auth -> auth
     | None ->
       (* Fall back to `kubectl proxy`, which handles authentication for us
          on 127.0.0.1:8001, so no token/TLS is required by default. *)
       local ~server:"http://127.0.0.1:8001")

(* ---------------------------------------------------------------------- *)
(* HTTP / Kubernetes helpers                                              *)
(* ---------------------------------------------------------------------- *)

let headers_of_auth (auth : auth) =
  let base = [ "accept", "application/json" ] in
  match auth.token with
  | Some tok -> ("authorization", "Bearer " ^ tok) :: base
  | None -> base

let piaf_config (auth : auth) =
  { Piaf.Config.default with
    Piaf.Config.cacert = auth.ca_cert
  ; allow_insecure = auth.insecure
  }

let pods_path ~namespace =
  match namespace with
  | Some ns -> Printf.sprintf "/api/v1/namespaces/%s/pods" ns
  | None -> "/api/v1/pods"

(* ---------------------------------------------------------------------- *)
(* JSON helpers                                                           *)
(* ---------------------------------------------------------------------- *)

open Yojson.Safe.Util

let pod_name json = json |> member "metadata" |> member "name" |> to_string_option

let resource_version json =
  json |> member "metadata" |> member "resourceVersion" |> to_string_option

(* ---------------------------------------------------------------------- *)
(* LIST                                                                   *)
(* ---------------------------------------------------------------------- *)

(* Issue a plain LIST request and return the resourceVersion to watch from. *)
let list_pods client ~headers ~path =
  match Piaf.Client.get client ~headers path with
  | Error e -> failwith (Printf.sprintf "LIST request failed: %s" (Piaf.Error.to_string e))
  | Ok response ->
    let status = Piaf.Response.status response in
    let body =
      match Piaf.Body.to_string (Piaf.Response.body response) with
      | Ok body -> body
      | Error e -> failwith (Printf.sprintf "failed to read LIST body: %s" (Piaf.Error.to_string e))
    in
    if not (Piaf.Status.is_successful status)
    then failwith (Printf.sprintf "LIST failed with status %s: %s" (Piaf.Status.to_string status) body);
    let json = Yojson.Safe.from_string body in
    let rv =
      match resource_version json with
      | Some rv -> rv
      | None -> failwith "LIST response is missing metadata.resourceVersion"
    in
    let items = json |> member "items" |> to_list in
    List.iter
      (fun item ->
        traceln "LIST    %-40s resourceVersion=%s"
          (Option.value (pod_name item) ~default:"<unknown>")
          (Option.value (resource_version item) ~default:"?"))
      items;
    traceln "-- LIST complete: %d pod(s), resourceVersion=%s --" (List.length items) rv;
    rv

(* ---------------------------------------------------------------------- *)
(* WATCH                                                                  *)
(* ---------------------------------------------------------------------- *)

(* The watch endpoint streams newline-delimited JSON:
     {"type":"ADDED"|"MODIFIED"|"DELETED"|"BOOKMARK"|"ERROR","object":{...}}
   Chunk boundaries from the HTTP layer have no relationship to line
   boundaries, so we buffer partial lines ourselves and dispatch each
   complete one as it arrives. *)
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

let handle_watch_event line =
  match Yojson.Safe.from_string line with
  | exception ex -> traceln "WATCH   could not parse event (%s): %s" (Printexc.to_string ex) line
  | json ->
    let event_type = json |> member "type" |> to_string_option |> Option.value ~default:"UNKNOWN" in
    let obj = member "object" json in
    (match event_type with
     | "ERROR" -> traceln "WATCH   ERROR event: %s" (Yojson.Safe.to_string obj)
     | "BOOKMARK" ->
       traceln "WATCH   BOOKMARK resourceVersion=%s" (Option.value (resource_version obj) ~default:"?")
     | _ ->
       traceln "WATCH   %-8s %-40s resourceVersion=%s" event_type
         (Option.value (pod_name obj) ~default:"<unknown>")
         (Option.value (resource_version obj) ~default:"?"))

(* Start a watch from [resource_version] and stream events until the
   connection ends, errors out, or the enclosing switch is cancelled
   (e.g. Ctrl-C — see [main] below). On 410 Gone (the resourceVersion has
   been compacted out of etcd's history) we just stop; a production client
   would re-LIST and restart the watch from the fresh resourceVersion. *)
let watch_pods client ~headers ~path ~resource_version =
  let watch_path =
    Printf.sprintf "%s?watch=1&allowWatchBookmarks=true&resourceVersion=%s" path
      (Uri.pct_encode resource_version)
  in
  traceln "-- starting WATCH at resourceVersion=%s --" resource_version;
  match Piaf.Client.get client ~headers watch_path with
  | Error e -> traceln "WATCH request failed: %s" (Piaf.Error.to_string e)
  | Ok response ->
    let status = Piaf.Response.status response in
    if Piaf.Status.to_code status = 410
    then traceln "WATCH got 410 Gone (resourceVersion too old) — stopping. Re-run to re-LIST and resume."
    else if not (Piaf.Status.is_successful status)
    then (
      let body = match Piaf.Body.to_string (Piaf.Response.body response) with Ok b -> b | Error _ -> "" in
      traceln "WATCH failed with status %s: %s" (Piaf.Status.to_string status) body)
    else (
      match Piaf.Body.iter_string ~f:(line_splitter ~f:handle_watch_event) (Piaf.Response.body response) with
      | Ok () -> traceln "-- WATCH stream closed by server --"
      | Error e -> traceln "-- WATCH stream error: %s --" (Piaf.Error.to_string e))

(* ---------------------------------------------------------------------- *)
(* main                                                                   *)
(* ---------------------------------------------------------------------- *)

let () =
  let cli = parse_cli () in
  let auth = resolve_auth cli in
  let headers = headers_of_auth auth in
  let config = piaf_config auth in
  let path = pods_path ~namespace:cli.namespace in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    (* Ctrl-C cancels the switch instead of killing the process outright.
       Eio propagates that cancellation into whichever fiber is currently
       blocked — here, the watch fiber's streaming HTTP read — which then
       unwinds through the [on_release] hook below and closes the
       connection before the process exits. *)
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
           traceln "received SIGINT, shutting down...";
           Switch.fail sw Exit));
    traceln "Connecting to %s ..." auth.base_url;
    match Piaf.Client.create ~config ~sw env (Uri.of_string auth.base_url) with
    | Error e -> traceln "failed to connect: %s" (Piaf.Error.to_string e)
    | Ok client ->
      Switch.on_release sw (fun () ->
          traceln "closing connection...";
          Piaf.Client.shutdown client);
      let resource_version = list_pods client ~headers ~path in
      (* Run the watch as its own fiber under [sw] so Eio's structured
         concurrency owns its lifetime: it is cancelled and joined
         automatically whenever [sw] is torn down. *)
      Fiber.fork ~sw (fun () -> watch_pods client ~headers ~path ~resource_version)
  with Exit -> traceln "stopped."
