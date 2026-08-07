(* Manual verification tool for [K8s.Controller] — exercises the full
   stack: Reflector (LIST+WATCH) -> Cache -> Workqueue (dedup/backoff) ->
   Reconciler, same as a real operator would use. Not part of the CLI
   proper. Run against a real cluster / `kubectl proxy`, e.g.:
     dune exec bin/controller_demo.exe -- kube-system
   The reconcile counter printed alongside each line is a rough way to see
   the Workqueue's dedup in action: a burst of MODIFIED events on the same
   pod collapses into far fewer reconciles than events. *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

module Pod_controller = Controller.Make (Pods)

let reconcile_count = ref 0

let reconcile : Pods.t Reconciler.t =
 fun ctx cache req ->
  incr reconcile_count;
  (match Cache.get cache req with
   | None -> Context.log ctx "RECONCILE #%d %s: deleted" !reconcile_count (Request.to_string req)
   | Some pod ->
     let phase = Yojson.Safe.Util.(pod |> member "status" |> member "phase" |> to_string_option) in
     Context.log ctx "RECONCILE #%d %s: phase=%s" !reconcile_count (Request.to_string req)
       (Option.value phase ~default:"?"));
  Ok Reconciler.Result.Done

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
      let controller =
        Pod_controller.create ~ctx ~clock:env#clock ?namespace ~workers:2 ~reconciler:reconcile ()
      in
      traceln "-- controller starting (2 workers) --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
