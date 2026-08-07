(** Everything a Kind needs to statically provide so the generic
    client/reflector/controller machinery can talk about it without being
    hardcoded to Pods. One module per Kind — typed bindings (a future
    [Pod.t], [Config_map.t], ...) and the generic {!Unstructured} functor
    below both produce values of this signature. *)
module type S = sig
  type t

  val gvk : Gvk.t
  val plural : string
  (** REST path segment, e.g. ["pods"] — used to build
      [/api/{version}/namespaces/{ns}/{plural}] (core group) or
      [/apis/{group}/{version}/namespaces/{ns}/{plural}] (named group). *)

  val namespaced : bool

  val of_json : Yojson.Safe.t -> (t, string) result
  val to_json : t -> Yojson.Safe.t

  (* Universal ObjectMeta accessors every Kind has, needed by the generic
     layers (Cache keying, Reflector, finalizer helpers) so they never have
     to know a Kind-specific field layout. *)
  val name : t -> string
  val namespace : t -> string option
  val resource_version : t -> string option
  val uid : t -> string option

  (* extension point: finalizers *)
  val deletion_timestamp : t -> string option
  val finalizers : t -> string list
end

module Unstructured (Spec : sig
    val gvk : Gvk.t
    val plural : string
    val namespaced : bool
  end) : S with type t = Yojson.Safe.t
(** Generic escape hatch for Kinds without typed bindings yet — CRDs, or
    anything you don't want to model. Decodes/encodes as plain JSON and
    reads ObjectMeta fields dynamically (best-effort: missing/malformed
    fields degrade to [""]/[None]/[[]] rather than raising, since this is
    fed directly from watch-stream events and must never crash a
    long-running reflector on one odd object). *)
