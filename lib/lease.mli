(** A typed binding for [coordination.k8s.io/v1] [Lease] objects — used by
    {!Leader_election}. No status subresource ([type status = unit]); all
    of a Lease's meaningful fields live in [spec]. *)

type spec =
  { holder_identity : string option
  ; lease_duration_seconds : int option
  ; acquire_time : string option (** RFC3339 *)
  ; renew_time : string option (** RFC3339 *)
  ; lease_transitions : int option
  }

type t =
  { metadata : Object_meta.t
  ; spec : spec
  }

include Resource.S with type t := t and type status = unit
