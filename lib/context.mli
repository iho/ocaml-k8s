(** Carries everything reconcilers and internal machinery need that isn't
    Kind-specific. Reconcilers are handed a [Context.t], never a raw
    [Eio.Switch.t] — they get resource-bounded cancellation checks via
    {!is_cancelled} instead of the ability to fork arbitrary long-lived
    fibers onto the controller's switch. *)
type t

(** Stub for now — a no-op implementation is the default. A future
    Prometheus backend just implements this. *)
module Metrics : sig
  type t

  val noop : t
  val inc_counter : t -> name:string -> labels:(string * string) list -> unit
  val observe : t -> name:string -> labels:(string * string) list -> float -> unit
end

val create :
   sw:Eio.Switch.t
  -> client:Client.t
  -> clock:_ Eio.Time.clock
  -> ?log:(string -> unit)
  -> ?metrics:Metrics.t
  -> unit
  -> t
(** [clock] is consumed immediately to close over an internal [sleep]
    closure — [Eio.Time.clock] is a row-polymorphic resource type (its
    concrete instantiation varies by backend), so [Context.t] cannot store
    one monomorphically without itself becoming parametric. Exposing just
    {!sleep} (all any caller in this design actually needs) sidesteps that
    while keeping [Context.t] a plain, non-parametric type — important
    since [Reflector]/[Controller]/[Manager] all reference it directly. *)

val client : t -> Client.t
val sleep : t -> float -> unit
val log : t -> ('a, unit, string, unit) format4 -> 'a
val metrics : t -> Metrics.t

val is_cancelled : t -> bool
(** Non-blocking check, for reconcilers doing multi-step work that want to
    bail out early on shutdown instead of relying on the next blocking IO
    call to raise [Eio.Cancel.Cancelled]. *)
