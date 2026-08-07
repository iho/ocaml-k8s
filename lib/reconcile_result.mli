type action =
  | Done
  | Requeue
  | Requeue_after of float (** seconds *)

type 'status t = private
  { action : action
  ; status : 'status option
    (** [Some s] — {!Controller} PUTs [s] to the object's [/status]
        subresource (via [R.with_status] + {!Client.update_status}) before
        acting on [action]. [None] — no status write. *)
  }
(** Private: always built via the smart constructors below, never with
    record syntax, so an omitted [~status] can't be mistaken for an
    intentional "clear the status" (there's no way to express that here —
    on purpose; nothing in this design ever deletes a status). *)

val done_ : ?status:'status -> unit -> 'status t
val requeue : ?status:'status -> unit -> 'status t
val requeue_after : ?status:'status -> float -> 'status t
