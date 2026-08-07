type t =
  | Api_error of string
  | Conflict
  | Msg of string

let to_string = function
  | Api_error s -> Printf.sprintf "api error: %s" s
  | Conflict -> "conflict (409)"
  | Msg s -> s
