(* Pure: no cluster, no TLS, no HTTP server -- just Admission.Request.of_json
   and Admission.response_json against realistic AdmissionReview fixture
   JSON (shaped like what a real API server actually sends -- see e.g.
   https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#request).
   Admission.serve itself (the real HTTPS endpoint) needs a real cert and
   is exercised by bin/webhook_demo.ml against a real cluster instead, not
   here. *)

module A = K8s.Admission

let check msg cond = if not cond then failwith ("FAILED: " ^ msg)

let create_review =
  {json|
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "705ab4f5-6393-11e8-b7cc-42010a800002",
    "kind": {"group": "example.com", "version": "v1", "kind": "App"},
    "resource": {"group": "example.com", "version": "v1", "resource": "apps"},
    "namespace": "default",
    "name": "hello-app",
    "operation": "CREATE",
    "object": {
      "apiVersion": "example.com/v1",
      "kind": "App",
      "metadata": {"name": "hello-app", "namespace": "default"},
      "spec": {"image": "nginx:latest", "replicas": 3}
    },
    "dryRun": false
  }
}
|json}

let delete_review =
  {json|
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "some-other-uid",
    "kind": {"group": "example.com", "version": "v1", "kind": "App"},
    "resource": {"group": "example.com", "version": "v1", "resource": "apps"},
    "namespace": "default",
    "name": "hello-app",
    "operation": "DELETE",
    "oldObject": {
      "apiVersion": "example.com/v1",
      "kind": "App",
      "metadata": {"name": "hello-app", "namespace": "default"},
      "spec": {"image": "nginx:latest", "replicas": 3}
    },
    "dryRun": false
  }
}
|json}

let () =
  let create_req = A.Request.of_json (Yojson.Safe.from_string create_review) in
  check "uid decoded" (create_req.uid = "705ab4f5-6393-11e8-b7cc-42010a800002");
  check "operation decoded as `Create" (create_req.operation = `Create);
  check "kind decoded" (create_req.kind = { K8s.Gvk.group = "example.com"; version = "v1"; kind = "App" });
  check "namespace decoded" (create_req.namespace = Some "default");
  check "name decoded" (create_req.name = "hello-app");
  check "object_ present on CREATE" (create_req.object_ <> None);
  check "old_object absent on CREATE" (create_req.old_object = None);
  check "dry_run decoded" (create_req.dry_run = false);
  (match Yojson.Safe.Util.(create_req.object_ |> Option.get |> member "spec" |> member "replicas" |> to_int) with
   | 3 -> ()
   | n -> failwith (Printf.sprintf "FAILED: expected spec.replicas=3 in decoded object_, got %d" n));

  let delete_req = A.Request.of_json (Yojson.Safe.from_string delete_review) in
  check "operation decoded as `Delete" (delete_req.operation = `Delete);
  check "object_ absent on DELETE" (delete_req.object_ = None);
  check "old_object present on DELETE" (delete_req.old_object <> None);

  print_endline "OK  Admission.Request.of_json (CREATE and DELETE fixtures)";

  (* response_json: Allow *)
  let allow_json = A.response_json ~api_version:"admission.k8s.io/v1" ~kind:"AdmissionReview" ~uid:"u1" A.Allow in
  let open Yojson.Safe.Util in
  check "Allow: apiVersion echoed" (allow_json |> member "apiVersion" |> to_string = "admission.k8s.io/v1");
  check "Allow: response.uid echoed" (allow_json |> member "response" |> member "uid" |> to_string = "u1");
  check "Allow: response.allowed = true" (allow_json |> member "response" |> member "allowed" |> to_bool = true);
  check "Allow: no status field" (allow_json |> member "response" |> member "status" = `Null);

  (* response_json: Deny *)
  let deny_json = A.response_json ~api_version:"admission.k8s.io/v1" ~kind:"AdmissionReview" ~uid:"u2" (A.Deny "nope") in
  check "Deny: response.allowed = false" (deny_json |> member "response" |> member "allowed" |> to_bool = false);
  check "Deny: response.status.message carries the reason"
    (deny_json |> member "response" |> member "status" |> member "message" |> to_string = "nope");

  (* response_json: Allow_with_patch -- patch must be base64-encoded JSON,
     round-tripping back to the exact patch document given. *)
  let patch = `List [ `Assoc [ "op", `String "add"; "path", `String "/metadata/labels/managed-by"; "value", `String "k8s-operator" ] ] in
  let mutate_json = A.response_json ~api_version:"admission.k8s.io/v1" ~kind:"AdmissionReview" ~uid:"u3" (A.Allow_with_patch patch) in
  check "Allow_with_patch: allowed = true" (mutate_json |> member "response" |> member "allowed" |> to_bool = true);
  check "Allow_with_patch: patchType = JSONPatch"
    (mutate_json |> member "response" |> member "patchType" |> to_string = "JSONPatch");
  let decoded_patch =
    mutate_json |> member "response" |> member "patch" |> to_string |> Base64.decode_exn |> Yojson.Safe.from_string
  in
  check "Allow_with_patch: patch round-trips through base64 unchanged" (decoded_patch = patch);

  print_endline "OK  Admission.response_json (Allow, Deny, Allow_with_patch)";
  print_endline "ALL ADMISSION TESTS PASSED"
