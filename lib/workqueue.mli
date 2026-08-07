(** Rate-limited, deduplicating work queue, modelled on client-go's
    [workqueue.RateLimitingInterface]: an object that changes N times while
    a reconcile for it is already in flight is only reconciled once more,
    not N times (the "dirty set + processing set" dance — see the design
    roadmap). Monomorphic on {!Request.t}: there is only ever one key type
    in this design, so a functor here would be pure ceremony.

    Implemented with [Eio.Mutex] + [Eio.Condition] guarding a queue/dirty-
    set/processing-set, and one short-lived [Eio.Time.sleep] fiber forked
    onto [sw] per [add_after]/[add_rate_limited] call. *)

type t

val create :
   sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?base_delay:float (** default 0.005s — first rate-limited retry *)
  -> ?max_delay:float (** default 1000.0s — backoff cap *)
  -> unit
  -> t
(** [sw] is used only to fork the short-lived timer fibers behind
    [add_after]/[add_rate_limited], so pending timers are cancelled on
    shutdown instead of firing into a torn-down queue. Should be the
    owning [Controller]'s switch. *)

val add : t -> Request.t -> unit
(** Enqueue now. If already queued or currently being processed, this is a
    no-op except for marking it dirty (redelivered after the current
    [done_]) — the core dedup guarantee. *)

val add_after : t -> Request.t -> delay:float -> unit
(** For [Reconciler.Result.Requeue_after]. *)

val add_rate_limited : t -> Request.t -> unit
(** For a reconcile error / [Reconciler.Result.Requeue]: re-add with
    exponential backoff based on how many consecutive times this key has
    been rate-limited without an intervening [forget]. *)

val forget : t -> Request.t -> unit
(** Reset a key's backoff counter. Call on successful reconcile. *)

val get : t -> Request.t option
(** Blocks until an item is available, marking it "processing"; returns
    [None] once [shutdown] has been called and the queue has drained. *)

val done_ : t -> Request.t -> unit
(** Marks processing finished. If the key was re-[add]ed (marked dirty)
    while it was processing, it is immediately requeued. *)

val shutdown : t -> unit
val len : t -> int
