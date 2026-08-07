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
    | Http of string
    | Decode of string

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
  -> ?insecure:bool
  -> unit
  -> (t, Error.t) result
(** Explicit connection settings, for callers overriding the [of_env]
    defaults (e.g. CLI flags). The underlying Piaf connection is closed
    automatically via [Switch.on_release sw] — callers do not need to call
    {!shutdown} themselves unless they want to close it early. *)

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
  -> resource_version:string
  -> on_event:('a Watch_event.t -> unit)
  -> unit
  -> (unit, Error.t) result
(** Blocks the calling fiber, invoking [on_event] for each
    ADDED/MODIFIED/DELETED/BOOKMARK event, until the server closes the
    stream, [Error.Gone] is returned, or the enclosing [Switch] is
    cancelled — cancellation interrupts the underlying streaming HTTP read,
    same as the already-verified low-level watch. *)

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
