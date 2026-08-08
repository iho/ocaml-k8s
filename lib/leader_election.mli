(** Active/passive leader election via a [coordination.k8s.io/v1] Lease —
    the same primitive client-go's [leaderelection] package uses. Exactly
    one candidate holding the lease at a time acts; the rest sit idle,
    retrying, ready to take over if the holder stops renewing. *)

type config =
  { lease_name : string
  ; lease_namespace : string
  ; identity : string (** unique per candidate process, e.g. hostname+pid *)
  ; lease_duration : float
    (** seconds. How long a lease is valid without a renewal before another
        candidate may steal it, and (see [run]) how long *this* candidate
        will keep retrying a failing renewal before giving up its own
        leadership. *)
  ; retry_period : float (** seconds between acquire/renew attempts *)
  }

val default_config :
   lease_name:string
  -> lease_namespace:string
  -> identity:string
  -> ?lease_duration:float (** default 15.0 *)
  -> ?retry_period:float (** default 2.0 *)
  -> unit
  -> config
(** Same defaults client-go's [leaderelection] package uses (minus its
    separate [RenewDeadline]: this implementation folds that into
    [lease_duration] — see [run] — to keep the config smaller). *)

exception Leadership_lost
(** Raised via [Switch.fail] (not locally) when [run] can no longer be
    sure this candidate still holds the lease — deliberately *not* caught
    anywhere in this library, so it propagates as a loud, uncaught
    failure with a non-zero exit code, the same fail-safe client-go's
    [OnStoppedLeading] typically implements with [os.Exit(1)]: continuing
    to act as leader without being sure is worse than crashing. *)

val run : sw:Eio.Switch.t -> ctx:Context.t -> config -> on_acquired:(unit -> unit) -> unit
(** Blocks the calling fiber trying to acquire the lease: every
    [retry_period], checks it, and either creates it (nobody holds it
    yet), steals it (the current holder's [renewTime] is older than its
    [leaseDurationSeconds] — presumed dead), or just waits (someone else
    holds it, not yet stale). Never gives up trying to acquire; only
    network/API errors are logged, not fatal, here.

    Once acquired, calls [on_acquired] — expected to be non-blocking, the
    same contract as {!Controller.run} (e.g. it forks controllers onto
    [sw] and returns) — then loops renewing the lease every [retry_period].
    Unlike acquiring, renewal has a deadline: if a full [lease_duration]
    passes without a *successful* renewal (repeated errors, or another
    identity winning a race and taking the lease), leadership can no
    longer be assured, and [Switch.fail sw Leadership_lost] is called,
    tearing down everything [on_acquired] started — along with everything
    else sharing [sw], including any other registered controllers, since
    a [Manager] shares one switch for exactly this reason (see
    [Manager.run]'s doc comment on [~sw]). *)
