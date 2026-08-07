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

module Make (Rec : Reconciler.S) : sig
  val create :
     ctx:Context.t
    -> client:Client.t
    -> clock:_ Eio.Time.clock
    -> ?namespace:string
    -> ?label_selector:string
    -> ?workers:int (** default 1 *)
    -> unit
    -> t
  (** [client] is a *separate* connection dedicated to this controller's
      own [Reflector] (its LIST+WATCH) — not [Context.client ctx], which
      [Rec.reconcile] may use itself for status updates (see
      {!Client.update_status}) or other ad-hoc calls. They must be
      different connections if [Rec.reconcile] ever does issue its own
      calls: a WATCH is long-lived, and over an HTTP/1.1 connection
      anything else sharing it — like a status PUT — queues forever
      behind it, silently. See {!Reflector.Make}'s [create] for how this
      was found. If [Rec.reconcile] only ever reads from the cache and
      never returns [Some status] or otherwise calls [Context.client],
      it's fine to pass the same [Client.t] as [ctx]'s.

      [clock] is needed only to build this controller's [Workqueue] (its
      [add_after]/[add_rate_limited] timers) — it can't be recovered from
      [ctx], since [Context] deliberately only exposes [Context.sleep], not
      the underlying row-polymorphic [Eio.Time.clock] (see
      [Context.create]'s doc comment for why). Pass the same clock used to
      build [ctx].

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
