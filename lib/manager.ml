type t =
  { ctx : Context.t
  ; mutable controllers : Controller.t list
  }

let create ~ctx () = { ctx; controllers = [] }
let add_controller t c = t.controllers <- c :: t.controllers

let run ~sw (t : t) =
  let shutdown signal_name =
    Context.log t.ctx "manager: received %s, shutting down..." signal_name;
    Eio.Switch.fail sw Exit
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> shutdown "SIGINT"));
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> shutdown "SIGTERM"));
  Context.log t.ctx "manager: starting %d controller(s)" (List.length t.controllers);
  List.iter (fun c -> Controller.run ~sw c) t.controllers

let todo name = failwith (Printf.sprintf "TODO(Phase 6): Manager.%s" name)
let add_health_check (_ : t) ~name:_ (_ : unit -> bool) = todo "add_health_check"
let add_readiness_check (_ : t) ~name:_ (_ : unit -> bool) = todo "add_readiness_check"

module Leader_election = struct
  type config =
    { lease_name : string
    ; lease_namespace : string
    ; identity : string
    ; lease_duration : float
    }
end

let with_leader_election (_ : t) (_ : Leader_election.config) : t = todo "with_leader_election"
