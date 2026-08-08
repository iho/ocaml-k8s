(* Pure in the sense of no cluster/network -- just the in-process registry
   (Metrics_prometheus.create/context_metrics/render) exercised directly
   through Context.Metrics.t's three operations, checking the rendered
   text exposition format is well-formed and the numbers in it are right.
   Still needs a real Eio scheduler running (Eio_main.run), since the
   registry's internal Eio.Mutex isn't usable outside one.
   Metrics_prometheus.serve (the actual /metrics HTTP endpoint) needs a
   real cluster to be worth exercising and is covered by
   bin/metrics_demo.ml instead, not here. *)

let check msg cond = if not cond then failwith ("FAILED: " ^ msg)

let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  go 0

let () =
  Eio_main.run
  @@ fun _env ->
  let reg = K8s.Metrics_prometheus.create () in
  let m = K8s.Metrics_prometheus.context_metrics reg in
  K8s.Context.Metrics.inc_counter m ~name:"widgets_total" ~labels:[ "outcome", "done" ];
  K8s.Context.Metrics.inc_counter m ~name:"widgets_total" ~labels:[ "outcome", "done" ];
  K8s.Context.Metrics.inc_counter m ~name:"widgets_total" ~labels:[ "outcome", "error" ];
  K8s.Context.Metrics.set_gauge m ~name:"queue_depth" ~labels:[] 3.0;
  K8s.Context.Metrics.set_gauge m ~name:"queue_depth" ~labels:[] 5.0;
  (* label order shouldn't matter -- same series either way *)
  K8s.Context.Metrics.observe m ~name:"duration_seconds" ~labels:[ "kind", "Widget"; "op", "get" ] 0.02;
  K8s.Context.Metrics.observe m ~name:"duration_seconds" ~labels:[ "op", "get"; "kind", "Widget" ] 0.2;
  K8s.Context.Metrics.observe m ~name:"duration_seconds" ~labels:[ "kind", "Widget"; "op", "get" ] 20.0;
  let text = K8s.Metrics_prometheus.render reg in

  check "counter TYPE line present" (contains text ~needle:"# TYPE widgets_total counter");
  check "counter{outcome=\"done\"} = 2" (contains text ~needle:"widgets_total{outcome=\"done\"} 2");
  check "counter{outcome=\"error\"} = 1" (contains text ~needle:"widgets_total{outcome=\"error\"} 1");

  check "gauge TYPE line present" (contains text ~needle:"# TYPE queue_depth gauge");
  check "gauge holds the last set_gauge value, not a sum" (contains text ~needle:"queue_depth 5");
  check "gauge overwrite didn't leave the old value behind too" (not (contains text ~needle:"queue_depth 3"));

  check "histogram TYPE line present" (contains text ~needle:"# TYPE duration_seconds histogram");
  (* Two observations (0.02, 0.2) landed in the same series regardless of
     label insertion order; a third (20.0) exceeds every finite bucket. *)
  check "0.02s and 0.2s both count toward the le=0.25 bucket (cumulative)"
    (contains text ~needle:"duration_seconds_bucket{kind=\"Widget\",le=\"0.25\",op=\"get\"} 2");
  check "the le=0.01 bucket (below both real observations) is 0, not absent"
    (contains text ~needle:"duration_seconds_bucket{kind=\"Widget\",le=\"0.01\",op=\"get\"} 0");
  check "the +Inf bucket includes the 20.0s outlier: count=3"
    (contains text ~needle:"duration_seconds_bucket{kind=\"Widget\",le=\"+Inf\",op=\"get\"} 3");
  check "duration_seconds_count = 3" (contains text ~needle:"duration_seconds_count{kind=\"Widget\",op=\"get\"} 3");
  check "duration_seconds_sum = 0.02 + 0.2 + 20.0 = 20.22"
    (contains text ~needle:"duration_seconds_sum{kind=\"Widget\",op=\"get\"} 20.22");

  (* Label value escaping: a literal quote and backslash in a label value
     must round-trip into valid Prometheus text, not break the format. *)
  K8s.Context.Metrics.inc_counter m ~name:"escaping_total" ~labels:[ "msg", {|say "hi" \ bye|} ];
  let text2 = K8s.Metrics_prometheus.render reg in
  check "backslash escaped" (contains text2 ~needle:{|\\|});
  check "quote escaped" (contains text2 ~needle:{|say \"hi\" \\ bye|});

  Eio.traceln "OK  Prometheus registry: counters, gauges, histograms, label escaping";
  Eio.traceln "ALL METRICS_PROMETHEUS TESTS PASSED"
