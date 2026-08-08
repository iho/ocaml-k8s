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

val with_leader_election : t -> Leader_election.config -> t
(** Returns a manager whose [run] first blocks acquiring (and then keeps
    renewing) a [coordination.k8s.io/v1] Lease — see {!Leader_election} —
    before starting any registered controller: standard active/passive HA
    for operators, so only one replica acts at a time. Uses [Context.client]
    of the [ctx] passed to {!create} for the Lease's own GET/PUT/POST calls
    — safe to share with every registered controller's [~ctx] (unlike an
    earlier version of this library, a controller's own [Reflector] now
    always clones its own connection rather than accepting a caller-
    supplied one — see {!Controller.Make}'s [create] — so there's no longer
    a way for this to accidentally end up sharing a connection with a
    long-lived WATCH; that used to be a real, silent failure mode here,
    found by running two [leader_demo] candidates against a real Lease
    with one shared connection each: the "leader"'s own renewals starved
    behind its controller's WATCH, its lease quietly expired, and the
    other candidate legitimately stole it — both then ran as "leader"
    simultaneously).

    If leadership is ever lost after having been acquired,
    {!Leader_election.Leadership_lost} tears down every controller sharing
    [run]'s [~sw] — see that exception's doc comment. *)

val add_health_check : t -> name:string -> (unit -> bool) -> unit
(** Registers an extra, named liveness check — {!serve_health}'s
    [/healthz] fails (503) if any registered check returns [false] or
    raises (a check throwing counts as "failed", not a crash — see
    {!serve_health}). No checks registered at all still answers 200: a
    process able to answer the request is, by definition, alive. Order
    of registration relative to {!serve_health} doesn't matter — checks
    are read fresh on every request, not snapshotted. *)

val add_readiness_check : t -> name:string -> (unit -> bool) -> unit
(** Same, for {!serve_health}'s [/readyz] — for anything a caller's own
    reconcilers or dependencies need beyond the two checks {!serve_health}
    always includes for free (see there): every registered controller's
    initial cache sync, and current leadership if
    {!with_leader_election} was used. *)

val render_checks : (string * (unit -> bool)) list -> bool * string
(** Runs every [(name, check)] pair and builds the [/healthz]/[/readyz]
    response {!serve_health} sends — [(all_ok, body)]. A check that
    raises counts as failed rather than propagating (see {!serve_health}).
    Exposed, like {!Metrics_prometheus.render} and
    {!Admission.response_json}, purely so it — the actual
    decision/formatting logic — can be unit-tested against a synthetic
    check list with no server or cluster involved; {!serve_health} is
    what actually calls it. *)

val serve_health : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> t -> port:int -> unit
(** Starts a plain HTTP server (like {!Metrics_prometheus.serve} — meant
    to be probed by the kubelet from inside the pod network, not exposed
    externally) forked onto [sw], answering:
    - [GET /healthz]: every check registered via {!add_health_check}.
    - [GET /readyz]: every check registered via {!add_readiness_check},
      plus, without the caller doing anything: [<kind>-synced] for each
      registered controller (from {!Controller.is_synced} — false until
      its first LIST has landed) and, only if {!with_leader_election} was
      used, [leader-election] (false until this replica has acquired the
      lease; see {!with_leader_election}'s doc comment for why it never
      goes back to [false] afterwards).

    Response body lists each check as [\[+\]name ok] or [\[-\]name failed],
    one per line — the same format `k8s.io/apiserver`'s own [/healthz]
    uses, recognizable if you've read one before. 200 if every check in
    that response passed, 503 if any failed. 404 for any other path. *)
