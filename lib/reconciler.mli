(** The business logic, bundled with the {!Resource.S} it operates over so
    {!Controller.Make} takes a single functor argument (and so composing
    reconcilers — e.g. a future finalizer- or metrics-wrapping functor of
    type [S -> S] — is just ordinary functor composition). Errors are
    values, not exceptions, per the "explicit errors" design rule; only
    genuine bugs or cancellation should raise. *)
module type S = sig
  module R : Resource.S

  val reconcile :
     Context.t
    -> Request.t
    -> R.t option
    (** [None] iff the object no longer exists in the local cache — either
        it was deleted, or (rarely, at startup) it hasn't been observed
        yet; either way there is nothing to read. *)
    -> (R.status Reconcile_result.t, Reconcile_error.t) result
end
