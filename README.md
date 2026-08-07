# k8s_watch

Minimal OCaml 5 + Eio Kubernetes client: LISTs Pods, then WATCHes them from
the returned `resourceVersion`, printing every `ADDED`/`MODIFIED`/`DELETED`
event. Direct-style throughout (no Lwt/Async, no monadic binds) using
[Piaf](https://github.com/anmonteiro/piaf) for HTTP/1.1 + HTTP/2 + TLS.

All the logic lives in `bin/main.ml`.

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

## Notes / limitations

This is intentionally minimal, not a full operator framework:

- On `410 Gone` (the watch's `resourceVersion` fell out of etcd's compaction
  window), the program logs it and stops rather than automatically
  re-LISTing and restarting the watch.
- No automatic reconnect/retry on transient network errors.
- No informer-style local cache/indexer — this only prints events.

## Manual verification

This was tested end-to-end against a real cluster (`kind`) via
`kubectl proxy`: LIST correctly enumerated existing pods and printed the
list's `resourceVersion`, and WATCH correctly streamed `ADDED`, `MODIFIED`,
and `DELETED` events in real time while a test pod was created and deleted.
Ctrl-C during an active watch was confirmed to cleanly cancel the fiber,
close the connection, and exit with status 0.
