(* [t] defers all construction that needs a [Switch.t] (the Workqueue, the
   Reflector, the worker fibers) into a closure captured at [create] time
   and only run when [run ~sw] supplies one. This is what lets every
   [Make(R).create] return the same concrete, non-parameterised type: the
   closure closes over [R] internally, and [R] never appears in [t]. *)
type t = { start : sw:Eio.Switch.t -> unit }

let run ~sw (t : t) = t.start ~sw

module Make (R : Resource.S) = struct
  module Rf = Reflector.Make (R)

  let create ~ctx ~clock ?namespace ?label_selector ?(workers = 1) ~reconciler () : t =
    let start ~sw =
      let wq = Workqueue.create ~sw ~clock () in
      let on_event (ev : R.t Watch_event.t) = Workqueue.add wq ev.request in
      let reflector = Rf.create ~ctx ?namespace ?label_selector ~on_event () in
      Eio.Fiber.fork ~sw (fun () -> Rf.run reflector);
      Cache.wait_for_sync (Rf.cache reflector);
      let cache = Rf.cache reflector in
      let worker () =
        let rec loop () =
          match Workqueue.get wq with
          | None -> () (* queue shut down and drained *)
          | Some req ->
            (* Deliberately no [try ... with] around the reconciler call:
               it's expected to report failure via [Error], per the
               "explicit errors, not exceptions" design rule. An
               unexpected exception here is a genuine bug and is allowed
               to propagate — through [Fiber.fork] that fails this
               controller's switch — rather than being silently
               swallowed into a requeue loop. *)
            (match reconciler ctx cache req with
             | Ok Reconciler.Result.Done -> Workqueue.forget wq req
             | Ok Reconciler.Result.Requeue -> Workqueue.add_rate_limited wq req
             | Ok (Reconciler.Result.Requeue_after delay) ->
               Workqueue.forget wq req;
               Workqueue.add_after wq req ~delay
             | Error e ->
               Context.log ctx "reconcile %s failed: %s" (Request.to_string req)
                 (Reconciler.Error.to_string e);
               Workqueue.add_rate_limited wq req);
            Workqueue.done_ wq req;
            loop ()
        in
        loop ()
      in
      for _ = 1 to workers do
        Eio.Fiber.fork ~sw worker
      done
    in
    { start }
end
