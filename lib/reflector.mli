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
    -> ?watch_timeout_seconds:int
    -> on_event:(R.t Watch_event.t -> unit)
    -> unit
    -> t
  (** Creates (but does not start) a reflector with its own, freshly
      created cache. [on_event] fires for every ADDED/MODIFIED/DELETED
      after the cache has already been updated — a [Controller] wires this
      to [Workqueue.add].

      No [~env] parameter: [run] gets it from [Context.env ctx], the same
      place it gets the client to clone from — one fewer thing a caller has
      to thread down separately from [ctx].

      No [~client] parameter either: [run] opens its own, via
      {!Client.clone} on [Context.client ctx]. Earlier versions of this took
      a caller-
      supplied [~client] instead, on the reasoning that a WATCH is
      long-lived and anything else sharing its connection (e.g. a
      reconciler's own status PUT, issued via [Context.client ctx])
      queues forever behind it — true, but that just turned "pass two
      *different* [Client.t] values, always, with nothing checking you
      did" into a footgun that caused three separate bugs across this
      codebase's history (within one controller, across controllers
      sharing a Manager, and in leader election's own Lease renewal
      traffic). Cloning internally instead removes the parameter a caller
      could get wrong in the first place.

      [watch_timeout_seconds], if given, is forwarded as the WATCH
      request's [timeoutSeconds] query param (see {!Client.watch}): the
      API server then closes the stream on that cadence, which [run] treats
      as a routine re-list, giving a predictable resync interval that also
      doubles as a liveness check on the connection. *)

  val cache : t -> R.t Cache.t

  val run : sw:Eio.Switch.t -> t -> unit
  (** Opens a dedicated connection (via {!Client.clone}; retried patiently
      with backoff, same as any other connectivity failure here, if it
      fails), then runs LIST-then-WATCH inline in the calling fiber,
      forever:
      - LIST populates the cache (via [Cache.Writer.replace_all], so
        objects that disappeared during a disconnection are actually
        dropped, not left stale) and resolves [Cache.wait_for_sync].
      - WATCH streams events from the LIST's [resourceVersion], updating
        the cache and invoking [on_event] for each one.
      - On {!Client.Error.Gone}, a dropped connection, or a LIST/WATCH
        request error: back off (capped exponential, reset on success)
        and re-LIST — a Reflector's job is to *stay* synced, not to give
        up.

      [sw] is needed only for {!Client.clone}'s cleanup registration (via
      [Switch.on_release]) — this still never forks a sub-fiber of its
      own, so cancellation still flows through Eio's ambient per-fiber
      context, not through [sw] directly: callers make this a background
      loop with [Fiber.fork ~sw (fun () -> run ~sw t)], and cancelling
      [sw] interrupts whichever blocking call (the clone, LIST, WATCH, or
      a backoff sleep) is in progress. *)
end
