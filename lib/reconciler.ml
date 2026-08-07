module Result = struct
  type t =
    | Done
    | Requeue
    | Requeue_after of float
end

module Error = struct
  type t =
    | Api_error of string
    | Conflict
    | Msg of string

  let to_string = function
    | Api_error s -> Printf.sprintf "api error: %s" s
    | Conflict -> "conflict (409)"
    | Msg s -> s
end

type 'a t = Context.t -> 'a Cache.t -> Request.t -> (Result.t, Error.t) result
