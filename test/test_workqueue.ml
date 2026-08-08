(* No test framework dependency (kept consistent with the rest of this
   project's minimalism) — just plain assertions. Failure raises, so [dune
   test] reports it via the executable's non-zero exit. Pure/no network, as
   called for by the Phase 3 roadmap entry for Workqueue. *)

open Eio
module Wq = K8s.Workqueue

let req name : K8s.Request.t = { namespace = None; name }
let check msg cond = if not cond then failwith ("FAILED: " ^ msg)

let test_dedup ~sw ~clock () =
  let wq = Wq.create ~sw ~clock () in
  let a = req "a" in
  Wq.add wq a;
  Wq.add wq a;
  Wq.add wq a;
  check "len = 1 after three Adds of the same key" (Wq.len wq = 1);
  (match Wq.get wq with
   | Some r -> check "get returns the deduped key" (r = a)
   | None -> failwith "get returned None unexpectedly");
  check "len = 0 after get" (Wq.len wq = 0);
  Wq.done_ wq a;
  traceln "OK  dedup"

let test_redeliver_if_dirty_after_done ~sw ~clock () =
  let wq = Wq.create ~sw ~clock () in
  let a = req "a" in
  Wq.add wq a;
  (match Wq.get wq with
   | Some r -> check "first get returns a" (r = a)
   | None -> failwith "expected a");
  (* re-Add while "processing": marks dirty, does *not* requeue yet *)
  Wq.add wq a;
  check "len stays 0 while a is still processing" (Wq.len wq = 0);
  Wq.done_ wq a;
  check "done_ requeues a because it was marked dirty" (Wq.len wq = 1);
  (match Wq.get wq with
   | Some r -> check "second get returns a again" (r = a)
   | None -> failwith "expected a a second time");
  Wq.done_ wq a;
  traceln "OK  redeliver-if-dirty-after-done_"

let test_add_after ~sw ~clock () =
  let wq = Wq.create ~sw ~clock () in
  let a = req "a" in
  let start = Time.now clock in
  Wq.add_after wq a ~delay:0.1;
  (match Wq.get wq with
   | Some r ->
     let elapsed = Time.now clock -. start in
     check "add_after delivers a" (r = a);
     check
       (Printf.sprintf "add_after waited close to 0.1s (got %.3fs)" elapsed)
       (Float.abs (elapsed -. 0.1) < 0.05)
   | None -> failwith "expected a");
  Wq.done_ wq a;
  traceln "OK  add_after"

let test_rate_limited_backoff_increases ~sw ~clock () =
  let wq = Wq.create ~sw ~clock ~base_delay:0.05 ~max_delay:10.0 () in
  let a = req "a" in
  let time_one_round () =
    let t0 = Time.now clock in
    Wq.add_rate_limited wq a;
    (match Wq.get wq with
     | Some r -> check "backoff round delivers a" (r = a)
     | None -> failwith "expected a");
    let elapsed = Time.now clock -. t0 in
    Wq.done_ wq a;
    elapsed
  in
  let d1 = time_one_round () in
  let d2 = time_one_round () in
  check (Printf.sprintf "first backoff ~0.05s (got %.3fs)" d1) (Float.abs (d1 -. 0.05) < 0.05);
  check (Printf.sprintf "second backoff ~0.10s (got %.3fs)" d2) (Float.abs (d2 -. 0.1) < 0.05);
  check (Printf.sprintf "backoff strictly increases (%.3fs -> %.3fs)" d1 d2) (d2 > d1);
  Wq.forget wq a;
  traceln "OK  add_rate_limited backoff increases across consecutive calls"

let test_failure_count ~sw ~clock () =
  let wq = Wq.create ~sw ~clock ~base_delay:0.001 ~max_delay:0.01 () in
  let a = req "a" in
  check "failure_count starts at 0" (Wq.failure_count wq a = 0);
  let bump_and_drain () =
    Wq.add_rate_limited wq a;
    (match Wq.get wq with
     | Some r -> check "delivers a" (r = a)
     | None -> failwith "expected a");
    Wq.done_ wq a
  in
  bump_and_drain ();
  check "failure_count = 1 after one add_rate_limited" (Wq.failure_count wq a = 1);
  bump_and_drain ();
  check "failure_count = 2 after a second add_rate_limited" (Wq.failure_count wq a = 2);
  check "peeking failure_count doesn't itself count as an attempt" (Wq.failure_count wq a = 2);
  Wq.forget wq a;
  check "forget resets failure_count to 0" (Wq.failure_count wq a = 0);
  traceln "OK  failure_count tracks add_rate_limited calls, reset by forget"

let test_shutdown_unblocks_get ~sw ~clock () =
  let wq = Wq.create ~sw ~clock () in
  let result = ref (Some (req "never set")) in
  Fiber.both
    (fun () -> result := Wq.get wq)
    (fun () ->
      Time.sleep clock 0.05;
      Wq.shutdown wq);
  check "get returns None once shut down" (!result = None);
  traceln "OK  shutdown unblocks a waiting get"

(* Regression test: cancelling a fiber while it's blocked in [get] (as
   opposed to [get] returning normally via [shutdown]'s broadcast) must
   not poison the queue's mutex. [Eio.Mutex.use_rw] disables the mutex on
   *any* exception escaping its callback, including a cancellation that
   only interrupted the wait — this was caught by end-to-end testing
   (SIGINT during a live watch, not by this suite) as a real
   [Eio.Mutex.Poisoned] crash before [get] was switched to [use_ro]. *)
let test_cancel_while_blocked_in_get_does_not_poison ~sw ~clock () =
  let wq = Wq.create ~sw ~clock () in
  (try
     Switch.run (fun inner_sw ->
       Fiber.fork ~sw:inner_sw (fun () -> ignore (Wq.get wq : K8s.Request.t option));
       Switch.fail inner_sw Exit)
   with _ -> ());
  let a = req "a" in
  Wq.add wq a;
  (match Wq.get wq with
   | Some r -> check "queue still usable after a cancelled get" (r = a)
   | None -> failwith "queue unusable after cancellation (mutex likely poisoned)");
  Wq.done_ wq a;
  traceln "OK  cancelling a blocked get does not poison the queue"

let () =
  Eio_main.run
  @@ fun env ->
  Switch.run
  @@ fun sw ->
  let clock = env#clock in
  test_dedup ~sw ~clock ();
  test_redeliver_if_dirty_after_done ~sw ~clock ();
  test_add_after ~sw ~clock ();
  test_rate_limited_backoff_increases ~sw ~clock ();
  test_failure_count ~sw ~clock ();
  test_shutdown_unblocks_get ~sw ~clock ();
  test_cancel_while_blocked_in_get_does_not_poison ~sw ~clock ();
  traceln "ALL WORKQUEUE TESTS PASSED"
