(* Manual verification tool for [K8s.Controller] — exercises the full
   stack: Reflector (LIST+WATCH) -> Cache -> Workqueue (dedup/backoff) ->
   Reconciler, same as a real operator would use. Not part of the CLI
   proper. Run against a real cluster / `kubectl proxy`, e.g.:
     dune exec bin/controller_demo.exe -- kube-system
   The reconcile counter printed alongside each line is a rough way to see
   the Workqueue's dedup in action: a burst of MODIFIED events on the same
   pod collapses into far fewer reconciles than events.

   Also the reference for [Controller.Make(_).create]'s tunables beyond
   the defaults: [~workers] (concurrency) and [~max_retries]/[~base_delay]/
   [~max_delay] (how hard a controller retries a reconcile that keeps
   returning [Error] before giving up on that key and logging instead of
   requeuing it forever — see `lib/controller.mli`). *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

let reconcile_count = ref 0

module Pod_reconciler = struct
  module R = Pods

  let reconcile (ctx : Context.t) (req : Request.t) (pod : Pods.t option) =
    incr reconcile_count;
    (match pod with
     | None -> Context.log ctx "RECONCILE #%d %s: deleted" !reconcile_count (Request.to_string req)
     | Some pod ->
       let phase = Yojson.Safe.Util.(pod |> member "status" |> member "phase" |> to_string_option) in
       Context.log ctx "RECONCILE #%d %s: phase=%s" !reconcile_count (Request.to_string req)
         (Option.value phase ~default:"?"));
    Ok (Reconcile_result.done_ ())
end

module Pod_controller = Controller.Make (Pod_reconciler)

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
      let controller = Pod_controller.create ~ctx ?namespace ~workers:2 ~max_retries:5 () in
      traceln "-- controller starting (2 workers, giving up on a key after 5 failed reconciles) --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
