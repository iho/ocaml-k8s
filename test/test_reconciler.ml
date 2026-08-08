(* Demonstrates that a reconciler is a pure-enough function --
   Context.t -> Request.t -> R.t option -> result -- to unit-test
   directly, no cluster/kubectl proxy required. This is exactly the shape
   of the "TODO: your real reconcile logic goes here" spot in every
   gen/scaffold_operator.ml output and in bin/webapp_demo.ml/
   bin/webapp_gen_demo.ml.

   Context.t still needs a real Client.t -- an abstract type, nothing
   builds one without actually connecting -- and Client.create/of_env
   connects eagerly (confirmed by hand while re-verifying the Client.clone
   fix: pointing one at a refused port fails immediately, not lazily on
   first request). So this starts a bare TCP listener, outside Eio
   entirely, that just accepts and drops connections, purely so that
   initial connect succeeds. None of the reconcile branches exercised
   below ever call Context.client, so that stub listener never receives
   an actual HTTP request -- branches that DO talk to the API server
   (Finalizer.add/remove, Client.update_status, Client.create_object,
   ...) are exactly the parts covered by the E2E demos in bin/ against a
   real cluster instead, not here: this test's job is the pure decision
   logic, not the I/O. [connections_accepted] below makes that an
   assertion, not just an unchecked claim -- it counts every connection
   the stub listener actually receives, and the test fails if that count
   moves at all while the four reconcile cases run. *)

open Eio

(* A minimal typed resource, the same spec/status shape
   gen/scaffold_operator.ml generates for a fresh CRD (see its
   typed_main_ml template) -- of_json/to_json aren't needed here, only
   the fields the reconciler under test actually reads. *)
module Widget = struct
  type spec = { replicas : int }
  type status = { ready_replicas : int }

  type t =
    { metadata : K8s.Object_meta.t
    ; spec : spec
    ; status : status option
    }
end

(* Copied verbatim from gen/scaffold_operator.ml's typed_main_ml template
   -- the exact function a scaffolded project's reconciler starts as,
   before any TODO is filled in. *)
let reconcile (ctx : K8s.Context.t) (req : K8s.Request.t) : Widget.t option -> _ = function
  | None ->
    K8s.Context.log ctx "WIDGET  %s: gone" (K8s.Request.to_string req);
    Ok (K8s.Reconcile_result.done_ ())
  | Some (w : Widget.t) ->
    let desired = w.spec.replicas in
    let already_correct =
      match w.status with
      | Some s -> s.ready_replicas = desired
      | None -> false
    in
    if already_correct
    then (
      K8s.Context.log ctx "WIDGET  %s: already ready_replicas=%d, nothing to do" (K8s.Request.to_string req) desired;
      Ok (K8s.Reconcile_result.done_ ()))
    else (
      let status : Widget.status = { ready_replicas = desired } in
      K8s.Context.log ctx "WIDGET  %s: setting status.readyReplicas=%d" (K8s.Request.to_string req) desired;
      Ok (K8s.Reconcile_result.done_ ~status ()))

let check msg cond = if not cond then failwith ("FAILED: " ^ msg)

let make_widget ?status ~replicas name : Widget.t =
  { metadata =
      { name
      ; namespace = Some "default"
      ; uid = Some "test-uid"
      ; resource_version = Some "1"
      ; generation = Some 1
      ; deletion_timestamp = None
      ; finalizers = []
      ; owner_references = []
      }
  ; spec = { replicas }
  ; status
  }

(* Blocking, outside Eio's scheduler entirely -- deliberately not an
   Eio.Net listener, to avoid needing this test to reason about Eio's own
   socket API at all for what's just a "let TCP connect succeed" stub. *)
let connections_accepted = Atomic.make 0

let start_stub_listener () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 8;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let (_ : Thread.t) =
    Thread.create
      (fun () ->
        let rec loop () =
          match Unix.accept sock with
          | fd, _ ->
            Atomic.incr connections_accepted;
            Unix.close fd;
            loop ()
          | exception _ -> ()
        in
        loop ())
      ()
  in
  port

let req name : K8s.Request.t = { namespace = Some "default"; name }

let () =
  Eio_main.run
  @@ fun env ->
  Switch.run
  @@ fun sw ->
  let port = start_stub_listener () in
  match K8s.Client.create ~sw env ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port) () with
  | Error e -> failwith ("stub Client.create failed: " ^ K8s.Client.Error.to_string e)
  | Ok client ->
    let ctx = K8s.Context.create ~sw ~client ~clock:env#clock () in
    (* Give the accept loop (a separate system thread) a beat to catch up
       with whatever connection(s) Client.create's own eager connect just
       opened, so the baseline below isn't racing it. *)
    Eio.Time.sleep env#clock 0.05;
    let connections_before_reconciling = Atomic.get connections_accepted in
    (match reconcile ctx (req "gone-widget") None with
     | Ok result ->
       check "None -> Done" (result.action = K8s.Reconcile_result.Done);
       check "None -> no status write" (result.status = None)
     | Error _ -> failwith "FAILED: reconciling None should never error");
    (match reconcile ctx (req "w1") (Some (make_widget "w1" ~replicas:3 ~status:{ ready_replicas = 3 })) with
     | Ok result ->
       check "already-correct -> Done" (result.action = K8s.Reconcile_result.Done);
       check "already-correct -> no status write" (result.status = None)
     | Error _ -> failwith "FAILED: reconciling an already-correct widget should never error");
    (match reconcile ctx (req "w2") (Some (make_widget "w2" ~replicas:5 ?status:None)) with
     | Ok result ->
       check "needs-update -> Done" (result.action = K8s.Reconcile_result.Done);
       check "needs-update -> status set to spec.replicas" (result.status = Some { Widget.ready_replicas = 5 })
     | Error _ -> failwith "FAILED: reconciling a needs-update widget should never error");
    (match reconcile ctx (req "w3") (Some (make_widget "w3" ~replicas:2 ~status:{ ready_replicas = 7 })) with
     | Ok result ->
       check "stale-status -> Done" (result.action = K8s.Reconcile_result.Done);
       check "stale-status -> status corrected to spec.replicas"
         (result.status = Some { Widget.ready_replicas = 2 })
     | Error _ -> failwith "FAILED: reconciling a stale-status widget should never error");
    traceln "OK  pure reconciler logic (None, already-correct, needs-update, stale-status)";
    Eio.Time.sleep env#clock 0.05;
    check "no reconcile branch above opened a new connection to the stub listener"
      (Atomic.get connections_accepted = connections_before_reconciling);
    traceln "OK  none of the four reconcile calls performed any HTTP I/O";
    traceln "ALL RECONCILER TESTS PASSED"
