(** The List+Watch engine: [bin/main.ml]'s original [list_pods]/
    [watch_pods] generalised over any {!Resource.S} (done, via
    {!Client}) and turned into a long-running, self-healing loop instead
    of a one-shot demo. *)
module Make (R : Resource.S) : sig
  type t

  val create :
     ctx:Context.t
    -> ?namespace:string
    -> ?label_selector:string
    -> ?field_selector:string
    -> on_event:(R.t Watch_event.t -> unit)
    -> unit
    -> t
  (** Creates (but does not start) a reflector with its own, freshly
      created cache. [on_event] fires for every ADDED/MODIFIED/DELETED
      after the cache has already been updated — a [Controller] wires this
      to [Workqueue.add]. *)

  val cache : t -> R.t Cache.t

  val run : t -> unit
  (** Runs LIST-then-WATCH inline in the calling fiber, forever:
      - LIST populates the cache (via [Cache.Writer.replace_all], so
        objects that disappeared during a disconnection are actually
        dropped, not left stale) and resolves [Cache.wait_for_sync].
      - WATCH streams events from the LIST's [resourceVersion], updating
        the cache and invoking [on_event] for each one.
      - On {!Client.Error.Gone}, a dropped connection, or a LIST/WATCH
        request error: back off (capped exponential, reset on success)
        and re-LIST — a Reflector's job is to *stay* synced, not to give
        up.

      No [~sw] parameter: this never forks a sub-fiber, so — unlike
      {!Controller.run}/{!Manager.run} — it needs no [Switch] of its own.
      Cancellation flows through Eio's ambient per-fiber context instead;
      callers make this a background loop with
      [Fiber.fork ~sw (fun () -> run t)], and cancelling [sw] interrupts
      whichever blocking call (LIST, WATCH, or the backoff sleep) is in
      progress. *)
end
