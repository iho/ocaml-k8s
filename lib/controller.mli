(** Wires a {!Reflector} + {!Cache} + {!Workqueue} + a {!Reconciler.t}
    together for one Kind.

    STUB — signature is final, [run] is not implemented yet (roadmap
    Phase 4): fork the reflector, wait for [Cache.wait_for_sync], fork
    [workers] worker fibers each looping
    [Workqueue.get -> reconcile -> map Reconciler.Result.t to
    forget/add_rate_limited/add_after -> Workqueue.done_]. *)

type t
(** Opaque, non-parameterised handle. Every [Make(R).create] — regardless
    of [R] — produces this same type (the [R.t] is closed over inside the
    worker closures and never appears in [t]'s type), so a [Manager] can
    hold controllers for different Kinds in one plain list. *)

val run : sw:Eio.Switch.t -> t -> unit
(** Forks the reflector fiber and worker fibers onto [sw] and returns
    immediately — same "fork, then let the enclosing Switch.run block"
    pattern the verified low-level client already uses. *)

module Make (R : Resource.S) : sig
  val create :
     ctx:Context.t
    -> ?namespace:string
    -> ?label_selector:string
    -> ?workers:int (** default 1 *)
    -> reconciler:R.t Reconciler.t
    -> unit
    -> t
end
