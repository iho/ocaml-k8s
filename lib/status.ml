type t =
  { status : string
  ; message : string option
  ; reason : string option
  ; code : int option
  }

let of_json j =
  let open Yojson.Safe.Util in
  match j |> member "kind" |> to_string_option, j |> member "status" |> to_string_option with
  | Some "Status", Some status ->
    Some
      { status
      ; message = j |> member "message" |> to_string_option
      ; reason = j |> member "reason" |> to_string_option
      ; code = j |> member "code" |> to_int_option
      }
  | _ -> None

let is_conflict t = t.reason = Some "Conflict"
let is_not_found t = t.reason = Some "NotFound"
