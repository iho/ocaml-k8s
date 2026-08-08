(* Demonstrates real Prometheus metrics: Context.Metrics.t is normally a
   no-op (see bin/hello_operator.ml and every other demo, none of which
   pass ~metrics at all), but Controller always calls inc_counter/observe/
   set_gauge regardless -- plugging in Metrics_prometheus.context_metrics
   instead of the default makes every controller sharing that Context
   instrumented for free, no reconciler code involved.

   Not part of the CLI proper. Run against a real cluster / `kubectl
   proxy`, e.g.: dune exec bin/metrics_demo.exe -- kube-system, then in
   another shell: curl http://127.0.0.1:9090/metrics -- watch
   k8s_controller_reconcile_total and k8s_controller_reconcile_duration_seconds
   grow as it reconciles, and k8s_controller_workqueue_depth settle to 0
   once the initial sync's backlog is drained. *)

open Eio
open K8s

module Config_maps = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"ConfigMap"
  let plural = "configmaps"
  let namespaced = true
end)

module Reconciler = struct
  module R = Config_maps

  let reconcile (ctx : Context.t) (req : Request.t) (_ : Config_maps.t option) =
    Context.log ctx "saw %s" (Request.to_string req);
    Ok (Reconcile_result.done_ ())
end

module My_controller = Controller.Make (Reconciler)

let metrics_port = 9090

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
      let registry = Metrics_prometheus.create () in
      Metrics_prometheus.serve ~sw env registry ~port:metrics_port;
      traceln "-- serving http://127.0.0.1:%d/metrics --" metrics_port;
      let ctx = Context.create ~sw ~client ~clock:env#clock ~metrics:(Metrics_prometheus.context_metrics registry) () in
      let controller = My_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      traceln "-- metrics-instrumented controller starting --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
