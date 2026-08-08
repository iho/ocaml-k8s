(* Scaffolds a brand-new, standalone operator project: its own
   dune-project/bin/deploy directory, not a subdirectory of this repo.
   Unlike gen_resource.ml (which turns one CRD YAML into one module to
   embed in an *existing* dune project), this generates every file a new
   project needs to build on its own -- a kubebuilder-init-style starting
   point, not a codegen step you'd re-run.

   Usage:
     scaffold_operator.exe <output-dir> <group> <version> <Kind> [plural] [cluster]

   <group> is the empty string or "core" for a built-in Kind (Pod,
   ConfigMap, ...) -- that emits a Resource.Unstructured-based reconciler
   with no CRD YAML, since there's no schema to hand-write. Any other
   group emits a typed spec/status record (one example field each,
   clearly marked TODO) plus a matching CRD YAML and sample object,
   modeled on this repo's own bin/webapp_demo.ml.

   [plural] defaults to the Kind lowercased with an "s" appended.
   Pass any non-empty 6th argument to mark the Kind cluster-scoped
   (namespaced defaults to true otherwise). *)

let k8s_repo_url = "git@github.com:iho/ocaml-k8s.git"

let mkdir_p dir =
  let rec go dir =
    if dir <> "." && dir <> "/" && not (Sys.file_exists dir)
    then (
      go (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  go dir

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)

let lower = String.lowercase_ascii

(* ------------------------------------------------------------------ *)
(* templates                                                          *)
(* ------------------------------------------------------------------ *)

let dune_project_file = "(lang dune 3.0)\n"

let bin_dune_file = "(executable\n (name main)\n (libraries eio eio_main piaf uri yojson k8s))\n"

let opam_file ~project_name =
  Printf.sprintf
    "opam-version: \"2.0\"\n\
     synopsis: \"%s Kubernetes operator, scaffolded from k8s\"\n\
     depends: [\n\
    \  \"ocaml\" {>= \"5.1\"}\n\
    \  \"dune\" {>= \"3.0\"}\n\
    \  \"eio\"\n\
    \  \"eio_main\"\n\
    \  \"piaf\"\n\
    \  \"uri\"\n\
    \  \"yojson\"\n\
    \  \"k8s\"\n\
     ]\n\
     build: [ [\"dune\" \"build\" \"-p\" name \"-j\" jobs] ]\n"
    project_name

let readme_file ~project_name ~kind ~plural ~is_core ~kind_lower =
  let crd_lines =
    if is_core
    then ""
    else
      Printf.sprintf
        "kubectl apply -f deploy/%s-crd.yaml\n\
         kubectl apply -f deploy/%s-sample.yaml\n"
        kind_lower kind_lower
  in
  let todo_spots =
    if is_core
    then Printf.sprintf "`%s_reconciler.reconcile`" kind
    else Printf.sprintf "%s's `spec`/`status` shape (kept in sync with deploy/*.yaml) and `%s_reconciler.reconcile`" kind kind
  in
  Printf.sprintf
    "# %s\n\n\
     A Kubernetes operator scaffolded by `gen/scaffold_operator.ml` from\n\
     [k8s](%s), an OCaml 5 + Eio + Piaf operator framework. Reconciles\n\
     `%s` (plural: `%s`).\n\n\
     ## First-time setup\n\n\
     This project depends on the `k8s` library, which isn't published on\n\
     the public opam repository -- pin it from source first:\n\n\
     ```sh\n\
     opam pin add k8s %s\n\
     # or, for local development against a checked-out copy:\n\
     # opam pin add k8s /path/to/ocaml-k8s\n\
     ```\n\n\
     Then build as usual:\n\n\
     ```sh\n\
     dune build\n\
     ```\n\n\
     ## Run\n\n\
     ```sh\n\
     kubectl proxy --port=8001 &\n\
     %s\
     dune exec bin/main.exe -- default   # namespace, or omit for all namespaces\n\
     ```\n\n\
     `bin/main.ml` is a starting point, not generated/regenerated code --\n\
     edit it freely. Search for `TODO` for the spots most likely to need\n\
     real logic: %s.\n"
    project_name k8s_repo_url kind plural k8s_repo_url crd_lines todo_spots

let crd_yaml ~group ~version ~kind ~plural ~kind_lower ~namespaced =
  Printf.sprintf
    "apiVersion: apiextensions.k8s.io/v1\n\
     kind: CustomResourceDefinition\n\
     metadata:\n\
     \  name: %s.%s\n\
     spec:\n\
     \  group: %s\n\
     \  scope: %s\n\
     \  names:\n\
     \    kind: %s\n\
     \    plural: %s\n\
     \    singular: %s\n\
     \  versions:\n\
     \    - name: %s\n\
     \      served: true\n\
     \      storage: true\n\
     \      subresources:\n\
     \        status: {}\n\
     \      schema:\n\
     \        openAPIV3Schema:\n\
     \          type: object\n\
     \          properties:\n\
     \            spec:\n\
     \              type: object\n\
     \              required: [replicas]\n\
     \              properties:\n\
     \                # TODO: replace with your real spec fields -- keep\n\
     \                # bin/main.ml's Widget.spec and this in sync by hand,\n\
     \                # or run gen/gen_resource.ml (from the k8s repo) against\n\
     \                # this file instead of hand-maintaining bin/main.ml.\n\
     \                replicas:\n\
     \                  type: integer\n\
     \            status:\n\
     \              type: object\n\
     \              properties:\n\
     \                readyReplicas:\n\
     \                  type: integer\n"
    plural group group (if namespaced then "Namespaced" else "Cluster") kind plural kind_lower version

let sample_yaml ~group ~version ~kind ~kind_lower =
  Printf.sprintf
    "apiVersion: %s/%s\n\
     kind: %s\n\
     metadata:\n\
     \  name: my-%s\n\
     spec:\n\
     \  replicas: 3\n"
    group version kind kind_lower

let typed_main_ml ~group ~version ~kind ~plural ~namespaced =
  let module_name = kind in
  let reconciler_name = module_name ^ "_reconciler" in
  let controller_name = module_name ^ "_controller" in
  let log_tag = String.uppercase_ascii kind in
  Printf.sprintf
    "(* Generated by gen/scaffold_operator.ml -- a starting point, not a\n\
    \   generated-and-regenerated file. Edit this freely: real spec/status\n\
    \   fields, real reconcile logic, finalizers, leader election, etc. See\n\
    \   the k8s library's own README for the full\n\
    \   Resource/Reconciler/Controller/Manager API and worked examples\n\
    \   (bin/webapp_demo.ml is the closest match to this file's shape). *)\n\n\
     open Eio\n\
     open K8s\n\n\
     (* TODO: replace with your CRD's real spec/status shape -- matches\n\
    \   deploy/%s-crd.yaml and deploy/%s-sample.yaml; keep all three in sync\n\
    \   as you edit, or generate this module instead with\n\
    \   `gen_resource.exe deploy/%s-crd.yaml` (see the k8s repo's README). *)\n\
     module %s = struct\n\
    \  type spec = { replicas : int }\n\n\
    \  type status = { ready_replicas : int }\n\n\
    \  type t =\n\
    \    { metadata : Object_meta.t\n\
    \    ; spec : spec\n\
    \    ; status : status option\n\
    \    }\n\n\
    \  let gvk = Gvk.{ group = %S; version = %S; kind = %S }\n\
    \  let plural = %S\n\
    \  let namespaced = %B\n\n\
    \  let of_json j =\n\
    \    let open Yojson.Safe.Util in\n\
    \    match\n\
    \      let metadata = Object_meta.of_json (member \"metadata\" j) in\n\
    \      let spec_json = member \"spec\" j in\n\
    \      let spec = { replicas = spec_json |> member \"replicas\" |> to_int } in\n\
    \      let status =\n\
    \        match member \"status\" j with\n\
    \        | `Null -> None\n\
    \        | s -> Some { ready_replicas = s |> member \"readyReplicas\" |> to_int }\n\
    \      in\n\
    \      { metadata; spec; status }\n\
    \    with\n\
    \    | t -> Ok t\n\
    \    | exception exn -> Error (Printexc.to_string exn)\n\n\
    \  let status_to_json (s : status) = `Assoc [ \"readyReplicas\", `Int s.ready_replicas ]\n\n\
    \  let to_json t =\n\
    \    `Assoc\n\
    \      (List.filter_map Fun.id\n\
    \         [ Some (\"apiVersion\", `String (Gvk.api_version gvk))\n\
    \         ; Some (\"kind\", `String gvk.kind)\n\
    \         ; Some (\"metadata\", Object_meta.to_json t.metadata)\n\
    \         ; Some (\"spec\", `Assoc [ \"replicas\", `Int t.spec.replicas ])\n\
    \         ; Option.map (fun s -> \"status\", status_to_json s) t.status\n\
    \         ])\n\n\
    \  let status_of_json j =\n\
    \    let open Yojson.Safe.Util in\n\
    \    match { ready_replicas = j |> member \"readyReplicas\" |> to_int } with\n\
    \    | s -> Ok s\n\
    \    | exception exn -> Error (Printexc.to_string exn)\n\n\
    \  let status t = t.status\n\
    \  let with_status t s = { t with status = Some s }\n\
    \  let name t = t.metadata.name\n\
    \  let namespace t = t.metadata.namespace\n\
    \  let resource_version t = t.metadata.resource_version\n\
    \  let uid t = t.metadata.uid\n\
    \  let deletion_timestamp t = t.metadata.deletion_timestamp\n\
    \  let finalizers t = t.metadata.finalizers\n\
     end\n\n\
     module %s = struct\n\
    \  module R = %s\n\n\
    \  let reconcile (ctx : Context.t) (req : Request.t) : %s.t option -> _ = function\n\
    \    | None ->\n\
    \      Context.log ctx \"%s  %%s: gone\" (Request.to_string req);\n\
    \      Ok (Reconcile_result.done_ ())\n\
    \    | Some obj ->\n\
    \      (* TODO: your real reconcile logic goes here. This example just\n\
    \         mirrors spec.replicas into status.readyReplicas, only PUTting\n\
    \         when it actually needs to change (its own PUT re-triggers a\n\
    \         reconcile via the watch -- writing the same status every time\n\
    \         would self-trigger forever instead of converging). *)\n\
    \      let desired = obj.spec.replicas in\n\
    \      let already_correct =\n\
    \        match obj.status with\n\
    \        | Some s -> s.ready_replicas = desired\n\
    \        | None -> false\n\
    \      in\n\
    \      if already_correct\n\
    \      then (\n\
    \        Context.log ctx \"%s  %%s: already ready_replicas=%%d, nothing to do\" (Request.to_string req)\n\
    \          desired;\n\
    \        Ok (Reconcile_result.done_ ()))\n\
    \      else (\n\
    \        let status : %s.status = { ready_replicas = desired } in\n\
    \        Context.log ctx \"%s  %%s: setting status.readyReplicas=%%d\" (Request.to_string req) desired;\n\
    \        Ok (Reconcile_result.done_ ~status ()))\n\
     end\n\n\
     module %s = Controller.Make (%s)\n\n\
     let () =\n\
    \  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in\n\
    \  Eio_main.run\n\
    \  @@ fun env ->\n\
    \  try\n\
    \    Switch.run\n\
    \    @@ fun sw ->\n\
    \    Sys.set_signal Sys.sigint\n\
    \      (Sys.Signal_handle\n\
    \         (fun _ ->\n\
    \           traceln \"received SIGINT, shutting down...\";\n\
    \           Switch.fail sw Exit));\n\
    \    match Client.of_env ~sw env with\n\
    \    | Error e -> traceln \"failed to connect: %%s\" (Client.Error.to_string e)\n\
    \    | Ok client ->\n\
    \      let ctx = Context.create ~sw ~env ~client () in\n\
    \      let controller = %s.create ~ctx ?namespace () in\n\
    \      traceln \"-- %s controller starting --\";\n\
    \      Controller.run ~sw controller\n\
    \  with Exit -> traceln \"stopped.\"\n"
    (lower kind) (lower kind) (lower kind) module_name group version kind plural namespaced reconciler_name
    module_name module_name log_tag log_tag module_name log_tag controller_name reconciler_name controller_name
    (lower kind)

let unstructured_main_ml ~version ~kind ~plural ~namespaced =
  let module_name = kind ^ "s" in
  let reconciler_name = kind ^ "_reconciler" in
  let controller_name = kind ^ "_controller" in
  let log_tag = String.uppercase_ascii kind in
  Printf.sprintf
    "(* Generated by gen/scaffold_operator.ml -- a starting point, not a\n\
    \   generated-and-regenerated file. %s is a built-in Kind, so this uses\n\
    \   Resource.Unstructured (raw JSON, no hand-written spec/status record)\n\
    \   rather than a typed CRD binding -- see the k8s library's own README\n\
    \   if you'd rather write a typed record for a built-in Kind's known\n\
    \   fields (bin/controller_demo.ml is the closest match to this file's\n\
    \   shape). *)\n\n\
     open Eio\n\
     open K8s\n\n\
     module %s = Resource.Unstructured (struct\n\
    \  let gvk = Gvk.core ~version:%S ~kind:%S\n\
    \  let plural = %S\n\
    \  let namespaced = %B\n\
     end)\n\n\
     module %s = struct\n\
    \  module R = %s\n\n\
    \  let reconcile (ctx : Context.t) (req : Request.t) (obj : %s.t option) =\n\
    \    (match obj with\n\
    \     | None -> Context.log ctx \"%s  %%s: gone\" (Request.to_string req)\n\
    \     | Some _ -> Context.log ctx \"%s  %%s: reconciled\" (Request.to_string req));\n\
    \    (* TODO: your real reconcile logic goes here. *)\n\
    \    Ok (Reconcile_result.done_ ())\n\
     end\n\n\
     module %s = Controller.Make (%s)\n\n\
     let () =\n\
    \  let namespace = if Array.length Sys.argv > 1 then Some Sys.argv.(1) else None in\n\
    \  Eio_main.run\n\
    \  @@ fun env ->\n\
    \  try\n\
    \    Switch.run\n\
    \    @@ fun sw ->\n\
    \    Sys.set_signal Sys.sigint\n\
    \      (Sys.Signal_handle\n\
    \         (fun _ ->\n\
    \           traceln \"received SIGINT, shutting down...\";\n\
    \           Switch.fail sw Exit));\n\
    \    match Client.of_env ~sw env with\n\
    \    | Error e -> traceln \"failed to connect: %%s\" (Client.Error.to_string e)\n\
    \    | Ok client ->\n\
    \      let ctx = Context.create ~sw ~env ~client () in\n\
    \      let controller = %s.create ~ctx ?namespace () in\n\
    \      traceln \"-- %s controller starting --\";\n\
    \      Controller.run ~sw controller\n\
    \  with Exit -> traceln \"stopped.\"\n"
    kind module_name version kind plural namespaced reconciler_name module_name module_name log_tag log_tag
    controller_name reconciler_name controller_name (lower kind)

(* ------------------------------------------------------------------ *)
(* driver                                                             *)
(* ------------------------------------------------------------------ *)

let () =
  match Sys.argv with
  | [| _; output_dir; group; version; kind |] | [| _; output_dir; group; version; kind; _ |] | [| _; output_dir; group; version; kind; _; _ |]
    ->
    if Sys.file_exists output_dir
    then (
      Printf.eprintf "refusing to scaffold into %s: already exists\n" output_dir;
      exit 1);
    let plural =
      if Array.length Sys.argv >= 6 && String.length Sys.argv.(5) > 0 then Sys.argv.(5) else lower kind ^ "s"
    in
    let namespaced = not (Array.length Sys.argv >= 7 && String.length Sys.argv.(6) > 0) in
    let is_core = group = "" || lower group = "core" in
    let group = if is_core then "" else group in
    let kind_lower = lower kind in
    let project_name = Filename.basename (if output_dir = "." then Sys.getcwd () else output_dir) in
    write_file (Filename.concat output_dir "dune-project") dune_project_file;
    write_file (Filename.concat output_dir "bin/dune") bin_dune_file;
    write_file (Filename.concat output_dir (project_name ^ ".opam")) (opam_file ~project_name);
    write_file
      (Filename.concat output_dir "README.md")
      (readme_file ~project_name ~kind ~plural ~is_core ~kind_lower);
    if is_core
    then
      write_file (Filename.concat output_dir "bin/main.ml") (unstructured_main_ml ~version ~kind ~plural ~namespaced)
    else (
      write_file
        (Filename.concat output_dir "bin/main.ml")
        (typed_main_ml ~group ~version ~kind ~plural ~namespaced);
      write_file
        (Filename.concat output_dir (Printf.sprintf "deploy/%s-crd.yaml" kind_lower))
        (crd_yaml ~group ~version ~kind ~plural ~kind_lower ~namespaced);
      write_file
        (Filename.concat output_dir (Printf.sprintf "deploy/%s-sample.yaml" kind_lower))
        (sample_yaml ~group ~version ~kind ~kind_lower));
    Printf.printf "scaffolded %s operator into %s/\n" kind output_dir;
    Printf.printf "next: cd %s && opam pin add k8s %s && dune build\n" output_dir k8s_repo_url
  | _ ->
    prerr_endline
      "usage: scaffold_operator.exe <output-dir> <group> <version> <Kind> [plural] [cluster-scoped]";
    prerr_endline "  <group> \"\" or \"core\" for a built-in Kind (Pod, ConfigMap, ...)";
    prerr_endline "  example: scaffold_operator.exe ./my-operator example.com v1 Widget";
    prerr_endline "  example: scaffold_operator.exe ./pod-watcher core v1 Pod";
    exit 1
