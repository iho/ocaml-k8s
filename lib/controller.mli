(** Wires a {!Reflector} + {!Cache} + {!Workqueue} + a {!Reconciler.S}
    together for one Kind. *)

type t
(** Opaque, non-parameterised handle. Every [Make(Rec).create] — regardless
    of [Rec.R] — produces this same type ([Rec.R.t] is closed over inside
    the worker closures and never appears in [t]'s type), so a [Manager]
    can hold controllers for different Kinds in one plain list. *)

val run : sw:Eio.Switch.t -> t -> unit
(** Forks the reflector fiber and [workers] worker fibers onto [sw] and
    returns immediately — same "fork, then let the enclosing Switch.run
    block" pattern the verified low-level client already uses. Blocks
    (inline, before forking the workers) on [Cache.wait_for_sync] so the
    first reconcile of any object already sees a warm cache. *)

val name : t -> string
(** The Kind this controller reconciles (its [Gvk.t.kind]) — used to
    label its metrics (see the [Make(Rec).create] doc comment below) and
    to name its entry in {!Manager}'s built-in readiness checks. *)

val is_synced : t -> bool
(** Non-blocking: [false] until this controller's [Cache] has completed
    its initial LIST (before [run] has even been called, or while the
    first LIST is still in flight) — see {!Cache.is_synced}. What
    {!Manager.serve_health} reports readiness from, one check per
    registered controller. *)

module Make (Rec : Reconciler.S) : sig
  val create :
     ctx:Context.t
    -> ?namespace:string
    -> ?label_selector:string
    -> ?owns:(module Secondary.S) list
    -> ?workers:int (** default 1 *)
    -> ?base_delay:float (** default 0.005s — first rate-limited retry after a reconcile error; forwarded to {!Workqueue.create} *)
    -> ?max_delay:float (** default 1000.0s — backoff cap; forwarded to {!Workqueue.create} *)
    -> ?max_retries:int
         (** default [None] (unlimited, client-go's behaviour): once a key has
             been rate-limited this many times by consecutive [Error] results
             from [Rec.reconcile] — a [Requeue] returned via [Ok] doesn't
             count, that's the reconciler's own deliberate "not ready yet",
             not a failure — it is [forget]'d instead of requeued again, and
             the failure is logged. A later watch event (the object actually
             changing) re-adds it with a fresh count. Without this, a
             permanently-broken object (e.g. one that fails validation no
             retry can fix) retries forever, capped only at [max_delay]
             between attempts, never actually stopping. *)
    -> unit
    -> t
  (** No [~env] or [~client] parameter: both come from [ctx]. This
      controller's [Reflector] opens its own dedicated connection internally
      (see {!Reflector.Make}'s [create]), cloned from [Context.client ctx]
      via [Context.env ctx]. [Rec.reconcile] is free to use [Context.client
      ctx] itself for status updates or other ad-hoc calls (e.g. via
      {!Finalizer}) without any risk of it starving behind this controller's
      own WATCH — they're now always different connections, structurally,
      not just by the caller's discipline.

      [?owns] declares secondary (child) Kinds this controller creates and
      therefore needs to reconcile its primary on changes to. For each
      {!Secondary.S} in the list, the controller runs an extra reflector
      whose events are mapped back to the primary's workqueue via that
      secondary's [map] (which should return the owning primary's
      [Request.t], or [None] for children this controller doesn't own).
      Without this, a child that is deleted or drifts is never noticed,
      because the primary Kind didn't move — see {!Secondary}.

      For each reconcile that returns [Ok { status = Some s; action }]: the
      object is looked up in the cache again (it may have been [None] when
      handed to [reconcile] only because of a race that's since resolved;
      if it's genuinely gone, the status update is skipped and logged,
      never attempted against a nonexistent object), updated via
      [Rec.R.with_status], and PUT via {!Client.update_status} *before*
      [action] is acted on. A failed status PUT *overrides* [action] with
      a backoff requeue, regardless of what [action] said: [reconcile]'s
      intent (e.g. [Done]) was computed assuming that write would land, so
      if it didn't, that intent isn't trustworthy until the write is
      retried and does succeed. *)
end
