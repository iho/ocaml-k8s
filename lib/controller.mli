(** Wires a {!Reflector} + {!Cache} + {!Workqueue} + a {!Reconciler.t}
    together for one Kind. *)

type t
(** Opaque, non-parameterised handle. Every [Make(R).create] — regardless
    of [R] — produces this same type (the [R.t] is closed over inside the
    worker closures and never appears in [t]'s type), so a [Manager] can
    hold controllers for different Kinds in one plain list. *)

val run : sw:Eio.Switch.t -> t -> unit
(** Forks the reflector fiber and [workers] worker fibers onto [sw] and
    returns immediately — same "fork, then let the enclosing Switch.run
    block" pattern the verified low-level client already uses. Blocks
    (inline, before forking the workers) on [Cache.wait_for_sync] so the
    first reconcile of any object already sees a warm cache. *)

module Make (R : Resource.S) : sig
  val create :
     ctx:Context.t
    -> clock:_ Eio.Time.clock
    -> ?namespace:string
    -> ?label_selector:string
    -> ?workers:int (** default 1 *)
    -> reconciler:R.t Reconciler.t
    -> unit
    -> t
  (** [clock] is needed only to build this controller's [Workqueue] (its
      [add_after]/[add_rate_limited] timers) — it can't be recovered from
      [ctx], since [Context] deliberately only exposes [Context.sleep], not
      the underlying row-polymorphic [Eio.Time.clock] (see
      [Context.create]'s doc comment for why). Pass the same clock used to
      build [ctx]. *)
end
