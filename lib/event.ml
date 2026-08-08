(* A typed binding for the core/v1 Event object and a small "recorder" for
   emitting them — client-go's EventRecorder, i.e. surfacing operator
   activity where `kubectl describe` (and `kubectl get events`) shows it, in
   addition to the Prometheus metrics `Controller` already emits. An Event is
   a one-shot, time-stamped note attached to an involved object ("BackOff",
   "SuccessfulCreate", ...); Kubernetes keeps a bounded recent window of
   them per namespace, deduplicated on (source, involvedObject, type,
   reason, message). *)

module R = struct
  type involved_object =
    { kind : string
    ; name : string
    ; namespace : string option
    ; uid : string option
    ; api_version : string option
    }

  type t =
    { metadata : Object_meta.t
    ; involved_object : involved_object
    ; reason : string
    ; message : string
    ; type_ : string  (* "Normal" | "Warning" *)
    ; count : int
    ; first_timestamp : string option
    ; last_timestamp : string option
    }

  type status = unit

  let gvk = Gvk.core ~version:"v1" ~kind:"Event"
  let plural = "events"
  let namespaced = true

  let involved_of_json j =
    let open Yojson.Safe.Util in
    { kind = j |> member "kind" |> to_string_option |> Option.value ~default:""
    ; name = j |> member "name" |> to_string_option |> Option.value ~default:""
    ; namespace = j |> member "namespace" |> to_string_option
    ; uid = j |> member "uid" |> to_string_option
    ; api_version = j |> member "apiVersion" |> to_string_option
    }

  let involved_to_json (o : involved_object) =
    `Assoc
      (List.filter_map Fun.id
         [ Some ("kind", `String o.kind)
         ; Some ("name", `String o.name)
         ; Option.map (fun ns -> "namespace", `String ns) o.namespace
         ; Option.map (fun u -> "uid", `String u) o.uid
         ; Option.map (fun a -> "apiVersion", `String a) o.api_version
         ])

  let of_json j =
    let open Yojson.Safe.Util in
    try
      Ok
        { metadata = Object_meta.of_json (member "metadata" j)
        ; involved_object = involved_of_json (member "involvedObject" j)
        ; reason = j |> member "reason" |> to_string_option |> Option.value ~default:""
        ; message = j |> member "message" |> to_string_option |> Option.value ~default:""
        ; type_ = j |> member "type" |> to_string_option |> Option.value ~default:"Normal"
        ; count = j |> member "count" |> to_int_option |> Option.value ~default:1
        ; first_timestamp = j |> member "firstTimestamp" |> to_string_option
        ; last_timestamp = j |> member "lastTimestamp" |> to_string_option
        }
    with _ -> Error "bad event json"

  let to_json (e : t) =
    `Assoc
      (List.filter_map Fun.id
         [ Some ("apiVersion", `String (Gvk.api_version gvk))
         ; Some ("kind", `String gvk.kind)
         ; Some ("metadata", Object_meta.to_json e.metadata)
         ; Some ("involvedObject", involved_to_json e.involved_object)
         ; Some ("reason", `String e.reason)
         ; Some ("message", `String e.message)
         ; Some ("type", `String e.type_)
         ; Some ("count", `Int e.count)
         ; Option.map (fun ts -> "firstTimestamp", `String ts) e.first_timestamp
         ; Option.map (fun ts -> "lastTimestamp", `String ts) e.last_timestamp
         ])

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
end

(* A small EventRecorder: builds a fresh core/v1 Event naming [reason]/
   [message] on an involved object and POSTs it (fire-and-forget, so a
   failure to record — a permissions gap, a network blip — never blocks a
   reconcile; a [log] line is the only trace). [source] is the component
   name Kubernetes stores (e.g. the controller/operator name); [now] is a
   UTC RFC3339 timestamp used for both firstTimestamp and lastTimestamp. *)
module Recorder = struct
  type t =
    { client : Client.t
    ; source : string
    ; now : unit -> string
    ; log : string -> unit
    }

  (* The default [now]: the same UTC RFC3339 formatting the library already
     uses for Lease timestamps (a fractional-seconds-free form is fine here
     — metav1.Time, unlike MicroTime, accepts a plain "...Z"). *)
  let default_now () =
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min
      tm.tm_sec

  let create ~client ~source ?(now = default_now) ~log () = { client; source; now; log }

  let build_event t ~type_ ~involved:(involved : R.involved_object) ~reason ~message =
    let ts = t.now () in
    let name =
      Printf.sprintf "%s.%x" involved.name (Hashtbl.hash (t.source, involved.name, type_, reason, message))
    in
    { R.metadata =
        { name
        ; namespace = involved.namespace
        ; uid = None
        ; resource_version = None
        ; generation = None
        ; deletion_timestamp = None
        ; finalizers = []
        ; owner_references = []
        }
    ; involved_object = involved
    ; reason
    ; message
    ; type_
    ; count = 1
    ; first_timestamp = Some ts
    ; last_timestamp = Some ts
    }

  let emit t ~type_ ~involved ~reason ~message =
    let event = build_event t ~type_ ~involved ~reason ~message in
    (match Client.create_object t.client ~resource:(module R) event with
     | Ok _ -> ()
     | Error e ->
       (* Fire-and-forget: recording an Event is best-effort observability,
          never worth failing a reconcile over. *)
       t.log (Printf.sprintf "event recorder: failed to record %s/%s on %s/%s: %s" type_ reason involved.kind
                involved.name (Client.Error.to_string e)))

  let normal t ~involved ~reason ~message = emit t ~type_:"Normal" ~involved ~reason ~message
  let warning t ~involved ~reason ~message = emit t ~type_:"Warning" ~involved ~reason ~message
end
