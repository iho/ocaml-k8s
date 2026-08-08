(** An entry in [metadata.ownerReferences] — how a child object (e.g. a
    [ReplicaSet]) marks its owner (e.g. a [Deployment]) for garbage
    collection and for tools like [kubectl] to show ownership trees. A
    controller that creates child objects on behalf of a CR sets this on
    the children it creates; nothing in this library does that
    automatically (there's no "owns" declaration anywhere yet — a
    reconciler that creates children builds this by hand today). *)
type t =
  { api_version : string
  ; kind : string
  ; name : string
  ; uid : string
  ; controller : bool option
  ; block_owner_deletion : bool option
  }

val of_json : Yojson.Safe.t -> t option
(** [None] if [j] isn't shaped like an owner reference (missing any of
    apiVersion/kind/name/uid — the only fields Kubernetes always sets).
    Used to decode a ["ownerReferences"] JSON array entry; see
    {!Object_meta}. *)

val to_json : t -> Yojson.Safe.t
