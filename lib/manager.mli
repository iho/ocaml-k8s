(** Runs one or more {!Controller.t}, handling graceful shutdown. Every
    [Controller.t] — regardless of which [Resource.S] it was built from —
    is the same concrete type (see {!Controller}'s doc comment), so a
    single [Manager.t] can hold controllers for different Kinds. *)

type t

val create : ctx:Context.t -> unit -> t
val add_controller : t -> Controller.t -> unit

val run : sw:Eio.Switch.t -> t -> unit
(** Installs SIGINT/SIGTERM handlers that [Switch.fail sw Exit] (the same
    mechanism verified by hand — [kill -INT] — against [bin/main.ml] and
    the other demo binaries, centralised here instead of duplicated in
    every [main]), forks every registered controller onto [sw], and
    returns immediately — same "fork, then let the enclosing Switch.run
    block" pattern as [Controller.run].

    [sw] must be the *same* switch used to build the [Client] backing
    every controller's [Context] (i.e. the [~sw] passed to
    [Client.create]/[Client.of_env]). An earlier version of this function
    took no [~sw] and created its own private switch for the controllers,
    so it could fully own catching its own shutdown and returning
    normally rather than raising. That deadlocked: a [Client]'s
    connection-management fibers run on whatever switch it was created
    with, and normal (non-cancelling) teardown of *that* switch waits for
    them to finish before running any [on_release] cleanup — but they only
    finish once [Client]'s registered [on_release] hook calls
    [Piaf.Client.shutdown] on them, which can't run until the wait-for-
    fibers phase is already done. Sharing one [sw] for both means
    cancelling it (via this function's signal handlers) cancels the
    connection-management fibers directly too, the same way it already
    does for every other fiber in this framework, avoiding the cycle. The
    caller therefore still needs a [try ... with Exit -> ...] around the
    enclosing [Switch.run], the same as every other entry point here. *)

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
