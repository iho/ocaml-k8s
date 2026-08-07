type t = unit

let create ~sw:_ ~clock:_ ?base_delay:_ ?max_delay:_ () : t = ()
let todo name = failwith (Printf.sprintf "TODO(Phase 3): Workqueue.%s" name)
let add (_ : t) (_ : Request.t) = todo "add"
let add_after (_ : t) (_ : Request.t) ~delay:_ = todo "add_after"
let add_rate_limited (_ : t) (_ : Request.t) = todo "add_rate_limited"
let forget (_ : t) (_ : Request.t) = todo "forget"
let get (_ : t) : Request.t option = todo "get"
let done_ (_ : t) (_ : Request.t) = todo "done_"
let shutdown (_ : t) = todo "shutdown"
let len (_ : t) : int = todo "len"
