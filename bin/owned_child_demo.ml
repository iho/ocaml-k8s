(* Demonstrates the pattern owner_reference.mli documents but nothing
   else in this repo actually does: a reconciler that creates a *child*
   object on behalf of its own CR and sets an OwnerReference on it, so
   Kubernetes' own garbage collector deletes the child when the parent is
   deleted -- no finalizer needed, unlike bin/webapp_demo.ml (whose
   cleanup is an external system Kubernetes' GC can't reach for it; this
   one's only "cleanup" is a child object GC already knows how to
   collect).

   `App` owns one child ConfigMap, `<name>-config`, holding its
   spec.image. Requires the CRD + a sample object:
     kubectl apply -f examples/app-crd.yaml
     kubectl apply -f examples/app-sample.yaml
     kubectl proxy --port=8001 &
     dune exec bin/owned_child_demo.exe -- default
   Then, in another shell, `kubectl get configmap hello-app-config -o
   yaml` to see the ownerReferences entry, and `kubectl delete app
   hello-app` to watch the child disappear on its own -- no finalizer,
   no watch-driven cleanup code, just Kubernetes doing what
   ownerReferences are for. *)

open Eio
open K8s

module App = struct
  type spec = { image : string }
  type status = unit

  type t =
    { metadata : Object_meta.t
    ; spec : spec
    }

  let gvk = Gvk.{ group = "example.com"; version = "v1"; kind = "App" }
  let plural = "apps"
  let namespaced = true

  let of_json j =
    let open Yojson.Safe.Util in
    match
      let metadata = Object_meta.of_json (member "metadata" j) in
      let spec = { image = j |> member "spec" |> member "image" |> to_string } in
      { metadata; spec }
    with
    | t -> Ok t
    | exception exn -> Error (Printexc.to_string exn)

  let to_json t =
    `Assoc
      [ "apiVersion", `String (Gvk.api_version gvk)
      ; "kind", `String gvk.kind
      ; "metadata", Object_meta.to_json t.metadata
      ; "spec", `Assoc [ "image", `String t.spec.image ]
      ]

  (* No status subresource on this Kind (see examples/app-crd.yaml) --
     same stub shape gen/gen_resource.ml emits for a status-less CRD. *)
  let status_of_json (_ : Yojson.Safe.t) = Ok ()
  let status_to_json () = `Null
  let status (_ : t) = None
  let with_status t (_ : status) = t
  let name t = t.metadata.name
  let namespace t = t.metadata.namespace
  let resource_version t = t.metadata.resource_version
  let uid t = t.metadata.uid
  let deletion_timestamp t = t.metadata.deletion_timestamp
  let finalizers t = t.metadata.finalizers
end

module Config_maps = Resource.Unstructured (struct
  let gvk = Gvk.core ~version:"v1" ~kind:"ConfigMap"
  let plural = "configmaps"
  let namespaced = true
end)

let child_name app = App.name app ^ "-config"

module App_reconciler = struct
  module R = App

  let reconcile (ctx : Context.t) (req : Request.t) : App.t option -> _ = function
    | None ->
      Context.log ctx "APP  %s: gone (owner-reference GC already removed its child ConfigMap)"
        (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some app when App.deletion_timestamp app <> None ->
      (* No finalizer branch here, deliberately: the child's
         ownerReference (set below when it was created) is what makes
         the API server's own garbage collector remove it once this
         object is actually deleted. Nothing for this reconciler to do. *)
      Context.log ctx "APP  %s: being deleted, owner-reference GC will remove its child ConfigMap"
        (Request.to_string req);
      Ok (Reconcile_result.done_ ())
    | Some app -> (
      let name = child_name app in
      let desired_data = [ "image", `String app.spec.image ] in
      match Client.get (Context.client ctx) ~resource:(module Config_maps) ?namespace:(App.namespace app) ~name () with
      | Error e -> Error (Reconcile_error.of_client_error e)
      | Ok None -> (
        match App.uid app with
        | None ->
          (* A just-created object the informer hasn't round-tripped
             through the API server yet has no uid: nothing to set as
             an owner. Wait a beat rather than fail -- the watch event
             that adds the uid will re-trigger a reconcile anyway, this
             just covers the (rare) race where this one runs first. *)
          Ok (Reconcile_result.requeue_after 1.0)
        | Some uid ->
          let owner : Owner_reference.t =
            { api_version = Gvk.api_version App.gvk
            ; kind = App.gvk.kind
            ; name = App.name app
            ; uid
            ; controller = Some true
            ; block_owner_deletion = Some true
            }
          in
          let child =
            `Assoc
              [ "apiVersion", `String "v1"
              ; "kind", `String "ConfigMap"
              ; "metadata",
                `Assoc [ "name", `String name; "ownerReferences", `List [ Owner_reference.to_json owner ] ]
              ; "data", `Assoc desired_data
              ]
          in
          (match
             Client.create_object (Context.client ctx) ~resource:(module Config_maps) ?namespace:(App.namespace app)
               child
           with
           | Ok _ ->
             Context.log ctx "APP  %s: created child ConfigMap %s, owned by this App" (Request.to_string req) name;
             Ok (Reconcile_result.done_ ())
           | Error e -> Error (Reconcile_error.of_client_error e)))
      | Ok (Some existing) ->
        let current_data =
          match existing with
          | `Assoc fields -> (
            match List.assoc_opt "data" fields with
            | Some (`Assoc d) -> d
            | _ -> [])
          | _ -> []
        in
        if current_data = desired_data
        then (
          Context.log ctx "APP  %s: child ConfigMap %s already up to date" (Request.to_string req) name;
          Ok (Reconcile_result.done_ ()))
        else (
          let updated =
            match existing with
            | `Assoc fields ->
              `Assoc (List.map (fun (k, v) -> if k = "data" then k, `Assoc desired_data else k, v) fields)
            | other -> other
          in
          (match Client.update (Context.client ctx) ~resource:(module Config_maps) updated with
           | Ok () ->
             Context.log ctx "APP  %s: updated child ConfigMap %s" (Request.to_string req) name;
             Ok (Reconcile_result.done_ ())
           | Error e -> Error (Reconcile_error.of_client_error e))))
end

module App_controller = Controller.Make (App_reconciler)

let () =
  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in
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
    match Client.of_env ~sw env with
    | Error e -> traceln "failed to connect: %s" (Client.Error.to_string e)
    | Ok client ->
      let ctx = Context.create ~sw ~client ~clock:env#clock () in
      let controller = App_controller.create ~ctx ~env ~clock:env#clock ?namespace () in
      traceln "-- owned-child-object controller starting --";
      Controller.run ~sw controller
  with Exit -> traceln "stopped."
