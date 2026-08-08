(** The generalised HTTP client: LIST and WATCH for any {!Resource.S}, on
    top of Piaf. This is [bin/main.ml]'s original hardcoded-to-Pods
    [list_pods]/[watch_pods] (see the project's first iteration), factored
    so the REST path and JSON decoding come from a [Resource.S] module
    instead of being written out by hand per Kind. *)

type t

module Error : sig
  type t =
    | Gone of { last_resource_version : string }
    (** 410: the watch's [resourceVersion] fell out of etcd's compaction
        window. Distinguished from other HTTP errors so a {!Reflector} can
        react by re-LISTing instead of treating it as fatal. *)
    | Api_error of Status.t
    (** Any other non-2xx response whose body parsed as a Kubernetes
        [meta/v1.Status] object — i.e. essentially every API error, since
        that's what the server sends. Carries [reason]/[code] structured,
        so callers (see [Reconcile_error.of_client_error]) can distinguish
        e.g. a 409 conflict from other failures without string-matching a
        formatted message. *)
    | Http of string (** a non-2xx response whose body did *not* parse as
                          a Status object (rare — a misbehaving proxy, an
                          HTML error page, ...) *)
    | Decode of string

  val is_transient : t -> bool
  (** [true] for failures that retrying has a reasonable chance of fixing:
      a transport/connection error (the request may never have reached the
      server), or a server-side 5xx. [false] for a definitive rejection
      (4xx — [NotFound], [Conflict], bad request) which retrying cannot
      change, and for {!Gone}/{!Decode} which a caller handles specially.
      {!with_retry} uses this to decide what to retry. *)

  val to_string : t -> string
end

val of_env : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> (t, Error.t) result
(** Zero-config: in-cluster ServiceAccount config if
    [KUBERNETES_SERVICE_HOST] is set, else falls back to [kubectl proxy] at
    [http://127.0.0.1:8001]. Same resolution the original demo binary did
    by hand in [resolve_auth]/[in_cluster_auth]. *)

val create :
   sw:Eio.Switch.t
  -> Eio_unix.Stdenv.base
  -> base_url:string
  -> ?token:string
  -> ?ca_cert:Piaf.Cert.t
  -> ?client_cert:Piaf.Cert.t
  -> ?client_key:Piaf.Cert.t
  -> ?insecure:bool
  -> unit
  -> (t, Error.t) result
(** Explicit connection settings, for callers overriding the [of_env]
    defaults (e.g. CLI flags). [client_cert]/[client_key] enable mutual TLS
    (mTLS) — the API server requests a client certificate in the TLS
    handshake, an alternative to bearer-token auth common for out-of-cluster
    operators (a kubeconfig [client-certificate] + [client-key]). Both must
    be given together; if only one is, it's ignored. The underlying Piaf
    connection is closed automatically via [Switch.on_release sw] — callers
    do not need to call {!shutdown} themselves unless they want to close it
    early. *)

val clone : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> t -> (t, Error.t) result
(** Opens an *independent* connection (a fresh TCP+TLS handshake, not a
    lightweight operation) with the same [base_url]/auth/TLS settings as
    [t] — reusing [t]'s already-resolved headers rather than re-reading a
    token file, so it works the same regardless of whether [t] was built
    via [of_env] or [create]. [Reflector]/[Controller] call this
    internally so a caller only ever builds *one* [Client.t]: see their
    doc comments for the starvation bug this exists to make structurally
    impossible instead of merely documented against. *)

val shutdown : t -> unit

val list :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> ?label_selector:string
  -> ?field_selector:string
  -> unit
  -> ('a list * string, Error.t) result
(** Returns the decoded items and the list's [resourceVersion], which is
    what a caller watches from next. *)

val watch :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> ?label_selector:string
  -> ?field_selector:string
  -> ?timeout_seconds:int
  -> resource_version:string
  -> on_event:('a Watch_event.t -> unit)
  -> unit
  -> (unit, Error.t) result
(** Blocks the calling fiber, invoking [on_event] for each
    ADDED/MODIFIED/DELETED/BOOKMARK event, until the server closes the
    stream, [Error.Gone] is returned, or the enclosing [Switch] is
    cancelled — cancellation interrupts the underlying streaming HTTP read,
    same as the already-verified low-level watch.

    [timeout_seconds], if given, is sent as the [timeoutSeconds] query
    param: it asks the API server to close the stream after that many
    seconds (rather than its default, several minutes), which a {!Reflector}
    treats as a routine "watch stream closed, re-list" and reconnects from.
    Passing it gives a predictable re-list cadence that also functions as a
    keep-alive check on the stream. *)

val get :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> name:string
  -> unit
  -> ('a option, Error.t) result
(** [Ok None] specifically on 404 (not found) — every other failure,
    including a decode error, is [Error]. Used by {!Leader_election} to
    check a Lease's current state before deciding whether to create,
    steal, or renew it. *)

val create_object :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> 'a
  -> ('a, Error.t) result
(** POSTs [R.to_json obj] to the collection path (.../<plural>), returning
    the server's version of it (with [resourceVersion]/[uid]/etc. now
    populated) on success. Used by {!Leader_election} to create a Lease
    that doesn't exist yet. *)

val update : t -> resource:(module Resource.S with type t = 'a) -> 'a -> (unit, Error.t) result
(** PUTs [R.to_json obj] to [.../<plural>/<name>] — replaces the whole
    object (metadata/spec/status, subject to the same
    [metadata.resourceVersion] optimistic-concurrency check every
    Kubernetes write uses: a stale [obj] gets a 409, surfaced as
    [Error (Http ...)]). Used by {!Finalizer}; a reconciler wanting to
    change its own [spec] would use this too, though nothing in this
    library does yet. *)

val update_status : t -> resource:(module Resource.S with type t = 'a) -> 'a -> (unit, Error.t) result
(** PUTs [R.to_json obj] to [.../<plural>/<name>/status]. Per Kubernetes
    convention the [/status] subresource endpoint reads and persists only
    the body's ["status"] key, ignoring any ["spec"]/["metadata"] changes
    in it — so sending the full object, as [to_json] does, is correct and
    standard (it's what client-go's [UpdateStatus] does too). Untyped/JSON
    at this layer, same as [list]/[watch]: the typed marshalling
    ([R.with_status]) happens one layer up, in [Controller]. *)

val delete :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> name:string
  -> ?resource_version:string
  -> unit
  -> (unit, Error.t) result
(** DELETEs [.../<plural>/<name>]. When [resource_version] is given, it's
    sent as a [DeleteOptions] precondition — a [metadata.resourceVersion]
    optimistic-concurrency check that returns a 409 (as [Error (Api_error
    _)] with [Status.is_conflict]) instead of deleting if the object has
    since changed. [Ok ()] on any successful status; the response body is
    discarded (a DELETE returns either a [Status] object or nothing, never
    the resource itself). *)

val patch :
   t
  -> resource:(module Resource.S with type t = 'a)
  -> ?namespace:string
  -> name:string
  -> body:Yojson.Safe.t
  -> unit
  -> ('a, Error.t) result
(** PATCHes [.../<plural>/<name>] with an RFC 7386 merge patch (content
    type [application/merge-patch+json]) — a sparse object whose fields are
    merged over the server's current state, leaving unspecified fields
    untouched. Unlike {!update}'s whole-object PUT it cannot collide on
    fields it isn't setting, which makes it the standard way to touch just
    [status] (or one [spec] field) without carrying a fresh copy of the
    whole object. Returns the server's version of the object (with the
    merged [resourceVersion]) on success. The [body] is raw JSON here,
    deliberately: constructing a merge patch usually means picking a subset
    of an object's fields, which the typed [Resource.S] layer can't express
    — a caller does it directly against the JSON. *)

val with_retry :
   ?max_attempts:int
  -> ?base_delay:float
  -> ?max_delay:float
  -> sleep:(float -> unit)
  -> (unit -> ('a, Error.t) result)
  -> ('a, Error.t) result
(** Runs [f ()] — a single [Client] operation returning [('a, Error.t)
    result] — retrying on {!Error.is_transient} failures (transport errors
    and 5xx) with capped exponential backoff, up to [max_attempts] total
    tries ([base_delay] doubling per retry, capped at [max_delay]; the same
    scheme {!Reflector} and {!Workqueue} already use). A non-transient
    error, or the final attempt failing, is returned unchanged. [sleep] is
    the caller's [Context.sleep].

    Purpose: a reconciler calling the low-level client directly (a
    [Client.get]/[Client.update] against [Context.client ctx]) gets the
    same retry-on-transient-failure behaviour the Reflector/Controller
    machinery already has, without threading backoff through every caller.
    Reads (LIST/GET/WATCH) are inherently safe to retry; wrap a write
    (PUT/PATCH/DELETE) only when its own idempotence makes a re-send safe —
    in particular never wrap a [DeleteOptions]-preconditioned DELETE, whose
    whole point is to reject a stale caller with a 409 rather than be
    re-sent. *)
