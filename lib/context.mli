(** Carries everything reconcilers and internal machinery need that isn't
    Kind-specific. Reconcilers are handed a [Context.t], never a raw
    [Eio.Switch.t] — they get resource-bounded cancellation checks via
    {!is_cancelled} instead of the ability to fork arbitrary long-lived
    fibers onto the controller's switch. *)
type t

(** A no-op implementation is the default; {!Metrics_prometheus} is a real
    in-process backend implementing this. [Controller] calls [inc_counter]/
    [observe]/[set_gauge] itself (reconcile count/duration, workqueue
    depth — see its doc comment for the exact names/labels), so plugging in
    a real backend instruments every controller automatically, with no
    per-reconciler code needed. *)
module Metrics : sig
  type t

  val noop : t

  val create :
     inc_counter:(name:string -> labels:(string * string) list -> unit)
    -> set_gauge:(name:string -> labels:(string * string) list -> float -> unit)
    -> observe:(name:string -> labels:(string * string) list -> float -> unit)
    -> t
  (** Builds a [t] from a real backend's three operations — what
      {!Metrics_prometheus.context_metrics} uses. *)

  val inc_counter : t -> name:string -> labels:(string * string) list -> unit
  (** Increments a counter by 1 — Prometheus counters only ever go up, so
      there's no arbitrary-delta variant: callers wanting "+N" call this N
      times, same as every other Prometheus client library's convention. *)

  val set_gauge : t -> name:string -> labels:(string * string) list -> float -> unit
  (** Sets a gauge to an absolute value (unlike {!inc_counter}, which is
      always relative) — for a quantity that goes up and down, like queue
      depth, not a running total. *)

  val observe : t -> name:string -> labels:(string * string) list -> float -> unit
  (** Records one sample into a histogram/summary — e.g. one reconcile's
      duration in seconds. *)
end

val create : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> client:Client.t -> ?log:(string -> unit) -> ?metrics:Metrics.t -> unit -> t
(** Takes the whole [env] (needed anyway by anything that opens its own
    network connection, e.g. a Reflector's dedicated watch connection via
    {!Client.clone}), not a bare [clock]: [Eio.Time.clock] alone is a
    row-polymorphic resource type (its concrete instantiation varies by
    backend), so [Context.t] couldn't store one monomorphically without
    itself becoming parametric, but [Eio_unix.Stdenv.base] is concrete and
    can be. [env#clock] is consumed immediately to close over the internal
    {!sleep}/{!now} closures. This is what lets [Controller.create] and
    [Reflector.create] take just [~ctx] instead of [~ctx ~env ~clock]. *)

val env : t -> Eio_unix.Stdenv.base
val client : t -> Client.t
val sleep : t -> float -> unit
val now : t -> float
(** Monotonic-ish wall-clock seconds from the same [env#clock] {!sleep}
    uses — e.g. for measuring a reconcile's duration by subtracting two
    calls, as {!Controller} does. *)

val log : t -> ('a, unit, string, unit) format4 -> 'a
val metrics : t -> Metrics.t

val is_cancelled : t -> bool
(** Non-blocking check, for reconcilers doing multi-step work that want to
    bail out early on shutdown instead of relying on the next blocking IO
    call to raise [Eio.Cancel.Cancelled]. *)
