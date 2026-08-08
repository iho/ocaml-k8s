(** Declaring secondary resources a controller "owns" — the missing
    client-go [Owns(&Child{})] / [Watches(&Child{}, handler)] half of the
    README's "No secondary-resource watches" limitation. A controller that
    creates child objects (a Deployment owns ReplicaSets; an operator CR owns
    Deployments) needs to be reconciled not just when its own Kind changes,
    but when a *child* changes — otherwise it never notices a child that was
    deleted or drifted, because the primary Kind didn't move.

    A [Secondary.S] pairs a child [Resource.S] with a [map] function turning
    a child object into the *owner's* reconcile [Request.t] (or [None] when
    that child isn't ours to care about — e.g. a Deployment owned by some
    other CR, filtered by checking the [ownerReferences]' controller uid
    against the primary object's [uid]). {!Controller.Make}'s [create]
    accepts an [?owns] list of these; the controller then runs an extra
    [Reflector] per secondary Kind whose events are mapped back onto the
    primary workqueue, so a child change reconciles its owner. *)

module type S = sig
  module R : Resource.S
  (** The child/secondary Kind. *)

  val map : R.t -> Request.t option
  (** Child object -> the owner's reconcile key, or [None] if this child
      isn't owned by a primary this controller manages (so a reflector
      watching a shared child Kind doesn't wake unrelated owners). The
      natural implementation reads the child's owner references (via
      {!Object_meta} for a typed [R.t], or the raw JSON for
      {!Resource.Unstructured}) and returns the request of the owning
      primary. *)
end
