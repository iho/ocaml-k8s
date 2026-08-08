type spec =
  { holder_identity : string option
  ; lease_duration_seconds : int option
  ; acquire_time : string option
  ; renew_time : string option
  ; lease_transitions : int option
  }

type t =
  { metadata : Object_meta.t
  ; spec : spec
  }

let gvk = Gvk.{ group = "coordination.k8s.io"; version = "v1"; kind = "Lease" }
let plural = "leases"
let namespaced = true

open Yojson.Safe.Util

let spec_of_json j =
  { holder_identity = j |> member "holderIdentity" |> to_string_option
  ; lease_duration_seconds = j |> member "leaseDurationSeconds" |> to_int_option
  ; acquire_time = j |> member "acquireTime" |> to_string_option
  ; renew_time = j |> member "renewTime" |> to_string_option
  ; lease_transitions = j |> member "leaseTransitions" |> to_int_option
  }

let spec_to_json (s : spec) =
  `Assoc
    (List.filter_map Fun.id
       [ Option.map (fun v -> "holderIdentity", `String v) s.holder_identity
       ; Option.map (fun v -> "leaseDurationSeconds", `Int v) s.lease_duration_seconds
       ; Option.map (fun v -> "acquireTime", `String v) s.acquire_time
       ; Option.map (fun v -> "renewTime", `String v) s.renew_time
       ; Option.map (fun v -> "leaseTransitions", `Int v) s.lease_transitions
       ])

let of_json j =
  match { metadata = Object_meta.of_json (member "metadata" j); spec = spec_of_json (member "spec" j) } with
  | t -> Ok t
  | exception exn -> Error (Printexc.to_string exn)

let to_json t =
  `Assoc
    [ "apiVersion", `String (Gvk.api_version gvk)
    ; "kind", `String gvk.kind
    ; "metadata", Object_meta.to_json t.metadata
    ; "spec", spec_to_json t.spec
    ]

type status = unit

let status_of_json _ = Ok ()
let status_to_json () = `Null
let status _ = None
let with_status t () = t
let name t = t.metadata.name
let namespace t = t.metadata.namespace
let resource_version t = t.metadata.resource_version
let uid t = t.metadata.uid
let deletion_timestamp t = t.metadata.deletion_timestamp
let finalizers t = t.metadata.finalizers
