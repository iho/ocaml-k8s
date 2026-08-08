(* Manual verification tool for [K8s.Manager] — registers two controllers
   of *different* Kinds (Pods and ConfigMaps) under one Manager, proving
   Controller.t's closure-erasure actually lets a Manager hold
   heterogeneous controllers in one plain list, not just same-Kind ones.
   Not part of the CLI proper. Run against a real cluster / `kubectl
   proxy`, e.g.:
     dune exec bin/manager_demo.exe -- kube-system
   [Manager.run] still installs the SIGINT/SIGTERM handler internally, so
   [main] doesn't need its own — but it *does* still need
   [try ... with Exit -> ...] around the enclosing [Switch.run], same as
   every other demo here: [Manager.run] takes [~sw] and cancels *that*
   switch rather than owning a private one, specifically so it shares a
   lifecycle with the [Client] built on the same [sw] below (see
   [Manager.run]'s doc comment for the deadlock this avoids).

   Only *one* [Client.t]/[Context.t] here, shared by both controllers:
   each [Controller.Make(_).create] clones its own dedicated connection
   for its Reflector internally (see [Controller.Make]'s doc comment), so
   there's no risk of one controller's long-lived WATCH starving the
   other's — that used to require the caller to manually build a separate
   [Client.t] per controller and remember not to mix them up; now it's
   automatic and there's nothing to get wrong.

   Also serves /healthz and /readyz on :8080 (see [Manager.serve_health])
   -- registers one artificial readiness check ("warmup") that stays
   failed for the first 5s, purely so `curl http://127.0.0.1:8080/readyz`
   run twice a few seconds apart actually shows a 503 -> 200 transition,
   not just the steady state. *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

module Config_maps = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"ConfigMap"
  let plural = "configmaps"
  let namespaced = true
end)

module Pod_reconciler = struct
  module R = Pods

  let reconcile (ctx : Context.t) (req : Request.t) (pod : Pods.t option) =
    (match pod with
     | None -> Context.log ctx "POD        %s: deleted" (Request.to_string req)
     | Some pod ->
       let phase = Yojson.Safe.Util.(pod |> member "status" |> member "phase" |> to_string_option) in
       Context.log ctx "POD        %s: phase=%s" (Request.to_string req)
         (Option.value phase ~default:"?"));
    Ok (Reconcile_result.done_ ())
end

module Config_map_reconciler = struct
  module R = Config_maps

  let reconcile (ctx : Context.t) (req : Request.t) (cm : Config_maps.t option) =
    (match cm with
     | None -> Context.log ctx "CONFIGMAP  %s: deleted" (Request.to_string req)
     | Some cm ->
       let n_keys =
         match Yojson.Safe.Util.member "data" cm with
         | `Assoc kvs -> List.length kvs
         | _ -> 0
       in
       Context.log ctx "CONFIGMAP  %s: %d data key(s)" (Request.to_string req) n_keys);
    Ok (Reconcile_result.done_ ())
end

module Pod_controller = Controller.Make (Pod_reconciler)
module Config_map_controller = Controller.Make (Config_map_reconciler)

let () =
  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    match Client.of_env ~sw env with
    | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok client ->
      let ctx = Context.create ~sw ~client ~clock:env#clock () in
      let pod_controller = Pod_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      let config_map_controller = Config_map_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      let manager = Manager.create ~ctx () in
      Manager.add_controller manager pod_controller;
      Manager.add_controller manager config_map_controller;
      let warmed_up = ref false in
      Fiber.fork ~sw (fun () ->
        Time.sleep env#clock 5.0;
        warmed_up := true;
        traceln "warmup complete, /readyz's \"warmup\" check now passes");
      Manager.add_readiness_check manager ~name:"warmup" (fun () -> !warmed_up);
      Manager.serve_health ~sw env manager ~port:8080;
      traceln "-- serving http://127.0.0.1:8080/healthz and /readyz --";
      Manager.run ~sw manager
  with Exit -> traceln "stopped."
