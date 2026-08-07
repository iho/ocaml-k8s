let has (type a) ~resource:(module R : Resource.S with type t = a) (obj : a) ~name = List.mem name (R.finalizers obj)

(* Kubernetes' wire format always puts finalizers at metadata.finalizers
   regardless of Kind, so this can rewrite it directly in the JSON that
   [R.to_json] produces without needing a typed [with_finalizers] setter
   on [Resource.S]. *)
let with_finalizers_json json finalizers =
  match json with
  | `Assoc fields ->
    let metadata = match List.assoc_opt "metadata" fields with Some (`Assoc m) -> m | _ -> [] in
    let metadata' =
      ("finalizers", `List (List.map (fun f -> `String f) finalizers)) :: List.remove_assoc "finalizers" metadata
    in
    `Assoc (("metadata", `Assoc metadata') :: List.remove_assoc "metadata" fields)
  | other -> other

let put_finalizers (type a) client (module R : Resource.S with type t = a) (obj : a) finalizers =
  match R.of_json (with_finalizers_json (R.to_json obj) finalizers) with
  | Error msg -> Error (Client.Error.Decode msg)
  | Ok updated -> Client.update client ~resource:(module R) updated

let add (type a) client ~resource:(module R : Resource.S with type t = a) (obj : a) ~name =
  if List.mem name (R.finalizers obj) then Ok () else put_finalizers client (module R) obj (name :: R.finalizers obj)

let remove (type a) client ~resource:(module R : Resource.S with type t = a) (obj : a) ~name =
  if not (List.mem name (R.finalizers obj))
  then Ok ()
  else put_finalizers client (module R) obj (List.filter (fun f -> not (String.equal f name)) (R.finalizers obj))
