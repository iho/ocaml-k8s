type t =
  | Api_error of string
  | Conflict
  | Msg of string

let to_string = function
  | Api_error s -> Printf.sprintf "api error: %s" s
  | Conflict -> "conflict (409)"
  | Msg s -> s

let of_client_error (e : Client.Error.t) =
  match e with
  | Api_error s when Status.is_conflict s -> Conflict
  | e -> Api_error (Client.Error.to_string e)
