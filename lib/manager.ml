type t = unit

let todo name = failwith (Printf.sprintf "TODO(Phase 5/6): Manager.%s" name)
let create ~ctx:_ () : t = ()
let add_controller (_ : t) (_ : Controller.t) = todo "add_controller"
let run ~sw:_ (_ : t) = todo "run"
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
