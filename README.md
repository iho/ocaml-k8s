# k8s_watch

Minimal OCaml 5 + Eio Kubernetes client: LISTs Pods, then WATCHes them from
the returned `resourceVersion`, printing every `ADDED`/`MODIFIED`/`DELETED`
event. Direct-style throughout (no Lwt/Async, no monadic binds) using
[Piaf](https://github.com/anmonteiro/piaf) for HTTP/1.1 + HTTP/2 + TLS.

`bin/main.ml` is now a thin CLI wrapper around the `k8s` library in `lib/`,
which is a strictly-typed operator framework (Informer/Reflector, Workqueue,
Controller, Manager — see "Library layout & roadmap" below). `lib/client.ml`
implements LIST+WATCH+status-updates generically for any `Resource.S`, and
reconcilers are written against real OCaml types for the resources they own
— including a real CRD's spec/status — not raw JSON. A CRD's typed
`Resource.S` module can be hand-written (`bin/webapp_demo.ml`) or generated
from the CRD's own YAML (`gen/gen_resource.ml` + `generated/`,
`bin/webapp_gen_demo.ml`) — both produce an ordinary module satisfying the
same signature, and nothing downstream can tell which.

Callers only ever build *one* `Client.t`/`Context.t`, no matter how many
`Reflector`s/`Controller`s/leader-election loops share it — each opens its
own dedicated connection internally via `Client.clone` (reusing the
original's already-resolved auth/TLS settings) rather than requiring the
caller to build and correctly route a separate `Client.t` per long-lived
WATCH. That used to be a real, unenforced-by-the-type-system footgun — see
`Client.clone` in the table below and the "Notes / limitations" history of
the three connection-starvation bugs it structurally eliminates.

## Prerequisites

- OCaml >= 5.1, dune >= 3.0
- opam packages: `eio`, `eio_main`, `piaf`, `uri`, `yojson`, `yaml`,
  `ppx_deriving_yojson`

```sh
opam install eio_main piaf uri yojson yaml ppx_deriving_yojson
```

Piaf's C stubs link against OpenSSL. On macOS with Homebrew, OpenSSL is
keg-only and not on the default include/library search path, so point the
compiler at it before installing:

```sh
export CPATH="$(brew --prefix openssl@3)/include:$CPATH"
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$LIBRARY_PATH"
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install piaf
```

On Linux with `libssl-dev` installed system-wide this is usually unnecessary.

## Build

```sh
dune build
```

## Test

```sh
dune runtest
```

Currently covers `Workqueue` (`test/test_workqueue.ml`): dedup, redeliver-if-
dirty-after-`done_`, `add_after` timing, `add_rate_limited` backoff
increasing across calls, `shutdown` unblocking a waiting `get`, and —
found by end-to-end testing, not this suite originally — cancelling a
fiber while it's blocked in `get` not poisoning the queue's mutex (see
"Notes / limitations"). Pure — no cluster or network needed.

## Run

### Against `kubectl proxy` (easiest way to test locally)

```sh
kubectl proxy --port=8001 &
dune exec bin/main.exe -- --server http://127.0.0.1:8001 -n kube-system
```

`kubectl proxy` already authenticates using your local kubeconfig, so no
token or TLS setup is needed. Omit `-n` to watch Pods in all namespaces
(requires a ClusterRole that can list/watch pods cluster-wide).

### Against a real cluster with a bearer token

```sh
dune exec bin/main.exe -- \
  --server https://<api-server-host>:6443 \
  --token-file ./token \
  --ca-cert ./ca.crt \
  -n default
```

Or `--token <value>` directly instead of `--token-file`. Add `--insecure` to
skip TLS certificate verification (e.g. against a self-signed dev cluster
such as minikube) instead of passing `--ca-cert`.

### In-cluster (running as a Pod with a ServiceAccount)

Run with no `--server` flag. If `KUBERNETES_SERVICE_HOST` /
`KUBERNETES_SERVICE_PORT` are set (true inside any Pod), the binary
automatically uses:

- `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`
- the token at `/var/run/secrets/kubernetes.io/serviceaccount/token`
- the CA cert at `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`

The ServiceAccount needs RBAC permissions to `list`/`watch` pods in the
target namespace(s).

## Stopping

Ctrl-C sends SIGINT, which cancels the top-level `Eio.Switch`. That
cancellation interrupts the watch fiber's in-progress streaming read and
runs the registered cleanup hook that shuts down the HTTP connection, so the
process always exits without leaking sockets.

## Library layout & roadmap

`lib/` is an operator framework being built bottom-up on top of the verified
LIST+WATCH client. Current status per module:

| Module | Status |
|---|---|
| `Gvk`, `Request`, `Watch_event`, `Object_meta` | done — `Object_meta` includes `owner_references : Owner_reference.t list` |
| `Type_meta`, `List_meta`, `Status` | done — `apiVersion`/`kind` read without knowing the Kind, a LIST response's own metadata, and Kubernetes' generic `meta/v1.Status` error-body type, respectively |
| `Resource` | done — `Resource.S` includes a `status` subresource type (`status_of_json`/`status_to_json`/`status`/`with_status`); `Resource.Unstructured` and typed CRD bindings (hand-written, e.g. `bin/webapp_demo.ml`'s `Web_app`, or generated — see below) all implement it |
| `Client` | done — LIST/WATCH/`get`/`create_object`/`update`/`update_status` generalised over any `Resource.S`; non-2xx responses are parsed into `Error.Api_error of Status.t` when the body is a Status object (essentially always), not just a formatted string; `Client.clone` opens an independent connection reusing an existing client's auth/TLS settings, so `Reflector`/`Controller` can each get their own dedicated connection without the caller doing anything |
| `Context`, `Cache` | done |
| `Reflector` | done — List-then-Watch-forever, full resync-as-sync-events on every (re)LIST (incl. on 410/dropped connection) with capped exponential backoff; opens its own connection via `Client.clone` rather than taking a caller-supplied `~client`, so it can never accidentally share a connection with anything else; see `bin/reflector_demo.ml` |
| `Workqueue` | done — `Eio.Mutex`/`Eio.Condition`-backed dedup queue + per-item exponential backoff; see `test/test_workqueue.ml` |
| `Reconcile_result`, `Reconcile_error`, `Reconciler` | done — `Reconciler.S` bundles a `Resource.S` (`module R`) with a `reconcile : Context.t -> Request.t -> R.t option -> (R.status Reconcile_result.t, Reconcile_error.t) result`, so `Controller.Make` takes one functor argument. `Reconcile_error.of_client_error` maps a `Client.Error.t` to `Conflict` iff it's a real 409 (via `Status.is_conflict`), making that case reachable for the first time instead of dead code |
| `Controller` | done — wires Reflector + Cache + Workqueue + a `Reconciler.S`, N worker fibers, status-subresource PUTs; see `bin/controller_demo.ml` (untyped/`Unstructured`) and `bin/webapp_demo.ml` (typed CRD, real status update) |
| `Manager` | done — multi-controller aggregation, centralised SIGINT/SIGTERM handling, `with_leader_election`; see `bin/manager_demo.ml` and `bin/leader_demo.ml` |
| `Finalizer` | done — `has`/`add`/`remove`, JSON-level (no `with_finalizers` needed on `Resource.S`); see `bin/webapp_demo.ml` |
| `Lease`, `Leader_election` | done — typed `coordination.k8s.io/v1` Lease binding + an acquire/steal/renew loop (patient acquire, hard-deadline renew, fails the switch via `Leadership_lost` if renewal can't keep up); see `bin/leader_demo.ml` |
| `gen/gen_resource.ml` | done — a small, selective CRD-YAML-to-`Resource.S` generator (see "Generating typed CRD bindings" below); `generated/web_app.ml` (built by a dune rule from `examples/webapp-crd.yaml`) and `bin/webapp_gen_demo.ml` prove it's a drop-in replacement for the hand-written `Web_app` |
| `gen/scaffold_operator.ml` | done — a kubebuilder-init-style generator that writes a whole new, standalone operator project (`dune-project`/`bin/`/`deploy/*.yaml`), not a module to embed in this one (see "Scaffolding a new operator" below) |

This completes the roadmap's core bottom-up build-out plus the finalizer
and leader-election extension points (`Phase 6` health/readiness checks
remain future work — stub signatures in `lib/manager.mli`). `bin/main.ml`
still doesn't use `Reflector`/`Controller`/`Manager` — it calls
`Client.list`/`Client.watch` directly, same shape as the original
hardcoded version, just parameterised by `Resource.Unstructured` for Pods
instead of hand-written paths/JSON decoding. Six separate, minimal demo
tools exercise the higher layers directly against a real cluster:

```sh
kubectl proxy --port=8001 &
dune exec bin/reflector_demo.exe -- kube-system   # Reflector + Cache only
dune exec bin/controller_demo.exe -- kube-system  # full Reflector->Workqueue->Reconciler loop, untyped (Unstructured)
dune exec bin/manager_demo.exe -- kube-system     # two controllers (Pods + ConfigMaps) under one Manager

# typed CRD example, with a real /status subresource update and finalizer
# (hand-written Web_app -- bin/webapp_gen_demo.exe below is the same thing
# against the *generated* one):
kubectl apply -f examples/webapp-crd.yaml
kubectl apply -f examples/webapp-sample.yaml
dune exec bin/webapp_demo.exe -- default
dune exec bin/webapp_gen_demo.exe -- default
# then, in another shell, while either is running:
kubectl delete webapp hello-web    # stays "Terminating" until the finalizer is removed

# leader election: run two instances competing for the same Lease
dune exec bin/leader_demo.exe -- candidate-a kube-system
dune exec bin/leader_demo.exe -- candidate-b kube-system   # in another shell
# kill -9 whichever one is currently reconciling and watch the other take over
```

## Generating typed CRD bindings

`gen/gen_resource.ml` is a small, deliberately selective generator — not a
general OpenAPI compiler. It reads one CRD YAML's chosen `.spec.versions[]`
entry (preferring `storage: true`, falling back to the first `served:
true`, falling back to the first version present) and prints an OCaml
module implementing `Resource.S` to stdout:

```sh
dune exec gen/gen_resource.exe -- examples/webapp-crd.yaml
```

It walks `openAPIV3Schema.properties.{spec,status}` (`object`+`properties`
→ a record, recursing; `string`/`integer`/`number`/`boolean` → the obvious
OCaml type; `array`+`items` → `_ list`; anything else it doesn't
understand — `oneOf`/`anyOf`/`allOf`, a map via `additionalProperties`, a
schema-less object — becomes a `Yojson.Safe.t` passthrough field rather
than blocking generation or guessing wrong), and emits
[`ppx_deriving_yojson`](https://github.com/ocaml-ppx/ppx_deriving_yojson)-annotated
record types (`[@key "..."]` where the JSON name differs from the
snake_case OCaml field name, `[@default None]` for fields absent from the
schema's `required` list) plus the mechanical `Resource.S` wiring around
an embedded `Object_meta.t` — six lines, identical for every Kind, so it's
emitted directly rather than templated. `generated/dune` shows the
reference wiring: a `(rule ...)` runs the generator against
`examples/webapp-crd.yaml` at build time (regenerating whenever the CRD
YAML or the generator changes, like any other dune codegen), and a
`(library ...)` in the same directory picks up the rule's target with
`(preprocess (pps ppx_deriving_yojson))`.

Object_meta gained `of_yojson`/`to_yojson` aliases (`= fun j -> Ok (of_json
j)` / `= to_json`) purely so a generated record with a `metadata :
Object_meta.t` field can derive its own (de)serializer automatically —
`ppx_deriving_yojson` calls a nested custom type's `of_yojson`/`to_yojson`
by naming convention, and `Object_meta` only had `of_json`/`to_json`
before this.

### Three real bugs, all found by generating and then actually running the output — not by reading the generator's code

1. **`@key`/`@default` attributes silently ignored when parenthesized.**
   The first draft wrote `(int option [@default None])`, modelled on one
   of `ppx_deriving_yojson`'s own README examples, which shows `@default`
   used exactly that way. Wrapping the whole `type [@attrs]` group in
   parens compiles fine but the attributes don't attach where the deriver
   looks for them — every field decode failed. Found with a standalone
   throwaway (`ppx_check/`, not part of this repo) exercising the exact
   annotation shapes against real JSON *before* writing the generator
   around them, which is what caught it — not the generator's own
   (correctly unparenthesized, once fixed) output. Fixed by dropping the
   parens: `int option [@key "..."] [@default None]`, matching the
   README's other example (`lat : float [@key "Latitude"]`) exactly.
2. **`[@@deriving yojson]` decodes strictly by default.** Every LIST
   failed with a generic decode error once the generator's (corrected)
   output was actually run against a real cluster. Cause: strict mode
   rejects any JSON key without a matching record field, and a real
   Kubernetes object always has `apiVersion`/`kind` at the top level,
   which the generated `type t` — only `metadata`/`spec`/`status` —
   doesn't declare. Fixed by generating `[@@deriving yojson { strict =
   false }]` on every emitted type; `Resource.Unstructured` and the
   hand-written examples were never at risk of this since they read
   fields on demand rather than requiring an exact match.
3. **Generated `to_json` never emitted `apiVersion`/`kind` on writes.**
   With (1) and (2) fixed, LIST/WATCH worked but adding a finalizer failed
   every time with a 400 ("Object 'Kind' is missing") — legible immediately
   as a *structured* `reason`/`code` rather than a raw string, thanks to
   the new `Status`-based error parsing (bug 2 above, from the *previous*
   design turn, paying for itself on its first real use). Cause:
   `apiVersion`/`kind` aren't fields on the record — nothing decodes them
   (see bug 2) — so bare `to_yojson` never wrote them either, but the API
   server requires them on every write, not just reads. The hand-written
   examples inject them from `gvk` inside `to_json`, never storing them on
   `t`; the generator does the same now (`to_json` wraps `to_yojson`'s
   output, prepending `apiVersion`/`kind`) instead of aliasing `to_json =
   to_yojson` directly.

After all three fixes, `bin/webapp_gen_demo.ml` (identical reconcile logic
to `bin/webapp_demo.ml`, just `module Web_app = Webapp_generated.Web_app`
instead of an inline definition) passed the exact same finalizer-add,
status-PUT, and finalizer-delete-and-gone scenarios as the hand-written
version — see "Manual verification" below.

## Scaffolding a new operator

`gen/gen_resource.ml` (above) turns one CRD YAML into one module to embed
in an *existing* dune project. `gen/scaffold_operator.ml` is different in
kind, not just degree: it's a kubebuilder-init-style generator that writes
out an entire new, standalone project — its own `dune-project`, `bin/`,
and (for a custom CRD) `deploy/*.yaml` — meant to live outside this repo
entirely, not a codegen step you re-run as your schema evolves.

```sh
dune exec gen/scaffold_operator.exe -- ./my-operator example.com v1 Widget
# or, for a built-in Kind instead of a CRD:
dune exec gen/scaffold_operator.exe -- ./pod-watcher core v1 Pod
```

`<group>` being `""` or `"core"` selects which of two templates gets
emitted: a built-in Kind (`core`) gets a `Resource.Unstructured`-based
reconciler with no CRD YAML, since there's no schema to hand-write (same
shape as `bin/controller_demo.ml`); anything else gets a typed
spec/status record with one example field each, clearly marked `TODO`,
plus a matching CRD YAML and sample object (same shape as
`bin/webapp_demo.ml`) — the generator's own templates are close copies of
those two demos specifically so the output looks like normal,
hand-writable code, not something bespoke to the generator. An optional
5th argument overrides the pluralized REST path segment (default: the
Kind lowercased plus `s`); a non-empty 6th argument marks the Kind
cluster-scoped instead of namespaced.

Since `k8s` isn't published on the public opam repository, a scaffolded
project can't just list it as a normal opam dependency and have it
resolve — `dune-project` here declares a `(package (name k8s) ...)` with
`generate_opam_files true` (and `lib/dune` a matching `(public_name k8s)`)
specifically so this repo itself becomes opam-pinnable, and every
scaffolded project's generated `README.md` opens with the exact
`opam pin add k8s <url-or-path>` command needed before its own
`dune build` will find the library. Verified for real: scaffolded both a
custom-CRD operator and a core-resource one, then built both against this
repo (via a throwaway `dune-workspace` referencing this checkout, rather
than actually mutating the local opam switch just to prove buildability)
and ran the resulting binaries — both reached and exercised the exact
same `Client.of_env`/`Context.create`/`Controller.create` wiring the
hand-written demos use, failing cleanly with a connection-refused error
since no `kubectl proxy` was running for that check, not a compile or
link error.

## Notes / limitations

- `bin/main.ml` itself still doesn't re-LIST on `410 Gone` — it calls
  `Client.list`/`Client.watch` directly and just logs+stops, same as
  before. `Reflector` (used by `bin/reflector_demo.ml`, not yet by
  `main.ml`) does implement the resync: any `Client.watch` error, 410 or
  otherwise, triggers a re-LIST with capped exponential backoff (reset on
  success), and re-LISTs replace the cache's contents wholesale so objects
  deleted during a disconnection are actually dropped, not left stale.
- No global rate limiting or jitter on the Reflector's own reconnect
  backoff (just per-attempt capped exponential) — fine at the scale this
  is built for, would want jitter across many controllers hitting the same
  API server simultaneously.
- `Controller`'s worker loop does *not* catch exceptions raised by the
  reconciler — only `Error` results are handled (requeue+backoff).
  An uncaught exception is treated as a real bug and allowed to propagate
  (failing that controller's whole switch), deliberately, rather than
  being silently converted into an endless requeue loop.
- **Bug found via end-to-end testing, now fixed**: cancelling a fiber
  blocked in `Workqueue.get` — e.g. Ctrl-C arriving while a controller's
  worker fiber is idle, waiting for work — used to raise
  `Eio.Mutex.Poisoned` and crash, because `Eio.Mutex.use_rw` disables its
  mutex on *any* exception escaping the callback, even `~protect:false`,
  even one from a cancelled `Condition.await` that left the table
  perfectly consistent. `get` now uses `Eio.Mutex.use_ro`, which only
  unlocks (never poisons) on exception — correct here since `get`'s writes
  are unreachable except after `await` has already returned normally. This
  was invisible to the original unit tests (which only exercised the
  non-exceptional `shutdown`-broadcasts-`get` wake path) and only surfaced
  once `bin/controller_demo.ml` was Ctrl-C'd against a real cluster; a
  regression test (`test_cancel_while_blocked_in_get_does_not_poison`) was
  added and confirmed to fail against the old code before the fix.
- **Bug found via end-to-end testing, now fixed structurally**: a
  Reflector's WATCH is a long-lived streaming request; over `kubectl
  proxy` (HTTP/1.1), sharing one connection across controllers means every
  controller after the first just queues forever behind the first one's
  never-ending watch, with no error or timeout to surface it. First found
  by running `manager_demo` with one shared client: the second controller
  silently never printed anything, ever. Real clusters over TLS negotiate
  HTTP/2, which genuinely multiplexes and wouldn't hit this, but one
  connection per controller avoids the failure mode either way — and
  avoids one connection's traffic being able to affect another's
  regardless of protocol. The original fix required each caller to
  manually build and correctly route a *separate* `Client`/`Context` per
  controller — unenforced by the type system, and the direct cause of two
  more bugs below recurring in different shapes. Superseded: `Reflector`
  now opens its own dedicated connection internally via `Client.clone`
  (see the intro and the `Client`/`Reflector` rows above), so a caller
  only ever builds one `Client.t` and there is no longer a `~client`
  parameter to get wrong. `bin/manager_demo.ml` now shares a single
  `Client`/`Context` across both its controllers — see "Manual
  verification" below for the re-test confirming this.
- **Bug found via end-to-end testing, now fixed — a real deadlock**:
  `Manager.run` originally took no `~sw` and created its own private
  `Switch` for the controllers, specifically so it could fully own
  catching its own shutdown and return normally instead of raising
  (avoiding a `try ... with Exit` at every call site). Running
  `manager_demo` (two controllers, two `Client`s) and sending SIGINT hung
  *indefinitely* — not slowly, forever. Root cause: a `Client`'s
  connection-management fibers run on whatever switch it was built with
  (the *outer* switch, since `Client`s are built before any `Controller`
  exists); Manager's private inner switch being cancelled only stopped the
  controllers, not those connection fibers. Normal (non-cancelling)
  teardown of the outer switch then waits for those fibers to finish
  before running any `on_release` cleanup — but they only finish once
  `Client`'s `on_release` hook calls `Piaf.Client.shutdown` on them, which
  never runs because the wait-for-fibers phase it's blocked behind never
  completes. A genuine cycle. Diagnosed by adding temporary `traceln`
  calls around the shutdown hook and observing they never fired at all —
  proving the hang wasn't inside Piaf as first suspected, but before the
  release hooks ran at all. Fixed by having `Manager.run` take `~sw` and
  share the caller's switch (the same one the `Client`s were built with)
  instead of owning a private one, so cancelling it takes down the
  connection-management fibers the same way it already does every other
  fiber in this framework. Re-verified: clean exit in ~1s across 6
  repeated runs, vs. never completing (one run was left for 74s, another
  killed after being stuck well past that) before the fix. `Client.ml`
  also now bounds `Piaf.Client.shutdown` itself to 3s via
  `Eio.Time.with_timeout_exn`, defensively, independent of this fix — a
  slow graceful HTTP/2 close (GOAWAY, drain) on any single connection
  shouldn't be able to hold up every other resource's cleanup, since
  `Switch.on_release` hooks run in series, not concurrently.
- A failed status PUT *overrides* the reconciler's requested action with a
  backoff requeue, even if the reconciler said `Done` — its intent was
  computed assuming the write would land, so if it didn't, that intent
  isn't trustworthy until the write is retried and succeeds. This is a
  deliberate choice, not the only reasonable one (the alternative — trust
  the reconciler's action regardless, just log the write failure — risks a
  status that's permanently stale until something else re-triggers a
  reconcile); worth knowing if this surprises you in practice.
- **Bug found via end-to-end testing, now fixed — starvation within a
  single controller**: `bin/webapp_demo.ml`'s first version hung
  *indefinitely* on its own first status update. Root cause: a
  `Controller`'s `Reflector` and the reconciler's own API calls (status
  updates) were sharing one `Client`/connection via `Context.client ctx`
  — the same HTTP/1.1-starvation class as the earlier multi-controller
  bug, but here within *one* controller: the reflector's long-lived WATCH
  occupies the connection forever, so the reconciler's status PUT — issued
  from a different fiber on the same connection — queues behind it and
  never gets a turn. No error, no timeout, just silence, same signature as
  the earlier bug. Originally fixed by giving `Reflector.Make(R).create`
  (and, in turn, `Controller.Make(Rec).create`) its own `~client`
  parameter, explicitly separate from `Context.client ctx` — verified for
  real at the time: reset a live `WebApp`'s status to a wrong value via
  `kubectl patch --subresource=status`, ran `webapp_demo`, and confirmed
  via `kubectl get webapp ... -o jsonpath='{.status}'` that the program's
  own PUT corrected it, that the watch picking up the program's own status
  PUT as a MODIFIED event converged instead of self-triggering forever,
  and that Ctrl-C still cleanly closed both connections (~1s exit). That
  `~client` parameter was itself the footgun, though: nothing stopped a
  caller from passing the *same* `Client.t` for both, which is exactly
  what happened one level up in the leader-election bug just below.
  Superseded: `Reflector`/`Controller` now clone their own connection
  internally (see the intro above), so `bin/webapp_demo.ml` and
  `bin/webapp_gen_demo.ml` now build and pass around a single `Client.t`
  — re-verified against a real cluster with the same finalizer-add,
  status-PUT, and finalizer-delete-and-gone scenarios; see "Manual
  verification" below.
- `Leader_election`'s renew loop treats *any* renewal failure the same,
  whether it's a network error or another identity having legitimately
  won a race — both just count toward the `lease_duration` failure
  budget. This is intentionally simple (client-go distinguishes more
  cases); the practical effect is a candidate that briefly can't reach
  the API server gives up leadership exactly as fast as one that actually
  lost it, which is the conservative, safe direction to be imprecise in.
- **Bug found via end-to-end testing, now fixed — a real, rejected
  request**: the first version of `Leader_election`'s RFC3339 formatter
  produced second-precision timestamps (`...05Z`), which the Kubernetes
  API server rejected outright with a 400 for `Lease.spec.acquireTime`/
  `renewTime` specifically — those fields deserialize as Go's
  `metav1.MicroTime`, whose parser requires an exact 6-digit
  fractional-seconds field (`...05.000000Z`), unlike plain
  `metav1.Time` elsewhere. Every acquire attempt failed with a clear
  error message, so this one was quick to diagnose and fix (always emit
  the 6 digits, even when zero) — but a good reminder that "valid
  RFC3339" isn't the same as "valid for this specific field." The
  before/after fix was also verified with a small standalone date-math
  script exercising `days_from_civil`/`epoch_of_utc`/format/parse
  round-trips (including a leap-day case and fractional-seconds parsing)
  independent of any cluster, since a subtly wrong staleness calculation
  wouldn't necessarily show up as a hard error the way the format bug did.
- **Bug found via end-to-end testing, now fixed — leader election's own
  starvation bug**: with the format bug fixed, the very first two-candidate
  test still showed *both* candidates simultaneously believing they were
  leader. Root cause was the same HTTP/1.1 starvation class as the two
  bugs above, recurring a third time, one level up: `bin/leader_demo.ml`'s
  first version reused one `Client` for both the controller's Reflector
  (long-lived WATCH) and `Manager`'s own Lease renewal calls (via
  `Context.client ctx`) — the leader's renewals queued behind its own
  controller's watch and effectively stopped firing once the controller
  started, so its lease quietly expired within a few seconds and the other
  candidate legitimately (and correctly, given what it could observe)
  stole it. Not a bug in the election algorithm itself — confirmed by the
  Lease's own `leaseTransitions` field incrementing exactly once, exactly
  when expected, both times. This was the third occurrence of the same
  connection-sharing footgun in three different shapes (multi-controller,
  within-a-controller, and now leader-election-vs-its-own-controller),
  which is what motivated eliminating the footgun itself rather than
  fixing it a fourth time: originally fixed by giving the demo's
  `Manager`/`Leader_election` traffic and its controller's `Reflector`
  separate connections, the same manual per-caller discipline as the two
  bugs above — since it was still just a rule to remember, not something
  the type system enforced, getting it wrong wouldn't raise an error, it
  would just quietly break mutual exclusion again. Superseded:
  `Reflector`/`Controller` now clone their own connection internally via
  `Client.clone`, so `Leader_election`'s renewal traffic can safely share
  `ctx`'s client with everything else — `bin/leader_demo.ml` now builds
  just one `Client.t`. Re-verified against a real cluster: two candidates'
  lease `renewTime` advances normally while each holds leadership (proving
  its own renewals aren't starved behind its controller's watch), and
  `kill -9`ing the active leader produces a single clean
  `leaseTransitions` increment to the standby, not a double-leader state;
  see "Manual verification" below.

## Manual verification

Tested end-to-end against a real cluster (`kind`) via `kubectl proxy`
multiple times as the library grew:

- **`Client`**: LIST correctly enumerated existing pods and printed the
  list's `resourceVersion`; WATCH streamed `ADDED`, `MODIFIED`, `DELETED`
  in real time while a test pod was created/deleted; Ctrl-C during an
  active watch cleanly cancelled the fiber, closed the connection
  (auto-registered via `Switch.on_release`), and exited with status 0.
- **`Reflector`**: same create/delete-pod scenario through
  `bin/reflector_demo.ml` — initial LIST correctly populated the cache and
  unblocked `Cache.wait_for_sync`, watch events updated the cache and fired
  `on_event` with the same ADDED/MODIFIED/DELETED sequence, and Ctrl-C
  cancelled cleanly the same way. (A live 410 was attempted by watching
  from `resourceVersion=1` on a fresh cluster but didn't reproduce — the
  API server's watch cache still served it; the 410 branch itself is a
  one-line status-code check reviewed rather than fault-injection-tested.)
- **`Workqueue`**: no cluster needed — `dune runtest` (see "Test" above).
- **`Controller`**: `bin/controller_demo.ml` (2 workers) against a real
  cluster — the first run surfaced a real gap (pre-existing pods were
  never reconciled at startup, only pods that changed after the initial
  LIST), which led to the resync-as-sync-events fix in `Reflector`
  described above; re-running afterward showed all 8 pre-existing
  `kube-system` pods reconciled at startup followed by the test pod's full
  create/modify/delete lifecycle. Ctrl-C testing during this same run also
  surfaced the `Workqueue.get` mutex-poisoning bug described above; fixed,
  and re-verified clean (exit 0) across several repeated Ctrl-C runs.
- **`Manager`**: `bin/manager_demo.ml` (Pods + ConfigMaps controllers,
  originally each with its own `Client`/`Context`, both created and
  reconciled all 8+9 pre-existing objects at startup correctly) — this is
  where both the HTTP/1.1 connection-sharing starvation bug and the
  private-switch shutdown deadlock described above were found and fixed.
  Re-verified clean (~1s to exit) across 6 repeated Ctrl-C runs after both
  fixes.
- **Typed CRDs / status updates**: `examples/webapp-crd.yaml` (a
  `WebApp` CRD with a `/status` subresource enabled) and
  `examples/webapp-sample.yaml` applied to a real cluster, then
  `bin/webapp_demo.ml` run against it — a real OCaml record type
  (`Web_app.t`/`Web_app.status`, using the new `Object_meta` helper), not
  `Resource.Unstructured`. This is where the within-a-controller
  connection-starvation bug above was found (the demo's first version
  hung on its own status update) and fixed. After the fix: confirmed the
  program correctly detects an already-correct status and skips the PUT,
  confirmed it performs a real PUT when the status was deliberately reset
  to a wrong value first (`kubectl patch --subresource=status`) — checked
  via `kubectl get -o jsonpath` before and after, not just program output
  — confirmed the watch converges on its own PUT instead of looping, and
  confirmed clean Ctrl-C shutdown of both connections (~1s).
- **`Finalizer`**: `bin/webapp_demo.ml`'s reconciler now adds
  `webapps.example.com/cleanup` on an object's first reconcile — confirmed
  via `kubectl get -o jsonpath='{.metadata.finalizers}'` — then, with the
  program running, `kubectl delete webapp hello-web` was issued from
  another shell: the object did *not* disappear immediately (blocked by
  the finalizer, standard Kubernetes behavior), the watch delivered the
  resulting MODIFIED event with `deletionTimestamp` set almost instantly,
  the reconciler ran its (pretend) cleanup and called `Finalizer.remove`,
  and `kubectl get webapp hello-web` immediately afterward returned
  `NotFound` — the deletion genuinely completed, not just locally
  believed to have. Whole delete-to-gone cycle took well under the ~6s
  observation window.
- **`Leader_election` / `Manager.with_leader_election`**: two
  `bin/leader_demo.ml` instances (`candidate-a`, `candidate-b`) run
  simultaneously against the same real cluster, competing for one Lease.
  This is where both bugs above were found. After both fixes: confirmed
  via `kubectl get lease -o jsonpath='{.spec}'` that exactly one candidate
  held the lease at a time, with `leaseTransitions=0` and a `renewTime`
  visibly advancing every ~1s while it ran (proving it was genuinely
  renewing, not just having won the initial race) — and confirmed the
  *other* candidate's log stayed silent after its one expected failed
  create attempt, meaning it correctly recognized the lease was live and
  didn't retry-spam. Then `kill -9`'d the active leader (no graceful
  release) and confirmed the standby acquired it — `leaseTransitions=1`,
  a fresh `acquireTime` — within the expected ~`lease_duration` window
  (5s, shortened from the 15s default for a fast-to-observe test), and
  resumed reconciling. Finally confirmed clean Ctrl-C shutdown (~1s) of
  the new leader while its leader-election fiber was still active.
- **`gen/gen_resource.ml` / generated `Web_app`**: `bin/webapp_gen_demo.ml`
  run against the CRD/sample from the `webapp_demo.ml` scenario above,
  using `generated/web_app.ml` (a dune rule's output, not hand-written).
  This is where all three bugs described in "Generating typed CRD
  bindings" were found, in sequence, each by actually running the
  generator's current output against a real cluster rather than by
  re-reading the generator's code. After all three fixes: reset the
  sample object to a clean state and confirmed, via `kubectl get -o
  jsonpath` before/after (not just program output), that the generated
  module's reconciler added the finalizer, correctly performed a real
  `/status` PUT (`{"observedGeneration":1,"readyReplicas":3}`, matching
  the hand-written version's earlier result exactly), and — with a fresh
  process — that deleting the object while it ran produced the identical
  finalizer-blocks-then-completes-deletion sequence already verified for
  `bin/webapp_demo.ml`: stayed present with `deletionTimestamp` set,
  cleanup ran, finalizer removed, `kubectl get` returned `NotFound`
  immediately after. Also independently confirmed the exact
  `[@key]`/`[@default]` annotation syntax the generator emits (including
  the parenthesization gotcha from bug 1) against real JSON in an
  isolated, non-generator throwaway before trusting it in the generator's
  own output, and confirmed clean Ctrl-C shutdown of the generated-module
  demo (~1s, two connections, same as `webapp_demo.ml`).
- **`Client.clone` / single-client demos**: after collapsing every demo
  down to one `Client.t`, all of the above was re-run end-to-end against a
  fresh cluster to confirm `Client.clone` genuinely eliminates the
  connection-sharing footgun rather than just hiding it. `manager_demo`
  (the demo that originally *proved* the cross-controller starvation bug)
  synced and reconciled both controllers' pre-existing objects fully and
  concurrently from one shared client. `webapp_demo`/`webapp_gen_demo`
  each completed the full finalizer-add → status-PUT → delete →
  finalizer-remove → gone cycle with one client. `leader_demo` (the
  highest-priority re-test, being the scenario the fix's motivating "wart"
  writeup named directly) ran two candidates against a real Lease with one
  client each: `renewTime` advanced normally for the whole time
  candidate-a held leadership, proving its own renewals weren't starved
  behind its controller's watch; `kill -9`ing it produced a clean
  single-transition (`leaseTransitions=1`) handover to candidate-b, not
  the old double-leader failure. Every demo (`reflector_demo`,
  `controller_demo`, `manager_demo`, `webapp_demo`, `webapp_gen_demo`,
  `leader_demo`) also re-confirmed clean SIGINT shutdown (exit code 0)
  under the single-client design, and `bin/main.ml` (unaffected by this
  refactor, since it never used `Reflector`/`Controller`) was sanity
  checked to still LIST+WATCH correctly.
