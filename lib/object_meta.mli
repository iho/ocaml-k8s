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
  ; owner_references : Owner_reference.t list
  }

val of_json : Yojson.Safe.t -> t
(** Best-effort, like {!Resource.Unstructured}: missing/malformed fields
    degrade to [""]/[None]/[[]] rather than raising. [j] is expected to be
    the ["metadata"] object itself (not the whole Kubernetes object). *)

val to_json : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result
(** = [fun j -> Ok (of_json j)] — [of_json] never fails (see its own doc
    comment), so this just fits [ppx_deriving_yojson]'s [(t, string)
    result] convention. A [[@@deriving yojson]]-annotated CRD record with
    a [metadata : Object_meta.t] field calls this and {!to_yojson} by
    that naming convention automatically — see gen/gen_resource.ml,
    which relies on it. *)

val to_yojson : t -> Yojson.Safe.t
(** = {!to_json}. *)
