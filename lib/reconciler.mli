module Result : sig
  type t =
    | Done
    | Requeue
    | Requeue_after of float (** seconds *)
end

module Error : sig
  type t =
    | Api_error of string (** generalised {!Client.Error.to_string} *)
    | Conflict (** 409 optimistic-concurrency — common enough to name
                   explicitly so a caller can special-case "just requeue,
                   don't log loudly" *)
    | Msg of string

  val to_string : t -> string
end

(** The business logic. Generic in ['a], the decoded object type — a
    [Controller.Make(R)] fixes it to [R.t]. Deliberately *not* a module
    type: it's one function, so a bare value is simpler than a module.
    Errors are values, not exceptions, per the "explicit errors" design
    rule; only genuine bugs or cancellation should raise. *)
type 'a t = Context.t -> 'a Cache.t -> Request.t -> (Result.t, Error.t) result
