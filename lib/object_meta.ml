type t =
  { name : string
  ; namespace : string option
  ; uid : string option
  ; resource_version : string option
  ; generation : int option
  ; deletion_timestamp : string option
  ; finalizers : string list
  }

open Yojson.Safe.Util

let of_json j =
  { name = j |> member "name" |> to_string_option |> Option.value ~default:""
  ; namespace = j |> member "namespace" |> to_string_option
  ; uid = j |> member "uid" |> to_string_option
  ; resource_version = j |> member "resourceVersion" |> to_string_option
  ; generation = j |> member "generation" |> to_int_option
  ; deletion_timestamp = j |> member "deletionTimestamp" |> to_string_option
  ; finalizers =
      (match member "finalizers" j with
       | `List l -> List.filter_map to_string_option l
       | _ -> [])
  }

let to_json t =
  `Assoc
    (List.filter_map Fun.id
       [ Some ("name", `String t.name)
       ; Option.map (fun ns -> "namespace", `String ns) t.namespace
       ; Option.map (fun uid -> "uid", `String uid) t.uid
       ; Option.map (fun rv -> "resourceVersion", `String rv) t.resource_version
       ; Option.map (fun g -> "generation", `Int g) t.generation
       ; Option.map (fun dt -> "deletionTimestamp", `String dt) t.deletion_timestamp
       ; (if t.finalizers = [] then None else Some ("finalizers", `List (List.map (fun f -> `String f) t.finalizers)))
       ])
