(* Pure tests for the new Client.with_retry / Error.is_transient helper and
   the Event codec. No cluster, no HTTP server — these exercise only the
   decision logic and JSON marshalling, consistent with the rest of this
   project's minimalism. *)

open Eio
let check msg cond = if not cond then failwith ("FAILED: " ^ msg)
module E = K8s.Client.Error

(* A Status.t with a given HTTP code, used to build Api_error fixtures. *)
let api_status ?(code = 500) ?(reason = "InternalError") () : K8s.Status.t =
  { status = "Failure"; message = Some "boom"; reason = Some reason; code = Some code }

(* ---------- Error.is_transient ---------- *)
let test_is_transient () =
  check "Http (transport) is transient" (E.is_transient (E.Http "connection refused"));
  check "500 Api_error is transient" (E.is_transient (E.Api_error (api_status ~code:500 ())));
  check "503 Api_error is transient" (E.is_transient (E.Api_error (api_status ~code:503 ())));
  check "404 is NOT transient" (not (E.is_transient (E.Api_error (api_status ~code:404 ~reason:"NotFound" ()))));
  check "409 conflict is NOT transient" (not (E.is_transient (E.Api_error (api_status ~code:409 ~reason:"Conflict" ()))));
  check "400 bad request is NOT transient" (not (E.is_transient (E.Api_error (api_status ~code:400 ~reason:"BadRequest" ()))));
  check "Gone (410) is NOT transient" (not (E.is_transient (E.Gone { last_resource_version = "x" })));
  check "Decode is NOT transient" (not (E.is_transient (E.Decode "bad json")));
  traceln "OK  Error.is_transient (transport/5xx transient; 4xx/Gone/Decode not)"
;;

(* ---------- Client.with_retry ---------- *)
let test_with_retry_retries_transient_then_succeeds () =
  let attempts = ref 0 in
  let sleeps = ref [] in
  (* fail twice with 500, succeed on the third *)
  let f () =
    incr attempts;
    if !attempts < 3 then Error (E.Api_error (api_status ~code:500 ())) else Ok "done"
  in
  let r = K8s.Client.with_retry ~max_attempts:3 ~base_delay:0.001 ~max_delay:1.0 ~sleep:(fun d -> sleeps := d :: !sleeps) f in
  check "retry succeeded after transient failures" (r = Ok "done");
  check "made 3 attempts" (!attempts = 3);
  check "slept between retries (2 sleeps)" (List.length !sleeps = 2);
  traceln "OK  with_retry retries transient failures then succeeds"
;;

let test_with_retry_gives_up_after_max_attempts () =
  let attempts = ref 0 in
  let f () = incr attempts; Error (E.Api_error (api_status ~code:503 ())) in
  let r = K8s.Client.with_retry ~max_attempts:3 ~base_delay:0.001 ~max_delay:1.0 ~sleep:(fun _ -> ()) f in
  check "returns the last error after exhausting attempts" (match r with Error (E.Api_error s) -> s.code = Some 503 | _ -> false);
  check "made exactly max_attempts attempts" (!attempts = 3);
  traceln "OK  with_retry gives up after max_attempts"
;;

let test_with_retry_does_not_retry_4xx () =
  let attempts = ref 0 in
  let f () = incr attempts; Error (E.Api_error (api_status ~code:404 ~reason:"NotFound" ())) in
  let slept = ref false in
  let r = K8s.Client.with_retry ~max_attempts:5 ~base_delay:0.001 ~sleep:(fun _ -> slept := true) f in
  check "4xx returned immediately" (match r with Error (E.Api_error s) -> s.code = Some 404 | _ -> false);
  check "no retry (1 attempt)" (!attempts = 1);
  check "no sleep on non-transient" (not !slept);
  traceln "OK  with_retry does not retry a 4xx"
;;

let test_with_retry_backoff_increases () =
  let delays = ref [] in
  let attempts = ref 0 in
  let f () = incr attempts; if !attempts < 4 then Error (E.Http "refused") else Ok () in
  ignore (K8s.Client.with_retry ~max_attempts:4 ~base_delay:0.01 ~max_delay:10.0
            ~sleep:(fun d -> delays := d :: !delays) f);
  (* 3 sleeps, doubling: 0.01, 0.02, 0.04 *)
  check "slept 3 times" (List.length !delays = 3);
  let d = List.rev !delays in
  check "backoff starts at base_delay" (Float.abs (List.nth d 0 -. 0.01) < 1e-9);
  check "backoff doubles" (Float.abs (List.nth d 1 -. 0.02) < 1e-9);
  check "backoff doubles again" (Float.abs (List.nth d 2 -. 0.04) < 1e-9);
  traceln "OK  with_retry backoff increases exponentially"
;;

(* ---------- Event codec round-trip ---------- *)
let test_event_codec () =
  let involved : K8s.Event.R.involved_object =
    { kind = "Widget"; name = "w1"; namespace = Some "default"; uid = Some "u1"; api_version = Some "example.com/v1" }
  in
  let e : K8s.Event.R.t =
    { metadata = { name = "w1.abc"; namespace = Some "default"; uid = None; resource_version = None; generation = None;
                   deletion_timestamp = None; finalizers = []; owner_references = [] }
    ; involved_object = involved
    ; reason = "SuccessfulCreate"; message = "created replica set"; type_ = "Normal"; count = 1
    ; first_timestamp = Some "2026-08-08T10:00:00Z"; last_timestamp = Some "2026-08-08T10:00:00Z" }
  in
  let json = K8s.Event.R.to_json e in
  (match K8s.Event.R.of_json json with
   | Ok e' ->
     check "Event round-trip preserves reason" (e'.reason = "SuccessfulCreate");
     check "Event round-trip preserves type" (e'.type_ = "Normal");
     check "Event round-trip preserves involvedObject.kind" (e'.involved_object.kind = "Widget");
     check "Event round-trip preserves involvedObject.namespace" (e'.involved_object.namespace = Some "default");
     check "Event round-trip preserves count" (e'.count = 1)
   | Error m -> failwith ("Event of_json failed: " ^ m));
  traceln "OK  Event codec round-trip"
;;

let () =
  Eio_main.run @@ fun _env ->
  test_is_transient ();
  test_with_retry_retries_transient_then_succeeds ();
  test_with_retry_gives_up_after_max_attempts ();
  test_with_retry_does_not_retry_4xx ();
  test_with_retry_backoff_increases ();
  test_event_codec ();
  traceln "ALL CLIENT_RETRY + EVENT TESTS PASSED"
