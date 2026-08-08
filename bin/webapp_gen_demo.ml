(* Same reconciler as bin/webapp_demo.ml, verifying the *generated*
   Web_app (generated/web_app.ml, produced by gen/gen_resource.ml from
   examples/webapp-crd.yaml) is a drop-in replacement for the hand-written
   one — Resource.S doesn't care which produced a conforming module.
   Requires the same CRD + sample object + kubectl proxy as webapp_demo:
     kubectl apply -f examples/webapp-crd.yaml
     kubectl apply -f examples/webapp-sample.yaml
     kubectl proxy --port=8001 &
     dune exec bin/webapp_gen_demo.exe -- default *)

open Eio
open K8s
module Web_app = Webapp_generated.Web_app

let finalizer_name = "webapps.example.com/cleanup"

module Web_app_reconciler = struct
  module R = Web_app

  let reconcile (ctx : Context.t) (req : Request.t) : Web_app.t option -> _ = function
    | None ->
      Context.log ctx "WEBAPP  %s: gone" (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some app when Web_app.deletion_timestamp app <> None ->
      if Finalizer.has ~resource:(module Web_app) app ~name:finalizer_name
      then (
        Context.log ctx "WEBAPP  %s: running finalizer (pretend cleanup), then removing it"
          (Request.to_string req);
        match Finalizer.remove (Context.client ctx) ~resource:(module Web_app) app ~name:finalizer_name with
        | Ok () -> Ok (Reconcile_result.done_ ())
        | Error e -> Error (Reconcile_error.of_client_error e))
      else Ok (Reconcile_result.done_ ())
    | Some app when not (Finalizer.has ~resource:(module Web_app) app ~name:finalizer_name) ->
      Context.log ctx "WEBAPP  %s: adding finalizer" (Request.to_string req);
      (match Finalizer.add (Context.client ctx) ~resource:(module Web_app) app ~name:finalizer_name with
       | Ok () -> Ok (Reconcile_result.done_ ())
       | Error e -> Error (Reconcile_error.of_client_error e))
    | Some app ->
      let desired = app.spec.replicas in
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
      traceln "-- webapp (generated) controller starting --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
