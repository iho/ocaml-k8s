(** Declaring secondary (child) resources a controller "owns", so that a
    change to a child reconciles its owner — the client-go [Owns(&Child{})]
    pattern, addressing the README's "No secondary-resource watches"
    limitation. A controller that creates child objects (a Deployment owns
    ReplicaSets; an operator CR owns Deployments) otherwise never notices a
    child that was deleted or drifted, because the primary Kind didn't
    move. {!Controller.Make.create} takes an [?owns] list of these; each
    runs an extra reflector whose events are mapped back onto the primary
    workqueue. *)

module type S = sig
  module R : Resource.S
  (** The child/secondary Kind being watched. *)

  val map : R.t -> Request.t option
  (** Turns a child object into the owner's reconcile [Request.t], or
      [None] when this child isn't owned by a primary this controller
      manages (so a reflector over a shared child Kind doesn't wake
      unrelated owners). The natural implementation reads the child's
      [ownerReferences] and returns the owning primary's request. *)
end
