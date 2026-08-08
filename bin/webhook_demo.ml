(* Demonstrates Admission: a mutating webhook that adds a default
   "managed-by" label if missing, and a validating webhook that rejects
   App objects with spec.replicas > 10 -- against the same App CRD
   bin/owned_child_demo.ml uses (examples/app-crd.yaml). One handler
   function per concern, each served on its own port (Admission.serve
   takes a single path/port; two separate WebhookConfigurations pointing
   at two ports is simpler than adding path-based routing to the library
   for a distinction Kubernetes itself doesn't put in the request payload
   -- nothing in an AdmissionReview says whether a mutating or validating
   config triggered it).

   Unlike every other demo here, this one genuinely cannot be tested
   against plain `kubectl proxy`: the API server itself must be able to
   open a real HTTPS connection *to* this process, which means it needs
   a certificate the API server will trust and a network path from
   inside the cluster back to wherever this runs. See "Admission
   webhooks" in the README for the full setup (self-signed cert via
   openssl, WebhookConfiguration YAML, and why `host.docker.internal` is
   what makes this reachable from a `kind` cluster on Docker Desktop). *)

open Eio
open K8s

let mutating_port = 8443
let validating_port = 8444

let mutate (req : Admission.Request.t) : Admission.decision =
  match req.object_ with
  | None -> Admission.Allow
  | Some obj ->
    let open Yojson.Safe.Util in
    let labels = obj |> member "metadata" |> member "labels" in
    let already_labeled =
      match labels with
      | `Assoc kvs -> List.mem_assoc "managed-by" kvs
      | _ -> false
    in
    if already_labeled
    then Admission.Allow
    else (
      let add_op =
        match labels with
        | `Assoc _ ->
          `Assoc
            [ "op", `String "add"; "path", `String "/metadata/labels/managed-by"; "value", `String "k8s-operator" ]
        | _ ->
          `Assoc
            [ "op", `String "add"
            ; "path", `String "/metadata/labels"
            ; "value", `Assoc [ "managed-by", `String "k8s-operator" ]
            ]
      in
      Admission.Allow_with_patch (`List [ add_op ]))

let max_replicas = 10

let validate (req : Admission.Request.t) : Admission.decision =
  match req.object_ with
  | None -> Admission.Allow
  | Some obj -> (
    match Yojson.Safe.Util.(obj |> member "spec" |> member "replicas" |> to_int_option) with
    | Some replicas when replicas > max_replicas ->
      Admission.Deny (Printf.sprintf "spec.replicas=%d exceeds the max of %d" replicas max_replicas)
    | _ -> Admission.Allow)

let () =
  let cert_path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "webhook-cert.pem" in
  let key_path = if Array.length Sys.argv > 2 then Sys.argv.(2) else "webhook-key.pem" in
  Eio_main.run
  @@ fun env ->
  try
    Switch.run
    @@ fun sw ->
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
           traceln "received SIGINT, shutting down...";
           Switch.fail sw Exit));
    let cert = Piaf.Cert.Filepath cert_path in
    let private_key = Piaf.Cert.Filepath key_path in
    Admission.serve ~sw env ~port:mutating_port ~cert ~private_key ~path:"/mutate" mutate;
    traceln "-- mutating webhook on https://0.0.0.0:%d/mutate --" mutating_port;
    Admission.serve ~sw env ~port:validating_port ~cert ~private_key ~path:"/validate" validate;
    traceln "-- validating webhook on https://0.0.0.0:%d/validate --" validating_port;
    Fiber.await_cancel ()
  with Exit -> traceln "stopped."
