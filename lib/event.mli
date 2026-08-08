(** A typed binding for the core/v1 [Event] object and a small
    EventRecorder ({!Recorder}) for surfacing operator activity where
    `kubectl describe` / `kubectl get events` shows it — the EventRecorder
    from client-go, as the observability complement to the Prometheus
    metrics {!Controller} already emits. *)

module R : sig
  type involved_object =
    { kind : string
    ; name : string
    ; namespace : string option
    ; uid : string option
    ; api_version : string option
    }

  type t =
    { metadata : Object_meta.t
    ; involved_object : involved_object
    ; reason : string
    ; message : string
    ; type_ : string
    ; count : int
    ; first_timestamp : string option
    ; last_timestamp : string option
    }

  type status = unit
  include Resource.S with type t := t and type status := status
end

module Recorder : sig
  type t

  val create :
    client:Client.t
    -> source:string
    -> ?now:(unit -> string)
    -> log:(string -> unit)
    -> unit
    -> t
  (** [source] is the component name Kubernetes stores on the Event (e.g.
      the operator/controller name); [log] receives a line if a record
      fails. [?now] supplies the RFC3339 timestamps (defaults to the same
      UTC formatter the Lease code uses) — injectable for tests. *)

  val normal :
    t
    -> involved:R.involved_object
    -> reason:string
    -> message:string
    -> unit
  (** Records a [type=Normal] Event on [involved]. Fire-and-forget: a
      failure is logged via [log], never raised. *)

  val warning :
    t
    -> involved:R.involved_object
    -> reason:string
    -> message:string
    -> unit
  (** Records a [type=Warning] Event on [involved]. Fire-and-forget, same
      as {!normal}. *)
end
