type t =
  | Api_error of string (** generalised {!Client.Error.to_string} *)
  | Conflict (** 409 optimistic-concurrency — common enough to name
                 explicitly so a caller can special-case "just requeue,
                 don't log loudly" *)
  | Msg of string

val to_string : t -> string

val of_client_error : Client.Error.t -> t
(** [Conflict] iff the underlying API error was a 409 whose parsed
    {!Status.t} has [reason = "Conflict"] (see {!Status.is_conflict});
    otherwise [Api_error (Client.Error.to_string e)]. A reconciler calling
    into [Client] directly (e.g. via {!Finalizer}, or its own
    [Context.client] calls) can use this instead of hand-rolling the same
    check — which is exactly what it replaced in [bin/webapp_demo.ml]. *)
