(** An in-process Prometheus registry: implements {!Context.Metrics.t} for
    real, and can render/serve what it's recorded in the standard text
    exposition format. Nothing else in this library depends on this module
    — {!Context.Metrics.noop} is the default, and a caller not wanting
    Prometheus specifically can implement {!Context.Metrics.create} against
    any other backend just as easily. *)

type t

val create : unit -> t
(** A fresh, empty registry. One per process is normal — every
    {!Controller}/{!Manager} sharing it (pass the same {!context_metrics}
    result to every [Context.create]) ends up on one combined [/metrics]
    endpoint, distinguished by their [kind]/[group_version] labels. *)

val context_metrics : t -> Context.Metrics.t
(** Pass to [Context.create ~metrics] — see {!Controller}'s doc comment
    for exactly what gets recorded once this is wired in. *)

val render : t -> string
(** Prometheus text exposition format (the `text/plain; version=0.0.4`
    that `/metrics` conventionally serves) for everything recorded so far.
    Counters/gauges/histograms are standard Prometheus types; histogram
    buckets are a fixed default set (matching the Prometheus client
    libraries' own convention: 5ms.. 10s), not configurable per metric —
    deliberately, to avoid a bucket-configuration API nothing here needs
    yet. *)

val serve : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> t -> port:int -> unit
(** Starts an HTTP/1.1 server, forked onto [sw], answering [GET /metrics]
    with {!render} and 404 for anything else. Returns immediately — the
    server keeps running in the background until [sw] is cancelled, same
    lifecycle as every other resource in this library. Plain HTTP, no TLS:
    intended to be scraped from inside the cluster network (the same trust
    boundary kubelet's own `/metrics` uses), not exposed externally. *)
