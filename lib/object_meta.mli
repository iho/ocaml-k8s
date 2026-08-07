(** The standard Kubernetes [ObjectMeta] fields, typed. A convenience for
    hand-written {!Resource.S} implementations (typed CRD bindings) so
    their [of_json]/[to_json] don't each re-implement this parsing —
    {!Resource.Unstructured} doesn't use this (it reads fields on demand
    from raw JSON instead), but a typed [Resource.S.t] typically embeds a
    [t] as its [metadata] field. *)
type t =
  { name : string
  ; namespace : string option
  ; uid : string option
  ; resource_version : string option
  ; generation : int option
  ; deletion_timestamp : string option
  ; finalizers : string list
  }

val of_json : Yojson.Safe.t -> t
(** Best-effort, like {!Resource.Unstructured}: missing/malformed fields
    degrade to [""]/[None]/[[]] rather than raising. [j] is expected to be
    the ["metadata"] object itself (not the whole Kubernetes object). *)

val to_json : t -> Yojson.Safe.t
