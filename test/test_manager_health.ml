(* Pure: no cluster, no HTTP server, no real Controller/Manager.t --
   Manager.render_checks against synthetic check lists. The rest of
   Manager.serve_health (routing /healthz vs /readyz, the 200/503 status
   code, the built-in controller-synced/leader-election checks) needs a
   real Controller and a real cluster to be worth exercising and is
   covered by bin/manager_demo.ml instead, not here. *)

let check msg cond = if not cond then failwith ("FAILED: " ^ msg)

let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  go 0

let () =
  (* all pass *)
  let all_ok, body = K8s.Manager.render_checks [ "a", (fun () -> true); "b", (fun () -> true) ] in
  check "all checks passing -> all_ok = true" all_ok;
  check "passing check renders [+]name ok" (contains body ~needle:"[+]a ok");
  check "passing check renders [+]name ok (b)" (contains body ~needle:"[+]b ok");
  check "all-pass body says the check passed" (contains body ~needle:"healthz check passed");

  (* one fails *)
  let all_ok, body = K8s.Manager.render_checks [ "a", (fun () -> true); "b", (fun () -> false) ] in
  check "one check failing -> all_ok = false" (not all_ok);
  check "passing check still renders ok" (contains body ~needle:"[+]a ok");
  check "failing check renders [-]name failed" (contains body ~needle:"[-]b failed");
  check "any-fail body says the check failed" (contains body ~needle:"healthz check failed");

  (* a check that raises counts as failed, not a crash *)
  let all_ok, body = K8s.Manager.render_checks [ "throws", (fun () -> failwith "boom") ] in
  check "a raising check -> all_ok = false" (not all_ok);
  check "a raising check renders as failed, not propagated" (contains body ~needle:"[-]throws failed");

  (* no checks at all -> vacuously healthy, matching "a process able to
     answer this request is, by definition, alive" *)
  let all_ok, _ = K8s.Manager.render_checks [] in
  check "no checks registered -> all_ok = true" all_ok;

  print_endline "OK  Manager.render_checks (all-pass, one-fail, raising check, empty)";
  print_endline "ALL MANAGER HEALTH TESTS PASSED"
