(* Manual verification tool for the *typed* Resource/Reconciler/Controller
   design: a real record type (not Yojson.Safe.t) for a toy CRD, decoded
   from real JSON, with a genuine PUT to its /status subresource against a
   real API server. Requires the CRD + a sample object to exist first:
     kubectl apply -f examples/webapp-crd.yaml
     kubectl apply -f examples/webapp-sample.yaml
     kubectl proxy --port=8001 &
     dune exec bin/webapp_demo.exe -- default *)

open Eio
open K8s

module Web_app = struct
  type spec =
    { image : string
    ; replicas : int
    }

  type status =
    { ready_replicas : int
    ; observed_generation : int
    }

  type t =
    { metadata : Object_meta.t
    ; spec : spec
    ; status : status option
    }

  let gvk = Gvk.{ group = "example.com"; version = "v1"; kind = "WebApp" }
  let plural = "webapps"
  let namespaced = true

  let of_json j =
    let open Yojson.Safe.Util in
    match
      let metadata = Object_meta.of_json (member "metadata" j) in
      let spec_json = member "spec" j in
      let spec =
        { image = spec_json |> member "image" |> to_string; replicas = spec_json |> member "replicas" |> to_int }
      in
      let status =
        match member "status" j with
        | `Null -> None
        | s ->
          Some
            { ready_replicas = s |> member "readyReplicas" |> to_int
            ; observed_generation = s |> member "observedGeneration" |> to_int
            }
      in
      { metadata; spec; status }
    with
    | t -> Ok t
    | exception exn -> Error (Printexc.to_string exn)

  let status_to_json (s : status) =
    `Assoc [ "readyReplicas", `Int s.ready_replicas; "observedGeneration", `Int s.observed_generation ]

  let to_json t =
    `Assoc
      (List.filter_map Fun.id
         [ Some ("apiVersion", `String (Gvk.api_version gvk))
         ; Some ("kind", `String gvk.kind)
         ; Some ("metadata", Object_meta.to_json t.metadata)
         ; Some ("spec", `Assoc [ "image", `String t.spec.image; "replicas", `Int t.spec.replicas ])
         ; Option.map (fun s -> "status", status_to_json s) t.status
         ])

  let status_of_json j =
    let open Yojson.Safe.Util in
    match
      { ready_replicas = j |> member "readyReplicas" |> to_int
      ; observed_generation = j |> member "observedGeneration" |> to_int
      }
    with
    | s -> Ok s
    | exception exn -> Error (Printexc.to_string exn)

  let status t = t.status
  let with_status t s = { t with status = Some s }
  let name t = t.metadata.name
  let namespace t = t.metadata.namespace
  let resource_version t = t.metadata.resource_version
  let uid t = t.metadata.uid
  let deletion_timestamp t = t.metadata.deletion_timestamp
  let finalizers t = t.metadata.finalizers
end

let finalizer_name = "webapps.example.com/cleanup"

module Web_app_reconciler = struct
  module R = Web_app

  let reconcile (ctx : Context.t) (req : Request.t) : Web_app.t option -> _ = function
    | None ->
      Context.log ctx "WEBAPP  %s: gone" (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some app when Web_app.deletion_timestamp app <> None ->
      (* Being deleted: the API server only set deletionTimestamp instead
         of actually removing the object, specifically because our
         finalizer is still present -- run cleanup, then remove it so the
         deletion can actually complete. If it's already gone (a second
         reconcile racing the first's removal, or a finalizer that was
         never added), there's nothing to do. *)
      if Finalizer.has ~resource:(module Web_app) app ~name:finalizer_name
      then (
        Context.log ctx "WEBAPP  %s: running finalizer (pretend cleanup), then removing it"
          (Request.to_string req);
        match Finalizer.remove (Context.client ctx) ~resource:(module Web_app) app ~name:finalizer_name with
        | Ok () -> Ok (Reconcile_result.done_ ())
        | Error e -> Error (Reconcile_error.of_client_error e))
      else Ok (Reconcile_result.done_ ())
    | Some app when not (Finalizer.has ~resource:(module Web_app) app ~name:finalizer_name) ->
      (* Not yet marked for deletion, and doesn't have our finalizer yet:
         add it before doing any other work, so a delete that arrives
         between now and the next reconcile is guaranteed to be caught by
         the branch above instead of the object just disappearing. *)
      Context.log ctx "WEBAPP  %s: adding finalizer" (Request.to_string req);
      (match Finalizer.add (Context.client ctx) ~resource:(module Web_app) app ~name:finalizer_name with
       | Ok () -> Ok (Reconcile_result.done_ ())
       | Error e -> Error (Reconcile_error.of_client_error e))
    | Some app ->
      let desired = app.spec.replicas in
      (* No real Deployment behind this demo -- pretend reconciliation
         always succeeds immediately. The point is exercising the typed
         decode and a genuine /status PUT, not simulating real workload
         management. Only PUT when the status actually needs to change:
         our own PUT generates a MODIFIED watch event, which would
         re-trigger this reconcile -- writing the same status every time
         would self-trigger forever instead of converging. *)
      let already_correct =
        match app.status with
        | Some s -> s.ready_replicas = desired
        | None -> false
      in
      if already_correct
      then (
        Context.log ctx "WEBAPP  %s: already ready_replicas=%d, nothing to do" (Request.to_string req) desired;
        Ok (Reconcile_result.done_ ()))
      else (
        let status : Web_app.status = { ready_replicas = desired; observed_generation = 1 } in
        Context.log ctx "WEBAPP  %s: image=%s, setting status.readyReplicas=%d" (Request.to_string req)
          app.spec.image desired;
        Ok (Reconcile_result.done_ ~status ()))
end

module Web_app_controller = Controller.Make (Web_app_reconciler)

let () =
  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in
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
    match Client.of_env ~sw env with
    | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok client ->
      let ctx = Context.create ~sw ~env ~client () in
      let controller = Web_app_controller.create ~ctx ?namespace () in
      traceln "-- webapp controller starting --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
