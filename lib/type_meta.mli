(** [apiVersion]/[kind], read from an arbitrary object without already
    knowing its [Resource.S]. [Resource.S.to_json] implementations
    hardcode these on the way *out* from [gvk], and [of_json]
    implementations ignore them on the way *in* (trusting the caller
    asked for the right Kind) — this is for the cases that don't already
    know the Kind: walking a heterogeneous List response's items, or
    reading an {!Owner_reference}. *)
type t =
  { api_version : string
  ; kind : string
  }

val of_json : Yojson.Safe.t -> t option
(** [None] if either field is missing. *)
