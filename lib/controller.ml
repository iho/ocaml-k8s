(* [t] defers all construction that needs a [Switch.t] (the Workqueue, the
   Reflector, the worker fibers) into a closure captured at [create] time
   and only run when [run ~sw] supplies one. This is what lets every
   [Make(Rec).create] return the same concrete, non-parameterised type: the
   closure closes over [Rec.R] internally, and it never appears in [t].
   [is_synced] is a second closure for the same reason: it reads a cache
   that doesn't exist until [start] has actually run (the [Reflector], and
   the [Cache] it owns, are only created inside [start]'s closure), so it
   has to be [unit -> bool], not a plain field snapshotted at [create]
   time — before [start] runs, it always answers [false]. *)
type t =
  { start : sw:Eio.Switch.t -> unit
  ; name : string
  ; is_synced : unit -> bool
  }

let run ~sw (t : t) = t.start ~sw
let name (t : t) = t.name
let is_synced (t : t) = t.is_synced ()

module Make (Rec : Reconciler.S) = struct
  module Rf = Reflector.Make (Rec.R)

  (* Every metric this controller emits carries these two labels, so a
     Manager combining several controllers on one Context.Metrics.t (e.g.
     via Metrics_prometheus.context_metrics) ends up with one distinguished
     time series per Kind on a single /metrics endpoint, not one
     unlabelled blob mixing every controller's numbers together. *)
  let metric_labels = [ "kind", Rec.R.gvk.kind; "group_version", Gvk.api_version Rec.R.gvk ]

  let create ~ctx ~env ~clock ?namespace ?label_selector ?(workers = 1) () : t =
    let cache_ref : Rec.R.t Cache.t option ref = ref None in
    let start ~sw =
      let wq = Workqueue.create ~sw ~clock () in
      let on_event (ev : Rec.R.t Watch_event.t) = Workqueue.add wq ev.request in
      let reflector = Rf.create ~ctx ~env ?namespace ?label_selector ~on_event () in
      Eio.Fiber.fork ~sw (fun () -> Rf.run ~sw reflector);
      let cache = Rf.cache reflector in
      cache_ref := Some cache;
      Cache.wait_for_sync cache;
      let metrics = Context.metrics ctx in
      Eio.Fiber.fork ~sw (fun () ->
        (* A queue depth gauge has no natural "event" to hang off of the
           way the counter/histogram below do (nothing changes it except
           Workqueue operations happening on other fibers) -- polling on a
           timer is the simplest thing that's actually correct, and cheap
           enough at this interval that it's not worth threading a metrics
           callback through every Workqueue.add/done_ call instead. *)
        let rec loop () =
          Context.Metrics.set_gauge metrics ~name:"k8s_controller_workqueue_depth" ~labels:metric_labels
            (float_of_int (Workqueue.len wq));
          Context.sleep ctx 5.0;
          loop ()
        in
        loop ());
      (* Applies a status update, if any, *before* the reconcile's
         requested action. Returns [false] if the update was requested but
         failed, so the caller can override [action] with a backoff
         requeue regardless of what the reconciler originally asked for:
         the reconciler's intent (e.g. "Done") was computed assuming the
         status write it asked for would actually land, so if it didn't,
         that intent isn't trustworthy until it's retried and does.

         One retry is made on a 409 conflict by refetching the current
         object from the API server (not the cache — the cache's copy is
         the very one that proved stale by conflicting) and re-applying the
         status to that fresh object before PUTting again. A conflict means
         our copy's resourceVersion is stale: some other writer (another
         worker reconciling the same key, or the object's spec being
         updated independently) landed a newer one while we were computing
         the status. Rather than give up into a full backoff requeue, one
         refetch-and-retry is usually enough: the fresh object's
         resourceVersion *now* matches the server, so the retried PUT
         succeeds and the reconciler's intent lands as asked. This is
         exactly the class of transient write race the status subresource
         exists for, and it's what client-go's [UpdateStatus] callers
         handle by looping on conflict. Only one retry, though — a *second*
         conflict means a genuinely contended key (or a bad [with_status]
         implementation), and that's correctly left to the backoff requeue
         rather than risking an unbounded hot loop. *)
      let apply_status req (result : _ Reconcile_result.t) =
        match result.status with
        | None -> true
        | Some status ->
          let put_against obj =
            match Client.update_status (Context.client ctx) ~resource:(module Rec.R) (Rec.R.with_status obj status) with
            | Ok () -> `Ok
            | Error (Client.Error.Api_error s) when Status.is_conflict s -> `Conflict
            | Error e -> `Failed e
          in
          let put_cached () =
            match Cache.get cache req with
            | None -> `Gone
            | Some obj -> put_against obj
          in
          (* The retry path deliberately refetches via [Client.get] rather
             than [Cache.get]: the cache is populated by watch events that
             may not have caught up to the version that just conflicted, so
             re-reading it would only reproduce the same stale
             resourceVersion and the same 409. *)
          let put_fresh () =
            match Client.get (Context.client ctx) ~resource:(module Rec.R) ?namespace:req.namespace ~name:req.name () with
            | Error e -> `Failed e
            | Ok None -> `Gone
            | Ok (Some obj) -> put_against obj
          in
          (match put_cached () with
           | `Ok -> true
           | `Gone ->
             (* Genuinely gone by the time we got here (a race with a
                DELETE, not the [None] originally handed to [reconcile] —
                that case wouldn't return [Some status] from a well-behaved
                reconciler, but we don't rely on that). Nothing to PUT to. *)
             Context.log ctx "%s: reconcile returned a status update but the object is gone, skipping"
               (Request.to_string req);
             true
           | `Failed e ->
             Context.log ctx "%s: status update failed: %s" (Request.to_string req) (Client.Error.to_string e);
             false
           | `Conflict ->
             Context.log ctx "%s: status update conflicted (409), refetching and retrying once" (Request.to_string req);
             (match put_fresh () with
              | `Ok -> true
              | `Gone ->
                Context.log ctx "%s: status update conflicted then object disappeared on retry" (Request.to_string req);
                true
              | `Failed e ->
                Context.log ctx "%s: status update retry after conflict failed: %s" (Request.to_string req)
                  (Client.Error.to_string e);
                false
              | `Conflict ->
                Context.log ctx "%s: status update conflicted twice, falling back to backoff requeue"
                  (Request.to_string req);
                false))
      in
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
            let started_at = Eio.Time.now clock in
            let record_reconcile ~outcome =
              let duration = Eio.Time.now clock -. started_at in
              Context.Metrics.inc_counter metrics ~name:"k8s_controller_reconcile_total"
                ~labels:(("result", outcome) :: metric_labels);
              Context.Metrics.observe metrics ~name:"k8s_controller_reconcile_duration_seconds" ~labels:metric_labels
                duration
            in
            (match Rec.reconcile ctx req (Cache.get cache req) with
             | Ok result ->
               let action = if apply_status req result then result.action else Reconcile_result.Requeue in
               (match action with
                | Reconcile_result.Done ->
                  record_reconcile ~outcome:"done";
                  Workqueue.forget wq req
                | Requeue ->
                  record_reconcile ~outcome:"requeue";
                  Workqueue.add_rate_limited wq req
                | Requeue_after delay ->
                  record_reconcile ~outcome:"requeue_after";
                  Workqueue.forget wq req;
                  Workqueue.add_after wq req ~delay)
             | Error e ->
               record_reconcile ~outcome:"error";
               Context.log ctx "reconcile %s failed: %s" (Request.to_string req) (Reconcile_error.to_string e);
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
    let is_synced () =
      match !cache_ref with
      | None -> false
      | Some cache -> Cache.is_synced cache
    in
    { start; name = Rec.R.gvk.kind; is_synced }
end
