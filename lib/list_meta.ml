type t =
  { resource_version : string option
  ; continue_token : string option
  ; remaining_item_count : int option
  }

let of_json j =
  let open Yojson.Safe.Util in
  { resource_version = j |> member "resourceVersion" |> to_string_option
  ; continue_token = j |> member "continue" |> to_string_option
  ; remaining_item_count = j |> member "remainingItemCount" |> to_int_option
  }
