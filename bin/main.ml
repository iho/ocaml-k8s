(* k8s_watch — minimal Kubernetes client: LIST pods, then WATCH them.

   This is now a thin CLI wrapper around the generalised [K8s.Client]
   (see lib/), which implements LIST+WATCH for any [K8s.Resource.S]
   instead of being hardcoded to Pods the way the first version of this
   file was. Pods are treated here as an [Unstructured] resource since
   there's no typed Pod binding yet — the same shortcut a CRD without
   typed bindings would use.

   Build:   dune build
   Run:     dune exec bin/main.exe -- [options]
   See README.md for full usage against `kubectl proxy` or a real cluster. *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

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

let read_file_opt path =
  match
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  with
  | contents -> Some (String.trim contents)
  | exception Sys_error _ -> None

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

(* ---------------------------------------------------------------------- *)
(* main                                                                   *)
(* ---------------------------------------------------------------------- *)

let () =
  let cli = parse_cli () in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
           traceln "received SIGINT, shutting down...";
           Switch.fail sw Exit));
    let client =
      match cli.server with
      | Some base_url ->
        let token =
          match cli.token with
          | Some _ as t -> t
          | None -> Option.bind cli.token_file read_file_opt
        in
        let ca_cert = Option.map (fun p -> Piaf.Cert.Filepath p) cli.ca_cert_path in
        traceln "Connecting to %s ..." base_url;
        Client.create ~sw env ~base_url ?token ?ca_cert ~insecure:cli.insecure ()
      | None -> Client.of_env ~sw env
    in
    match client with
    | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok client ->
      (match Client.list client ~resource:(module Pods) ?namespace:cli.namespace () with
       | Error e -> traceln "LIST failed: %s" (Client.Error.to_string e)
       | Ok (pods, resource_version) ->
         List.iter
           (fun p ->
             traceln "LIST    %-40s resourceVersion=%s" (Pods.name p)
               (Option.value (Pods.resource_version p) ~default:"?"))
           pods;
         traceln "-- LIST complete: %d pod(s), resourceVersion=%s --" (List.length pods)
           resource_version;
         (* Run the watch as its own fiber under [sw] so Eio's structured
            concurrency owns its lifetime: it is cancelled when [sw] is
            torn down (e.g. on the SIGINT handler above), which interrupts
            the blocked streaming HTTP read inside [Client.watch]. *)
         Fiber.fork ~sw (fun () ->
             traceln "-- starting WATCH at resourceVersion=%s --" resource_version;
             let on_event (ev : Pods.t Watch_event.t) =
               let kind_str =
                 match ev.kind with
                 | Added -> "ADDED"
                 | Modified -> "MODIFIED"
                 | Deleted -> "DELETED"
                 | Bookmark -> "BOOKMARK"
               in
               traceln "WATCH   %-8s %-40s resourceVersion=%s" kind_str
                 (Request.to_string ev.request)
                 (Option.value (Pods.resource_version ev.object_) ~default:"?")
             in
             match
               Client.watch client ~resource:(module Pods) ?namespace:cli.namespace
                 ~resource_version ~on_event ()
             with
             | Ok () -> traceln "-- WATCH stream ended --"
             | Error e -> traceln "-- WATCH error: %s --" (Client.Error.to_string e)))
  with Exit -> traceln "stopped."
