type t =
  { api_version : string
  ; kind : string
  }

let of_json j =
  let open Yojson.Safe.Util in
  match j |> member "apiVersion" |> to_string_option, j |> member "kind" |> to_string_option with
  | Some api_version, Some kind -> Some { api_version; kind }
  | _ -> None
