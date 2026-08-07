(** Add/remove a named finalizer, the standard Kubernetes mechanism for a
    controller to block an object's actual deletion until it has run its
    own cleanup: adding a finalizer string makes a DELETE only set
    [metadata.deletionTimestamp] instead of removing the object outright;
    removing the last finalizer lets the API server finish the deletion.
    See {!Resource.S}'s [deletion_timestamp]/[finalizers] accessors — a
    reconciler checks [deletion_timestamp <> None] to know it should run
    cleanup and then {!remove} its finalizer, rather than doing its normal
    work.

    Operates purely at the JSON level via [R.to_json]/[R.of_json] — no
    [with_finalizers] on {!Resource.S} is needed, since this never has to
    hand a caller back a modified value, only PUT one. *)

val has : resource:(module Resource.S with type t = 'a) -> 'a -> name:string -> bool

val add :
   Client.t
  -> resource:(module Resource.S with type t = 'a)
  -> 'a
  -> name:string
  -> (unit, Client.Error.t) result
(** No-op (returns [Ok ()] without a request) if [name] is already
    present. Otherwise PUTs the object with [name] appended to its
    finalizers, via {!Client.update} — a *separate* connection from
    whatever's watching this object's Kind, for the same reason
    {!Controller.Make}'s [~client] is: see its doc comment. *)

val remove :
   Client.t
  -> resource:(module Resource.S with type t = 'a)
  -> 'a
  -> name:string
  -> (unit, Client.Error.t) result
(** No-op if [name] is already absent. Otherwise PUTs the object with
    [name] removed from its finalizers. *)
