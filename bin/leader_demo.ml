(* Manual verification tool for [K8s.Leader_election] / [Manager.with_leader_election].
   Not part of the CLI proper. Run *two* instances against the same real
   cluster / `kubectl proxy`, with different identities, competing for the
   same Lease:
     dune exec bin/leader_demo.exe -- candidate-a kube-system
     dune exec bin/leader_demo.exe -- candidate-b kube-system
   Only one should ever print "acquired leadership" and start reconciling
   pods at a time; kill it (SIGKILL, so it can't release cleanly) and the
   other should take over once the lease goes stale (~lease_duration,
   shortened below for a fast-to-observe demo — production code should use
   {!Leader_election.default_config}'s real defaults instead).

   Also serves /healthz and /readyz -- port defaults to 8080, pass a 3rd
   argument to change it (needed to run two candidates on one host, since
   they can't share a port). /readyz's "leader-election" check should
   read false for the standby candidate and true for whichever is
   currently leading -- worth curling both while both are running. *)

open Eio
open K8s

module Pods = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"Pod"
  let plural = "pods"
  let namespaced = true
end)

module Pod_reconciler = struct
  module R = Pods

  let reconcile (ctx : Context.t) (req : Request.t) : Pods.t option -> _ = function
    | None ->
      Context.log ctx "POD  %s: gone" (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some _ ->
      Context.log ctx "POD  %s: reconciled (I am the leader)" (Request.to_string req);
      Ok (Reconcile_result.done_ ())
end

module Pod_controller = Controller.Make (Pod_reconciler)

let () =
  let identity =
    if Array.length Sys.argv > 1 then Sys.argv.(1) else Printf.sprintf "candidate-%d" (Unix.getpid ())
  in
  let namespace = if Array.length Sys.argv > 2 then Some Sys.argv.(2) else None in
  let health_port = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 8080 in
  let lease_namespace = Option.value namespace ~default:"default" in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    match Client.of_env ~sw env with
    | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok client ->
      let ctx = Context.create ~sw ~client ~clock:env#clock () in
      let controller = Pod_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      let config =
        Leader_election.default_config ~lease_name:"leader-demo" ~lease_namespace ~identity ~lease_duration:5.0
          ~retry_period:1.0 ()
      in
      let manager = Manager.create ~ctx () in
      let manager = Manager.with_leader_election manager config in
      Manager.add_controller manager controller;
      Manager.serve_health ~sw env manager ~port:health_port;
      traceln "-- candidate %s competing for lease %s/leader-demo (health on :%d) --" identity lease_namespace
        health_port;
      Manager.run ~sw manager
  with Exit -> traceln "stopped."
