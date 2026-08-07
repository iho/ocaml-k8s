type t =
  | Api_error of string (** generalised {!Client.Error.to_string} *)
  | Conflict (** 409 optimistic-concurrency — common enough to name
                 explicitly so a caller can special-case "just requeue,
                 don't log loudly" *)
  | Msg of string

val to_string : t -> string
