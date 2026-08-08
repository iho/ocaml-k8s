(** Kubernetes' generic [meta/v1.Status] object — the body of every API
    error response (and, on success, of some write operations that don't
    return the object itself, e.g. a bare DELETE). Parsing this out of
    [Client]'s error paths is what lets {!Reconcile_error.Conflict} (and
    similar) actually get populated from a real HTTP response instead of
    being unreachable dead code — see [Client.Error.of_response]. *)
type t =
  { status : string (** ["Success"] | ["Failure"] *)
  ; message : string option
  ; reason : string option (** e.g. ["Conflict"], ["NotFound"], ["AlreadyExists"] *)
  ; code : int option (** the HTTP status, duplicated into the body by convention *)
  }

val of_json : Yojson.Safe.t -> t option
(** [None] if [j] isn't shaped like a Status object (missing [kind] =
    ["Status"], or missing the [status] field itself). *)

val is_conflict : t -> bool
(** [reason = Some "Conflict"] — the 409 optimistic-concurrency case every
    write in this library can hit (a PUT against a stale
    [resourceVersion]). *)

val is_not_found : t -> bool
(** [reason = Some "NotFound"] — the case {!Client.get} already turns into
    [Ok None] before a caller would ever see a [Status.t] for it, but
    surfaced for callers parsing a [Status.t] from elsewhere. *)
