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
   lifecycle with the [Client]s built on the same [sw] below (see
   [Manager.run]'s doc comment for the deadlock this avoids).

   Each controller gets its own [Client.t]/[Context.t] here rather than
   sharing one: a Reflector's WATCH is a long-lived streaming request, and
   over a single HTTP/1.1 connection (which is what `kubectl proxy` speaks)
   that starves every *other* controller sharing the connection — their
   LIST/WATCH calls just queue forever behind the first controller's
   never-ending watch, with no error or timeout to surface it. This was
   found by running exactly this demo with one shared client: the second
   controller silently never printed anything, ever. HTTP/2 (real clusters
   over TLS) genuinely multiplexes and wouldn't hit this, but one
   connection per controller avoids the failure mode either way. Both
   clients still share the *same* [sw], for the reason above. *)

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

module Pod_controller = Controller.Make (Pods)
module Config_map_controller = Controller.Make (Config_maps)

let pod_reconcile : Pods.t Reconciler.t =
 fun ctx cache req ->
  (match Cache.get cache req with
   | None -> Context.log ctx "POD        %s: deleted" (Request.to_string req)
   | Some pod ->
     let phase = Yojson.Safe.Util.(pod |> member "status" |> member "phase" |> to_string_option) in
     Context.log ctx "POD        %s: phase=%s" (Request.to_string req)
       (Option.value phase ~default:"?"));
  Ok Reconciler.Result.Done

let config_map_reconcile : Config_maps.t Reconciler.t =
 fun ctx cache req ->
  (match Cache.get cache req with
   | None -> Context.log ctx "CONFIGMAP  %s: deleted" (Request.to_string req)
   | Some cm ->
     let n_keys =
       match Yojson.Safe.Util.member "data" cm with
       | `Assoc kvs -> List.length kvs
       | _ -> 0
     in
     Context.log ctx "CONFIGMAP  %s: %d data key(s)" (Request.to_string req) n_keys);
  Ok Reconciler.Result.Done

let () =
  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    (* A fresh Client/Context per controller, but the *same* [sw] for
       both — see the file header comment for both of those choices. *)
    let new_ctx () =
      match Client.of_env ~sw env with
      | Error e -> Error e
      | Ok client -> Ok (Context.create ~sw ~client ~clock:env#clock ())
    in
    match new_ctx (), new_ctx () with
    | Error e, _ | _, Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok pod_ctx, Ok config_map_ctx ->
      let manager_ctx = pod_ctx in
      let pod_controller =
        Pod_controller.create ~ctx:pod_ctx ~clock:env#clock ?namespace ~reconciler:pod_reconcile ()
      in
      let config_map_controller =
        Config_map_controller.create ~ctx:config_map_ctx ~clock:env#clock ?namespace
          ~reconciler:config_map_reconcile ()
      in
      let manager = Manager.create ~ctx:manager_ctx () in
      Manager.add_controller manager pod_controller;
      Manager.add_controller manager config_map_controller;
      Manager.run ~sw manager
  with Exit -> traceln "stopped."
