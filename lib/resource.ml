module type S = sig
  type t
  type status

  val gvk : Gvk.t
  val plural : string
  val namespaced : bool
  val of_json : Yojson.Safe.t -> (t, string) result
  val to_json : t -> Yojson.Safe.t
  val status_of_json : Yojson.Safe.t -> (status, string) result
  val status_to_json : status -> Yojson.Safe.t
  val status : t -> status option
  val with_status : t -> status -> t
  val name : t -> string
  val namespace : t -> string option
  val resource_version : t -> string option
  val uid : t -> string option
  val deletion_timestamp : t -> string option
  val finalizers : t -> string list
end

module Unstructured (Spec : sig
    val gvk : Gvk.t
    val plural : string
    val namespaced : bool
  end) =
struct
  type t = Yojson.Safe.t
  type status = Yojson.Safe.t

  let gvk = Spec.gvk
  let plural = Spec.plural
  let namespaced = Spec.namespaced
  let of_json j = Ok j
  let to_json j = j
  let status_of_json j = Ok j
  let status_to_json j = j

  open Yojson.Safe.Util

  let status t =
    match member "status" t with
    | `Null -> None
    | s -> Some s

  let with_status t s =
    match t with
    | `Assoc fields -> `Assoc (("status", s) :: List.remove_assoc "status" fields)
    | other -> other (* not a JSON object; nothing sensible to do *)

  let metadata t = member "metadata" t
  let name t = metadata t |> member "name" |> to_string_option |> Option.value ~default:""
  let namespace t = metadata t |> member "namespace" |> to_string_option
  let resource_version t = metadata t |> member "resourceVersion" |> to_string_option
  let uid t = metadata t |> member "uid" |> to_string_option
  let deletion_timestamp t = metadata t |> member "deletionTimestamp" |> to_string_option

  let finalizers t =
    match metadata t |> member "finalizers" with
    | `List l -> List.filter_map to_string_option l
    | _ -> []
end
