type t =
  { ctx : Context.t
  ; mutable controllers : Controller.t list
  ; mutable leader_election : Leader_election.config option
  }

let create ~ctx () = { ctx; controllers = []; leader_election = None }
let add_controller t c = t.controllers <- c :: t.controllers
let with_leader_election t config = { t with leader_election = Some config }

let run ~sw (t : t) =
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
  match t.leader_election with
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
      Leader_election.run ~sw ~ctx:t.ctx config ~on_acquired:start_controllers)

let todo name = failwith (Printf.sprintf "TODO(Phase 6): Manager.%s" name)
let add_health_check (_ : t) ~name:_ (_ : unit -> bool) = todo "add_health_check"
let add_readiness_check (_ : t) ~name:_ (_ : unit -> bool) = todo "add_readiness_check"
