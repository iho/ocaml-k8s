type t =
  { api_version : string
  ; kind : string
  ; name : string
  ; uid : string
  ; controller : bool option
  ; block_owner_deletion : bool option
  }

open Yojson.Safe.Util

let of_json j =
  match
    ( j |> member "apiVersion" |> to_string_option
    , j |> member "kind" |> to_string_option
    , j |> member "name" |> to_string_option
    , j |> member "uid" |> to_string_option )
  with
  | Some api_version, Some kind, Some name, Some uid ->
    Some
      { api_version
      ; kind
      ; name
      ; uid
      ; controller = j |> member "controller" |> to_bool_option
      ; block_owner_deletion = j |> member "blockOwnerDeletion" |> to_bool_option
      }
  | _ -> None

let to_json t =
  `Assoc
    (List.filter_map Fun.id
       [ Some ("apiVersion", `String t.api_version)
       ; Some ("kind", `String t.kind)
       ; Some ("name", `String t.name)
       ; Some ("uid", `String t.uid)
       ; Option.map (fun b -> "controller", `Bool b) t.controller
       ; Option.map (fun b -> "blockOwnerDeletion", `Bool b) t.block_owner_deletion
       ])
