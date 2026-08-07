(** GroupVersionKind: the three-part identifier that, together with a
    "plural" REST path segment (see {!Resource}), is everything needed to
    address a Kubernetes API resource. *)

type t =
  { group : string  (** the empty string for the core/legacy API group (Pods, ConfigMaps, ...) *)
  ; version : string  (** e.g. ["v1"] *)
  ; kind : string  (** e.g. ["Pod"] *)
  }

val core : version:string -> kind:string -> t
(** [core ~version ~kind] builds a GVK in the empty ("core") group, e.g.
    [core ~version:"v1" ~kind:"Pod"]. *)

val api_version : t -> string
(** ["group/version"], or just ["version"] when [group = ""], matching the
    [apiVersion] field Kubernetes objects carry. *)

val to_string : t -> string
(** e.g. ["v1, Kind=Pod"] — for logs. *)
