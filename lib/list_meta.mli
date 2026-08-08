(** The [metadata] of a LIST response (as opposed to an individual
    object's [ObjectMeta]) — e.g. [{"kind":"PodList","metadata":
    {"resourceVersion":"123"},"items":[...]}]. [Client.list] already
    extracts [resourceVersion] out of this ad hoc, inline; this just gives
    that a name and picks up the pagination fields, which nothing here
    uses yet ([Client.list] doesn't paginate — every list call fetches the
    whole collection in one request, fine at the scale this is built for,
    revisit if that changes). *)
type t =
  { resource_version : string option
  ; continue_token : string option
  ; remaining_item_count : int option
  }

val of_json : Yojson.Safe.t -> t
(** [j] is expected to be the ["metadata"] object of a List response. *)
