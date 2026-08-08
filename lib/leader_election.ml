type config =
  { lease_name : string
  ; lease_namespace : string
  ; identity : string
  ; lease_duration : float
  ; retry_period : float
  }

let default_config ~lease_name ~lease_namespace ~identity ?(lease_duration = 15.0) ?(retry_period = 2.0) () =
  { lease_name; lease_namespace; identity; lease_duration; retry_period }

exception Leadership_lost

(* ---------------------------------------------------------------------- *)
(* Minimal, self-contained RFC3339 (UTC only) parse/format. Kubernetes'
   Lease timestamps are always UTC ("Z" suffix). [Unix.mktime] is
   deliberately avoided here: it interprets its input as *local* time, so
   using it against a UTC string would silently misbehave outside a
   UTC-configured environment. [Unix.gmtime] (UTC-only) is fine for
   formatting; the reverse direction needs its own civil-date-to-epoch
   conversion, so it gets one (Howard Hinnant's days_from_civil, integer
   arithmetic, correct across the whole Gregorian range). *)
(* ---------------------------------------------------------------------- *)

let days_from_civil ~year ~month ~day =
  let y = if month <= 2 then year - 1 else year in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (month + 9) mod 12 in
  let doy = ((153 * mp) + 2) / 5 + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let epoch_of_utc ~year ~month ~day ~hour ~min ~sec =
  let days = days_from_civil ~year ~month ~day in
  (float_of_int days *. 86400.0) +. float_of_int ((hour * 3600) + (min * 60) + sec)

let format_rfc3339 (epoch : float) =
  let tm = Unix.gmtime epoch in
  (* Kubernetes deserializes Lease.spec.acquireTime/renewTime as Go's
     metav1.MicroTime, whose JSON marshaller requires an exact 6-digit
     fractional-seconds field (RFC3339Micro: "...15:04:05.000000Z07:00")
     -- found the hard way: a plain "...05Z" (valid RFC3339, but not what
     this specific field accepts) was rejected outright with a 400. *)
  let micros = int_of_float (Float.rem epoch 1.0 *. 1_000_000.0) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour
    tm.tm_min tm.tm_sec micros

let parse_rfc3339 (s : string) : float option =
  match Scanf.sscanf_opt s "%d-%d-%dT%d:%d:%d" (fun year month day hour min sec -> year, month, day, hour, min, sec) with
  | None -> None
  | Some (year, month, day, hour, min, sec) -> Some (epoch_of_utc ~year ~month ~day ~hour ~min ~sec)

(* ---------------------------------------------------------------------- *)

let now_rfc3339 () = format_rfc3339 (Unix.gettimeofday ())

let is_expired (config : config) (lease : Lease.t) =
  match lease.spec.renew_time with
  | None -> true
  | Some rt ->
    (match parse_rfc3339 rt with
     | None -> true (* unparseable: treat as stale rather than get stuck forever *)
     | Some renew_epoch ->
       let duration =
         Option.value (Option.map float_of_int lease.spec.lease_duration_seconds) ~default:config.lease_duration
       in
       renew_epoch +. duration < Unix.gettimeofday ())

let claimed_spec (config : config) ~transitions =
  { Lease.holder_identity = Some config.identity
  ; lease_duration_seconds = Some (int_of_float config.lease_duration)
  ; acquire_time = Some (now_rfc3339 ())
  ; renew_time = Some (now_rfc3339 ())
  ; lease_transitions = Some transitions
  }

let empty_metadata (config : config) : Object_meta.t =
  { name = config.lease_name
  ; namespace = Some config.lease_namespace
  ; uid = None
  ; resource_version = None
  ; generation = None
  ; deletion_timestamp = None
  ; finalizers = []
  ; owner_references = []
  }

let try_acquire (ctx : Context.t) (config : config) =
  let client = Context.client ctx in
  match Client.get client ~resource:(module Lease) ~namespace:config.lease_namespace ~name:config.lease_name () with
  | Error e ->
    Context.log ctx "leader-election: GET lease failed: %s" (Client.Error.to_string e);
    false
  | Ok None ->
    let new_lease : Lease.t = { metadata = empty_metadata config; spec = claimed_spec config ~transitions:0 } in
    (match Client.create_object client ~resource:(module Lease) ~namespace:config.lease_namespace new_lease with
     | Ok _ -> true
     | Error e ->
       Context.log ctx "leader-election: create lease failed (likely lost a race to create it): %s"
         (Client.Error.to_string e);
       false)
  | Ok (Some lease) ->
    if lease.spec.holder_identity = Some config.identity
    then true
    else if is_expired config lease
    then (
      let transitions = 1 + Option.value lease.spec.lease_transitions ~default:0 in
      let updated = { lease with Lease.spec = claimed_spec config ~transitions } in
      match Client.update client ~resource:(module Lease) updated with
      | Ok () -> true
      | Error e ->
        Context.log ctx "leader-election: steal lease failed (likely lost a race to steal it): %s"
          (Client.Error.to_string e);
        false)
    else false

let try_renew (ctx : Context.t) (config : config) =
  let client = Context.client ctx in
  match Client.get client ~resource:(module Lease) ~namespace:config.lease_namespace ~name:config.lease_name () with
  | Error e ->
    Context.log ctx "leader-election: renew GET failed: %s" (Client.Error.to_string e);
    false
  | Ok None ->
    Context.log ctx "leader-election: lease disappeared while we held it";
    false
  | Ok (Some lease) ->
    if lease.spec.holder_identity <> Some config.identity
    then (
      Context.log ctx "leader-election: lease is now held by %s, not us"
        (Option.value lease.spec.holder_identity ~default:"<nobody>");
      false)
    else (
      let updated = { lease with Lease.spec = { lease.spec with renew_time = Some (now_rfc3339 ()) } } in
      match Client.update client ~resource:(module Lease) updated with
      | Ok () -> true
      | Error e ->
        Context.log ctx "leader-election: renew PUT failed: %s" (Client.Error.to_string e);
        false)

let run ~sw ~(ctx : Context.t) (config : config) ~on_acquired =
  let rec acquire_loop () =
    if try_acquire ctx config
    then (
      Context.log ctx "leader-election: acquired lease %s/%s as %s" config.lease_namespace config.lease_name
        config.identity;
      on_acquired ();
      renew_loop (Unix.gettimeofday ()))
    else (
      Context.sleep ctx config.retry_period;
      acquire_loop ())
  and renew_loop last_success =
    Context.sleep ctx config.retry_period;
    if try_renew ctx config
    then renew_loop (Unix.gettimeofday ())
    else (
      let elapsed = Unix.gettimeofday () -. last_success in
      if elapsed >= config.lease_duration
      then (
        Context.log ctx "leader-election: failed to renew for %.1fs (>= lease_duration=%.1fs), giving up leadership"
          elapsed config.lease_duration;
        Eio.Switch.fail sw Leadership_lost)
      else renew_loop last_success)
  in
  acquire_loop ()
