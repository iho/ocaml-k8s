type t =
  { mutex : Eio.Mutex.t
  ; condition : Eio.Condition.t
  ; queue : Request.t Queue.t
  ; dirty : (Request.t, unit) Hashtbl.t
  ; processing : (Request.t, unit) Hashtbl.t
  ; mutable shutting_down : bool
  ; failures : (Request.t, int) Hashtbl.t
  ; sw : Eio.Switch.t
  ; sleep : float -> unit
  ; base_delay : float
  ; max_delay : float
  }

let create ~sw ~clock ?(base_delay = 0.005) ?(max_delay = 1000.0) () =
  { mutex = Eio.Mutex.create ()
  ; condition = Eio.Condition.create ()
  ; queue = Queue.create ()
  ; dirty = Hashtbl.create 64
  ; processing = Hashtbl.create 64
  ; shutting_down = false
  ; failures = Hashtbl.create 64
  ; sw
  ; sleep = Eio.Time.sleep clock
  ; base_delay
  ; max_delay
  }

(* Every mutator below returns whether a waiter should be woken, and the
   caller broadcasts *after* releasing the mutex (per Eio.Condition's
   documented usage) rather than while still holding it. *)

let add t req =
  let should_broadcast =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
      if t.shutting_down || Hashtbl.mem t.dirty req
      then false
      else (
        Hashtbl.replace t.dirty req ();
        if Hashtbl.mem t.processing req
        then false
        else (
          Queue.push req t.queue;
          true)))
  in
  if should_broadcast then Eio.Condition.broadcast t.condition

let get t =
  (* [use_ro], not [use_rw ~protect:false]: [Eio.Mutex.use_rw] *disables*
     the mutex if [fn] raises, even with [~protect:false] — appropriate
     when an interrupted mutation might leave the table inconsistent, but
     wrong here. The only thing in [fn] that can raise is
     [Condition.await] being cancelled (e.g. the worker fiber pulling from
     this queue got cancelled during shutdown while idle) — a purely
     read-only wait; it is documented to re-lock the mutex before
     propagating, so the table is still perfectly consistent when that
     happens. [use_ro] unlocks-without-poisoning on exception, which is
     exactly the (correct) behaviour wanted, despite [get] doing writes
     below: those writes are unreachable except after [await] has already
     returned normally. *)
  Eio.Mutex.use_ro t.mutex (fun () ->
    while Queue.is_empty t.queue && not t.shutting_down do
      Eio.Condition.await t.condition t.mutex
    done;
    if Queue.is_empty t.queue
    then None (* shutting down and fully drained *)
    else (
      let req = Queue.pop t.queue in
      Hashtbl.replace t.processing req ();
      Hashtbl.remove t.dirty req;
      Some req))

let done_ t req =
  let should_broadcast =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
      Hashtbl.remove t.processing req;
      if Hashtbl.mem t.dirty req
      then (
        Queue.push req t.queue;
        true)
      else false)
  in
  if should_broadcast then Eio.Condition.broadcast t.condition

let shutdown t =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> t.shutting_down <- true);
  (* Wakes every fiber blocked in [get] so they can re-check
     [shutting_down] and return [None] instead of waiting forever. *)
  Eio.Condition.broadcast t.condition

let len t = Eio.Mutex.use_ro t.mutex (fun () -> Queue.length t.queue)

let forget t req = Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> Hashtbl.remove t.failures req)

(* [base_delay * 2^failures], capped at [max_delay]; mirrors client-go's
   ItemExponentialFailureRateLimiter. *)
let next_delay t req =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    let failures = Option.value (Hashtbl.find_opt t.failures req) ~default:0 in
    Hashtbl.replace t.failures req (failures + 1);
    Float.min t.max_delay (t.base_delay *. (2.0 ** float_of_int failures)))

let add_after t req ~delay = Eio.Fiber.fork ~sw:t.sw (fun () -> t.sleep delay; add t req)
let add_rate_limited t req = add_after t req ~delay:(next_delay t req)
