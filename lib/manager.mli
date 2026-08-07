(** Runs one or more {!Controller.t} under a single [Switch], handling
    graceful shutdown.

    STUB — signature is final, bodies are not implemented yet (roadmap
    Phase 5): [run] installs SIGINT/SIGTERM handlers that [Switch.fail sw
    Exit] (the mechanism already verified in the original demo binary via
    manual [kill -INT] testing, centralised here instead of duplicated per
    binary), then forks every registered controller onto [sw]. *)

type t

val create : ctx:Context.t -> unit -> t
val add_controller : t -> Controller.t -> unit
val run : sw:Eio.Switch.t -> t -> unit

(* --- extension points: real signatures now, stub implementations later --- *)

val add_health_check : t -> name:string -> (unit -> bool) -> unit
val add_readiness_check : t -> name:string -> (unit -> bool) -> unit
(** Roadmap Phase 6: wired to an HTTP endpoint, reusing Piaf's server side
    ([Piaf.Server], already available). *)

module Leader_election : sig
  type config =
    { lease_name : string
    ; lease_namespace : string
    ; identity : string
    ; lease_duration : float
    }
end

val with_leader_election : t -> Leader_election.config -> t
(** Roadmap Phase 6: returns a manager whose [run] first blocks acquiring
    and renewing a [coordination.k8s.io/v1] Lease before starting any
    controller — standard active/passive HA for operators. *)
