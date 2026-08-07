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
| `Reflector` | stub — signature final, `run` (List-then-Watch-forever with 410/backoff resync) not implemented |
| `Workqueue` | stub — rate-limited/deduplicating queue, not implemented |
| `Controller`, `Manager` | stub — wiring + graceful shutdown, not implemented |

`bin/main.ml` doesn't use `Reflector`/`Controller`/`Manager` yet — it calls
`Client.list`/`Client.watch` directly, same shape as the original hardcoded
version, just parameterised by `Resource.Unstructured` for Pods instead of
hand-written paths/JSON decoding.

## Notes / limitations

- On `410 Gone` (the watch's `resourceVersion` fell out of etcd's compaction
  window), `Client.watch` returns `Error (Gone ...)` and the program logs it
  and stops, rather than automatically re-LISTing and restarting the watch
  — that resync behavior belongs in `Reflector` (see roadmap above), not in
  `Client` itself.
- No automatic reconnect/retry on transient network errors.
- No informer-style local cache/indexer wired up yet in `bin/main.ml` — it
  only prints events. (`Cache` exists in the library but nothing populates
  it until `Reflector` is implemented.)

## Manual verification

This was tested end-to-end against a real cluster (`kind`) via
`kubectl proxy`: LIST correctly enumerated existing pods and printed the
list's `resourceVersion`, and WATCH correctly streamed `ADDED`, `MODIFIED`,
and `DELETED` events in real time while a test pod was created and deleted.
Ctrl-C during an active watch was confirmed to cleanly cancel the fiber,
close the connection, and exit with status 0.
