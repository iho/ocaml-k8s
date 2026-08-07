# k8s_watch

Minimal OCaml 5 + Eio Kubernetes client: LISTs Pods, then WATCHes them from
the returned `resourceVersion`, printing every `ADDED`/`MODIFIED`/`DELETED`
event. Direct-style throughout (no Lwt/Async, no monadic binds) using
[Piaf](https://github.com/anmonteiro/piaf) for HTTP/1.1 + HTTP/2 + TLS.

`bin/main.ml` is now a thin CLI wrapper around the `k8s` library in `lib/`,
which is the start of a higher-level operator framework (Informer/Reflector,
Workqueue, Controller, Manager — see "Library layout & roadmap" below).
`lib/client.ml` implements LIST+WATCH generically for any `Resource.S`, not
just Pods.

## Prerequisites

- OCaml >= 5.1, dune >= 3.0
- opam packages: `eio`, `eio_main`, `piaf`, `uri`, `yojson`

```sh
opam install eio_main piaf uri yojson
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
| `Gvk`, `Resource`, `Request`, `Watch_event` | done |
| `Client` | done — LIST/WATCH generalised over any `Resource.S`, used by `bin/main.ml` |
| `Context`, `Cache`, `Reconciler` | done |
| `Reflector` | done — List-then-Watch-forever, full resync-as-sync-events on every (re)LIST (incl. on 410/dropped connection) with capped exponential backoff; see `bin/reflector_demo.ml` |
| `Workqueue` | done — `Eio.Mutex`/`Eio.Condition`-backed dedup queue + per-item exponential backoff; see `test/test_workqueue.ml` |
| `Controller` | done — wires Reflector + Cache + Workqueue + a `Reconciler.t`, N worker fibers; see `bin/controller_demo.ml` |
| `Manager` | stub — multi-controller aggregation + graceful shutdown, not implemented |

`bin/main.ml` doesn't use `Reflector`/`Controller`/`Manager` yet — it calls
`Client.list`/`Client.watch` directly, same shape as the original hardcoded
version, just parameterised by `Resource.Unstructured` for Pods instead of
hand-written paths/JSON decoding. Two separate, minimal demo tools exercise
the higher layers directly against a real cluster:

```sh
kubectl proxy --port=8001 &
dune exec bin/reflector_demo.exe -- kube-system   # Reflector + Cache only
dune exec bin/controller_demo.exe -- kube-system  # full Reflector->Workqueue->Reconciler loop
```

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
