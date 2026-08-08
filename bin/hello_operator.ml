(* The minimal operator: watch one Kind, log, done. This is every line
   needed to get a real Reflector->Cache->Workqueue->Reconciler loop
   running against a live cluster -- start here, then see:
     bin/controller_demo.ml   multiple workers, a reconcile counter
     bin/webapp_demo.ml       a typed CRD, a real /status PUT, a finalizer
     bin/owned_child_demo.ml  creating a child object with an OwnerReference
     bin/periodic_demo.ml     Requeue_after -- reconciling on a timer, not
                               just on watch events
     gen/scaffold_operator.ml scaffolds a whole new project shaped like
                               this file (or webapp_demo.ml, for a CRD)
   Not part of the CLI proper. Run against a real cluster / `kubectl
   proxy`, e.g.: dune exec bin/hello_operator.exe -- kube-system

   Deliberately skips the `Sys.set_signal Sys.sigint` dance every other
   demo here has: Ctrl-C just kills the process via OCaml's default
   disposition instead of cleanly closing the connection first. Fine for
   a five-second manual test, not for anything real -- see any other
   demo in this directory for the few extra lines that make shutdown
   clean. *)

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

let () =
  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in
  Eio_main.run
  @@ fun env ->
  Switch.run
  @@ fun sw ->
  match Client.of_env ~sw env with
  | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
  | Ok client ->
    let ctx = Context.create ~sw ~env ~client () in
    let controller = My_controller.create ~ctx ?namespace () in
    Controller.run ~sw controller
