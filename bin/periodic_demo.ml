(* Demonstrates Reconcile_result.requeue_after: a reconciler that keeps
   re-running on a timer, independent of watch events -- for state that's
   driven by something a watch can't observe (an external API's current
   value, wall-clock expiry, ...). Nothing else in this repo's demos
   exercises this path: they all rely on Requeue's rate-limited backoff
   (for retrying a failure) or Done (for "nothing to do until the next
   watch event"), never a *scheduled* re-run of an object nothing changed
   about. Not part of the CLI proper. Run against a real cluster /
   `kubectl proxy`, e.g.: dune exec bin/periodic_demo.exe -- kube-system,
   then watch it print a tick every [poll_interval] seconds per
   pre-existing ConfigMap, with no `kubectl edit`/`kubectl apply` needed
   to trigger each one. *)

open Eio
open K8s

module Config_maps = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"ConfigMap"
  let plural = "configmaps"
  let namespaced = true
end)

let poll_interval = 10.0

module Reconciler = struct
  module R = Config_maps

  let reconcile (ctx : Context.t) (req : Request.t) (obj : Config_maps.t option) =
    match obj with
    | None ->
      Context.log ctx "CM  %s: gone, no more polling" (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some _ ->
      (* Pretend this checks something outside Kubernetes -- an external
         API's health, a certificate's expiry, ... -- and always finds
         nothing to change. A real version would set ~status here on the
         reconciles that *do* find something new, same as any other
         reconciler; requeue_after doesn't require a status update, it's
         orthogonal to whether one happens. *)
      Context.log ctx "CM  %s: tick, next check in %.0fs" (Request.to_string req) poll_interval;
      Ok (Reconcile_result.requeue_after poll_interval)
end

module Config_map_controller = Controller.Make (Reconciler)

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
      let ctx = Context.create ~sw ~client ~clock:env#clock () in
      let controller = Config_map_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      traceln "-- periodic controller starting (tick every %.0fs) --" poll_interval;
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
