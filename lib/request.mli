(** A namespaced name — the dedup/queue key, and what a {!Reconciler.t} is
    actually handed. Reconcilers re-fetch the current object from the local
    {!Cache} (never the API server directly) rather than being given the
    object itself, which is what makes deduplication in {!Workqueue} cheap:
    comparing two of these is comparing two strings, not deep-comparing
    JSON. *)
type t =
  { namespace : string option
  ; name : string
  }

val equal : t -> t -> bool
val compare : t -> t -> int
val to_string : t -> string
val pp : Format.formatter -> t -> unit
