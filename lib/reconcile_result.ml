type action =
  | Done
  | Requeue
  | Requeue_after of float

type 'status t =
  { action : action
  ; status : 'status option
  }

let done_ ?status () = { action = Done; status }
let requeue ?status () = { action = Requeue; status }
let requeue_after ?status delay = { action = Requeue_after delay; status }
