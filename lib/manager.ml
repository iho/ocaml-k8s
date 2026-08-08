type t =
  { ctx : Context.t
  ; mutable controllers : Controller.t list
  ; mutable leader_election : Leader_election.config option
  ; mutable is_leader : bool
  ; mutable health_checks : (string * (unit -> bool)) list
  ; mutable readiness_checks : (string * (unit -> bool)) list
  }

let create ~ctx () =
  { ctx
  ; controllers = []
  ; leader_election = None
  ; is_leader = false
  ; health_checks = []
  ; readiness_checks = []
  }

let add_controller t c = t.controllers <- c :: t.controllers
let with_leader_election t config = { t with leader_election = Some config }
let add_health_check t ~name f = t.health_checks <- (name, f) :: t.health_checks
let add_readiness_check t ~name f = t.readiness_checks <- (name, f) :: t.readiness_checks

let run ~sw (t : t) =
  (* Resolves when [sw] is released (i.e. when the enclosing [Switch.run]
     is tearing everything down — normal completion, or [Exit] raised by
     this manager's own signal handlers, or [Leadership_lost]). Lets a
     caller [await] the manager's lifetime instead of blocking on the
     enclosing [Switch.run] themselves; the signal handlers / controllers
     still do all the real work on [sw]. *)
  let done_promise, resolve_done = Eio.Promise.create () in
  Eio.Switch.on_release sw (fun () -> Eio.Promise.resolve resolve_done ());
  let shutdown signal_name =
    Context.log t.ctx "manager: received %s, shutting down..." signal_name;
    Eio.Switch.fail sw Exit
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> shutdown "SIGINT"));
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> shutdown "SIGTERM"));
  let start_controllers () =
    Context.log t.ctx "manager: starting %d controller(s)" (List.length t.controllers);
    List.iter (fun c -> Controller.run ~sw c) t.controllers
  in
  (match t.leader_election with
  | None -> start_controllers ()
  | Some config ->
    (* Forked, not called inline: [run] always forks-and-returns
       regardless of leader election, so callers get the same contract
       either way. The acquire loop can block for a while (patiently
       retrying forever until this candidate wins), and that wait must not
       delay [run] itself returning. *)
    Eio.Fiber.fork ~sw (fun () ->
      Context.log t.ctx "manager: acquiring leadership (lease=%s/%s, identity=%s)..." config.lease_namespace
        config.lease_name config.identity;
      Leader_election.run ~sw ~ctx:t.ctx config ~on_acquired:(fun () ->
        (* Never flipped back to [false]: losing leadership after having
           acquired it is exception-driven (see Leadership_lost), tearing
           down [sw] and everything on it, this manager included -- there
           is no graceful "no longer leader, but still running" state for
           a readiness check to observe. *)
        t.is_leader <- true;
        start_controllers ())));
  done_promise

(* Built-in readiness signals Manager already has enough information to
   provide for free: every controller's cache has completed its initial
   sync, and (only if with_leader_election was used) this replica
   currently holds leadership. add_readiness_check is for anything
   beyond that a caller's own reconcilers/dependencies need -- these two
   are never something a caller has to remember to wire up themselves. *)
let builtin_readiness_checks t =
  let controller_checks =
    List.map (fun c -> Printf.sprintf "%s-synced" (Controller.name c), fun () -> Controller.is_synced c) t.controllers
  in
  let leader_check =
    match t.leader_election with
    | None -> []
    | Some _ -> [ "leader-election", (fun () -> t.is_leader) ]
  in
  controller_checks @ leader_check

(* A check throwing is treated as "failed", not left to crash the whole
   /healthz or /readyz request -- deliberately different from
   Controller's reconcile loop or Admission.serve's handler, both of
   which let an unexpected exception propagate as a bug. A health check
   is explicitly in the business of answering "is this thing broken";
   an exception from one *is* that answer, and turning it into an opaque
   500 instead of naming which check failed would defeat the endpoint's
   whole purpose. *)
let run_checks checks =
  List.map (fun (name, f) -> name, (try f () with _ -> false)) checks

let render_checks checks =
  let results = run_checks checks in
  let all_ok = List.for_all snd results in
  let lines =
    List.map (fun (name, ok) -> Printf.sprintf "[%c]%s %s" (if ok then '+' else '-') name (if ok then "ok" else "failed")) results
  in
  let body = String.concat "\n" (lines @ (if all_ok then [ "healthz check passed" ] else [ "healthz check failed" ])) ^ "\n" in
  all_ok, body

let serve_health ~sw env (t : t) ~port =
  let address = `Tcp (Eio.Net.Ipaddr.V4.any, port) in
  let config = Piaf.Server.Config.create address in
  let handler ({ request; _ } : _ Piaf.Server.ctx) =
    match Piaf.Request.target request with
    | "/healthz" ->
      let ok, body = render_checks t.health_checks in
      Piaf.Response.of_string ~body (if ok then `OK else `Service_unavailable)
    | "/readyz" ->
      let ok, body = render_checks (builtin_readiness_checks t @ t.readiness_checks) in
      Piaf.Response.of_string ~body (if ok then `OK else `Service_unavailable)
    | _ -> Piaf.Response.of_string ~body:"not found\n" `Not_found
  in
  let server = Piaf.Server.create ~config handler in
  let (_ : Piaf.Server.Command.t) = Piaf.Server.Command.start ~sw env server in
  ()
