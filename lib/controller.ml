type t = unit

let run ~sw:_ (_ : t) =
  failwith
    "TODO(Phase 4): fork the reflector fiber, wait for Cache.wait_for_sync, \
     then fork `workers` worker fibers pulling from the Workqueue"

module Make (_ : Resource.S) = struct
  let create ~ctx:_ ?namespace:_ ?label_selector:_ ?workers:_ ~reconciler:_ () : t = ()
end
