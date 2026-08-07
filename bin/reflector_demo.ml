(* Manual verification tool for [K8s.Reflector] — not part of the CLI
   proper (see bin/main.ml, which still talks to [K8s.Client] directly).
   Exercises the full Reflector loop: LIST into the cache, resolve
   [Cache.wait_for_sync], then WATCH-forever updating the cache and
   printing every event. Same CLI shape as [main.ml] but namespace-only
   (run against a real cluster / `kubectl proxy`, e.g.:
     dune exec bin/reflector_demo.exe -- kube-system
   ). *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

module Pod_reflector = Reflector.Make (Pods)

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
      let on_event (ev : Pods.t Watch_event.t) =
        let kind_str =
          match ev.kind with
          | Added -> "ADDED"
          | Modified -> "MODIFIED"
          | Deleted -> "DELETED"
          | Bookmark -> "BOOKMARK"
        in
        traceln "EVENT   %-8s %-40s resourceVersion=%s" kind_str (Request.to_string ev.request)
          (Option.value (Pods.resource_version ev.object_) ~default:"?")
      in
      let reflector = Pod_reflector.create ~ctx ~client ?namespace ~on_event () in
      Fiber.fork ~sw (fun () -> Pod_reflector.run reflector);
      Cache.wait_for_sync (Pod_reflector.cache reflector);
      traceln "-- synced: %d pod(s) in cache --"
        (List.length (Cache.list (Pod_reflector.cache reflector)))
  with Exit -> traceln "stopped."
