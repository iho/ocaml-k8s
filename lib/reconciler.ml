module type S = sig
  module R : Resource.S

  val reconcile :
     Context.t
    -> Request.t
    -> R.t option
    -> (R.status Reconcile_result.t, Reconcile_error.t) result
end
