# k8s

A strict, type-driven OCaml 5 library for writing Kubernetes operators —
built on [Eio](https://github.com/ocaml-multicore/eio) (direct-style
structured concurrency: no Lwt/Async, no monadic binds) and
[Piaf](https://github.com/anmonteiro/piaf) (HTTP/1.1 + HTTP/2 + TLS).

It gives you LIST+WATCH informers, a workqueue-backed controller runtime,
typed CRD bindings (hand-written or generated from a CRD's own YAML),
finalizers, owner references, leader election, Prometheus metrics, and
admission webhooks — the pieces client-go/controller-runtime give Go
operator authors, with the type system doing more of the work: a
reconciler is `Context.t -> Request.t -> R.t option -> result`, a plain
function you can unit-test with no cluster involved.

`lib/` is the library. Everything under `bin/`, `examples/`, and `gen/`
is development tooling — demos exercised against a real cluster while
building the library, and generators for scaffolding new projects — not
part of it; see "Examples & tooling" below.

## Install

Not on the public opam repository yet — pin it from source:

```sh
opam pin add k8s git@github.com:iho/ocaml-k8s.git
```

Requires OCaml >= 5.1 and dune >= 3.0. Piaf's C stubs link against
OpenSSL; on macOS, Homebrew's OpenSSL is keg-only and not on the default
search path, so point the compiler at it first (opam will build Piaf as
part of pinning `k8s`):

```sh
export CPATH="$(brew --prefix openssl@3)/include:$CPATH"
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$LIBRARY_PATH"
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$PKG_CONFIG_PATH"
```

On Linux with `libssl-dev` installed system-wide this is usually
unnecessary.

## Quickstart

The smallest complete operator — watches ConfigMaps and logs each one:

```ocaml
open Eio
open K8s

module Config_maps = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"ConfigMap"
  let plural = "configmaps"
  let namespaced = true
end)

module Reconciler = struct
  module R = Config_maps

  let reconcile (ctx : Context.t) (req : Request.t) (_ : Config_maps.t option) =
    Context.log ctx "saw %s" (Request.to_string req);
    Ok (Reconcile_result.done_ ())
end

module My_controller = Controller.Make (Reconciler)

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  match Client.of_env ~sw env with
  | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
  | Ok client ->
    let ctx = Context.create ~sw ~client ~clock:env#clock () in
    let controller = My_controller.create ~ctx ~env ~clock:env#clock () in
    Controller.run ~sw controller
```

`Client.of_env` picks up in-cluster ServiceAccount config automatically,
falling back to `kubectl proxy` at `127.0.0.1:8001` for local testing.
`Controller.Make` wires a Reflector (LIST+WATCH with resync and backoff),
a Cache, and a Workqueue (dedup + exponential backoff) around your
`reconcile` function; `Controller.run` forks it all onto the switch and
blocks. The runnable version of this is `bin/hello_operator.ml`; see
"Examples & tooling" for progressively more complete ones (typed CRDs,
finalizers, leader election, metrics, webhooks).

## Starting your own operator

`gen/scaffold_operator.ml` generates a whole new, standalone project —
its own `dune-project`, `bin/main.ml`, and (for a custom CRD)
`deploy/*.yaml` — rather than a file to drop into this repo:

```sh
dune exec gen/scaffold_operator.exe -- ./my-operator example.com v1 Widget
cd my-operator
opam pin add k8s git@github.com:iho/ocaml-k8s.git
dune build
```

Pass `core` as the group instead of a CRD group/version for a built-in
Kind (Pod, ConfigMap, ...) — that emits a `Resource.Unstructured`-based
reconciler with no CRD YAML, since there's no schema to hand-write.
`gen/scaffold_operator.exe` with no arguments prints full usage.

## Core concepts

- **`Resource.S`** — everything a Kind needs to plug into the generic
  machinery: its `Gvk.t`, REST path, JSON codec, and a `status`
  subresource type. `Resource.Unstructured` gives you this for any Kind
  with zero typing effort (raw `Yojson.Safe.t`); a typed CRD binding is a
  record type plus a handful of functions (see `bin/webapp_demo.ml`), or
  generated from the CRD's own YAML (see "Generators").
- **`Reconciler.S`** — a `module R : Resource.S` plus one function:
  `reconcile : Context.t -> Request.t -> R.t option -> (R.status Reconcile_result.t, Reconcile_error.t) result`.
  `None` means the object is gone. The result says what happened
  (`Reconcile_result.done_`/`requeue`/`requeue_after`, optionally with a
  new `status`) or why it failed. Pure enough to unit-test directly —
  see `test/test_reconciler.ml`.
- **`Controller.Make(Reconciler)`** — wires a `Reflector`, a `Cache`, and
  a `Workqueue` around your reconciler, running `workers` worker fibers.
  Applies the reconciler's requested status write itself; if that PUT hits
  a 409 conflict it refetches the object from the API server and retries
  once before falling back to a backoff requeue. An optional `~owns` list
  of `Secondary.S` runs extra reflectors over child Kinds, mapping child
  events back onto the primary's reconcile key (so a child that's deleted
  or drifts reconciles its owner). Emits Prometheus-shaped metrics on
  every reconcile regardless of whether anything's listening (see
  "Metrics").
- **`Manager`** — aggregates controllers for different Kinds under one
  SIGINT/SIGTERM handler, with `with_leader_election` for active/standby
  HA via a `coordination.k8s.io/v1` Lease.
- **`Context.t`** — what a reconciler is actually handed: the shared
  `Client.t`, `log`, `sleep`, `metrics`, and a non-blocking
  `is_cancelled` check. Never a raw `Eio.Switch.t`.
- **`Client.t`** — the low-level piece, if you need it directly:
  LIST/WATCH/GET/CREATE/UPDATE/DELETE/PATCH/UPDATE-STATUS for any
  `Resource.S` — `DELETE` takes an optional `resourceVersion` precondition
  (a 409-guarded delete), `PATCH` is RFC 7386 merge-patch for touching a
  subset of an object without a full-object PUT, `with_retry` wraps any
  operation to retry transient failures (transport errors and 5xx) with
  exponential backoff, and `create` accepts `client_cert`/`client_key` for
  mutual-TLS auth against the API server. A caller only ever builds *one*
  `Client.t`, no matter how many controllers or a leader-election loop
  share it — `Reflector`/`Controller` each open their own dedicated
  connection internally via `Client.clone`, so a long-lived WATCH can never
  starve other traffic sharing the same connection. WATCH requests accept
  an optional `timeoutSeconds` for a predictable re-list cadence.

## Features

- **Typed CRDs** — hand-write a `Resource.S` or generate one from the
  CRD's own YAML (`gen/gen_resource.ml`) — both produce an ordinary
  module, and nothing downstream can tell which.
- **Finalizers & owner references** — `Finalizer.has`/`add`/`remove` for
  cleanup that blocks deletion until it runs; `Owner_reference.t` for
  child objects Kubernetes' own garbage collector cleans up instead, no
  finalizer needed (see `bin/owned_child_demo.ml`).
- **Leader election** — `Leader_election`/`Lease`, a typed Lease binding
  with patient acquire/steal/renew, wired through
  `Manager.with_leader_election`.
- **Metrics** — `Context.Metrics.t` is a real, pluggable interface
  (`inc_counter`/`set_gauge`/`observe`); `Controller` calls it on every
  reconcile unconditionally. `Metrics_prometheus` is a real backend: an
  in-process registry plus a `/metrics` HTTP endpoint.
- **Admission webhooks** — `Admission` handles both validating and
  mutating webhooks through one interface (`Request.t -> decision`),
  served over real TLS.
- **Health & readiness checks** — `Manager.serve_health` answers
  `/healthz`/`/readyz`; readiness includes every registered controller's
  cache-sync state and current leadership (if `with_leader_election` is
  used) automatically, with no caller code required.
- **Event recording** — `Event.Recorder` emits typed `core/v1` Events
  (Normal/Warning, `reason`/`message`) on any involved object, so operator
  activity shows up in `kubectl describe` / `kubectl get events` — the
  client-go EventRecorder complement to the Prometheus metrics.
- **Secondary-resource watches** — `Controller.Make` takes an `~owns` list
  of `Secondary.S` to run extra reflectors over child Kinds, mapping child
  events back onto the primary's reconcile key.

## Generators

Two, for different jobs:

- **`gen/gen_resource.ml`** turns one CRD YAML into a `Resource.S`
  module (`.spec`/`.status` as OCaml records, via `ppx_deriving_yojson`)
  to embed in an *existing* project:

  ```sh
  dune exec gen/gen_resource.exe -- path/to/crd.yaml > generated_module.ml
  ```

  Deliberately selective, not a general OpenAPI compiler: it reads one
  chosen `.spec.versions[]` entry and walks `object`/`properties` into
  records, `string`/`integer`/`number`/`boolean` into the obvious OCaml
  type, and `array` into `_ list`; anything else it doesn't understand
  (`oneOf`/`anyOf`/`allOf`, a schema-less object, `additionalProperties`)
  becomes a `Yojson.Safe.t` passthrough field rather than guessing wrong.
  See `generated/dune` for the reference dune-rule wiring, and
  `generated/web_app.ml` / `bin/webapp_gen_demo.ml` for a full example
  proving the output is a drop-in replacement for a hand-written binding.

- **`gen/scaffold_operator.ml`** writes an entire new, standalone
  project — see "Starting your own operator" above.

## Metrics

`Context.Metrics.t`'s default is a no-op, so instrumentation costs
nothing unless you ask for it. Plug in `Metrics_prometheus` and every
controller sharing that `Context.t` is instrumented automatically, with
no reconciler-side code:

```ocaml
let registry = Metrics_prometheus.create () in
Metrics_prometheus.serve ~sw env registry ~port:9090;  (* GET /metrics *)
let ctx = Context.create ~sw ~client ~clock:env#clock
            ~metrics:(Metrics_prometheus.context_metrics registry) () in
```

`Controller` emits `k8s_controller_reconcile_total` (counter, labelled
`kind`/`group_version`/`result`), `k8s_controller_reconcile_duration_seconds`
(histogram), and `k8s_controller_workqueue_depth` (gauge, polled every
5s). Multiple controllers sharing one registry end up on a single
`/metrics` endpoint, distinguished by those labels. See
`bin/metrics_demo.ml`.

## Admission webhooks

A `ValidatingWebhookConfiguration` and a `MutatingWebhookConfiguration`
both POST the identical `AdmissionReview` envelope and expect the
identical response schema back, so one handler covers both:

```ocaml
let handle (req : Admission.Request.t) : Admission.decision =
  match req.object_ with
  | None -> Admission.Allow
  | Some obj ->
    match Yojson.Safe.Util.(obj |> member "spec" |> member "replicas" |> to_int_option) with
    | Some n when n > 10 -> Admission.Deny (Printf.sprintf "spec.replicas=%d exceeds the max of 10" n)
    | _ -> Admission.Allow_with_patch (`List [ (* RFC 6902 JSON Patch ops *) ])
```

Unlike everything else in this library, this genuinely needs TLS and a
certificate the API server will trust — `Admission.serve` takes
`cert`/`private_key` directly; getting a certificate isn't a library
concern (X.509 generation needs its own dependency this library doesn't
otherwise want). See `bin/webhook_demo.ml`, `examples/gen-webhook-cert.sh`
(a thin `openssl` wrapper), and `examples/app-webhook.yaml` for the full
local-testing setup, including why `clientConfig.url` with
`host.docker.internal` is what makes a `kind` cluster on Docker Desktop
able to reach a webhook server running on the host.

## Health & readiness checks

```ocaml
Manager.serve_health ~sw env manager ~port:8080;  (* GET /healthz, /readyz *)
Manager.add_readiness_check manager ~name:"warmed-up" (fun () -> !some_flag);
```

`/readyz` always includes, with no caller code required: `<kind>-synced`
for every registered controller (from `Controller.is_synced` — false
until its first LIST has landed) and, if `with_leader_election` was used,
`leader-election` (false until this replica has acquired the Lease).
`add_health_check`/`add_readiness_check` are for anything beyond that —
a dependency check, a warmup flag. A check that raises counts as failed
rather than crashing the request — deliberately different from
`Controller`'s reconcile loop or `Admission.serve`, both of which let an
unexpected exception propagate as a bug: a health check's whole job is
answering "is this broken," and an exception from one *is* that answer.
Response body lists each check as `[+]name ok`/`[-]name failed`, the same
format `k8s.io/apiserver`'s own `/healthz` uses; 200 if everything in
that response passed, 503 if anything failed.

Verified against a real cluster via `bin/manager_demo.ml` (an artificial
"warmup" readiness check observed transitioning 503 → 200 after 5s,
alongside both controllers' real `-synced` checks) and two
`bin/leader_demo.ml` candidates (the `leader-election` check read `false`
for the standby and `true` for whichever actually held the lease).

## Examples & tooling

Everything below is development tooling, not the library — demos
exercised against a real cluster (via `kubectl proxy`) while building
`lib/`, kept as runnable reference material and manual regression tests
rather than an automated E2E suite.

| Binary | Demonstrates |
|---|---|
| `bin/hello_operator.ml` | The whole stack in ~20 lines — start here |
| `bin/reflector_demo.ml` | Reflector + Cache only, no reconciler |
| `bin/controller_demo.ml` | Full loop, untyped, multiple workers |
| `bin/webapp_demo.ml` / `bin/webapp_gen_demo.ml` | A typed CRD, a real `/status` PUT, a finalizer (hand-written vs. `gen_resource`-generated) |
| `bin/owned_child_demo.ml` | Creating a child object with an `OwnerReference` — no finalizer |
| `bin/periodic_demo.ml` | `Requeue_after` — reconciling on a timer, not just on watch events |
| `bin/manager_demo.ml` | Multiple controllers (different Kinds) under one `Manager`, plus `/healthz`/`/readyz` |
| `bin/leader_demo.ml` | Leader election / HA failover, plus the `leader-election` readiness check |
| `bin/metrics_demo.ml` | Real Prometheus `/metrics` |
| `bin/webhook_demo.ml` | Validating + mutating admission webhooks |
| `bin/main.ml` | The original hardcoded-to-Pods LIST+WATCH CLI, predating `Controller`/`Manager` — kept as a low-level `Client` sanity check |

`examples/` holds the CRDs/samples the CRD-based demos need. Most demos
need only `kubectl proxy --port=8001 &`; `bin/webhook_demo.ml` needs a
real cert and `WebhookConfiguration` (see "Admission webhooks" above).
Each demo file's own header comment has exact run instructions.

## Building and testing this repo

```sh
dune build
dune runtest
```

Building the demos/generators/tests (not just the `k8s` library) needs a
few more opam packages than the library itself depends on:

```sh
opam install eio_main piaf uri yojson yaml ppx_deriving_yojson base64
```

`dune runtest` is pure — no cluster or network needed: `Workqueue`
(dedup, backoff, cancellation-doesn't-poison-the-mutex), a reconciler's
decision logic (via a bare TCP listener so `Client.create`'s eager
connect succeeds, with an assertion that no HTTP I/O actually happens),
the Prometheus registry/rendering, and the admission-webhook JSON codec
against realistic `AdmissionReview` fixtures. Everything that actually
talks to Kubernetes is verified by hand against a real `kind` cluster as
each piece is built, not by an automated E2E suite.

## Known limitations

- `Leader_election`'s renew loop treats any renewal failure (a network
  blip or a real loss) the same, conservatively — the practical effect
  is giving up leadership as fast as the strictest interpretation would.
- `Controller`'s worker loop does not catch reconciler exceptions —
  deliberately: an uncaught exception is treated as a bug and propagates
  (failing that controller's switch), not silently converted into an
  endless requeue loop.
- A status PUT that fails for any *non*-conflict reason (a network blip,
  a transient 500, ...) still overrides the reconciler's requested action
  with a backoff requeue, even if it said `Done` — its intent was computed
  assuming the write would land. A 409 *conflict* is handled specially
  (one refetch-and-retry, see "Core concepts"); this limitation is about
  the other failure classes.
- The `Event.Recorder` emits fresh Events (deduplicated by Kubernetes on
  source/involvedObject/reason/message) but does not itself aggregate a
  repeated reason into a single Event with a bumped `count` the way
  client-go's recorder does before it hits the server — repeated calls
  create repeated Events that Kubernetes' own dedup then collapses.
