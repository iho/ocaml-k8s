module Make (R : Resource.S) = struct
  type t =
    { ctx : Context.t
    ; client : Client.t
    ; namespace : string option
    ; label_selector : string option
    ; field_selector : string option
    ; on_event : R.t Watch_event.t -> unit
    ; cache : R.t Cache.t
    }

  let create ~ctx ~client ?namespace ?label_selector ?field_selector ~on_event () =
    { ctx; client; namespace; label_selector; field_selector; on_event; cache = Cache.create () }

  let cache t = t.cache

  let request_of item : Request.t = { namespace = R.namespace item; name = R.name item }

  let max_backoff = 30.0

  let run (t : t) =
    let backoff = ref 0.5 in
    let sleep_backoff () =
      Context.sleep t.ctx !backoff;
      backoff := Float.min max_backoff (!backoff *. 2.0)
    in
    let on_watch_event (ev : R.t Watch_event.t) =
      (match ev.kind with
       | Added | Modified -> Cache.Writer.set t.cache ev.request ev.object_
       | Deleted -> Cache.Writer.remove t.cache ev.request
       | Bookmark -> ());
      t.on_event ev
    in
    let rec list_and_watch () =
      match
        Client.list t.client ~resource:(module R) ?namespace:t.namespace
          ?label_selector:t.label_selector ?field_selector:t.field_selector ()
      with
      | Error e ->
        Context.log t.ctx "reflector[%s]: LIST failed: %s" (Gvk.to_string R.gvk)
          (Client.Error.to_string e);
        sleep_backoff ();
        list_and_watch ()
      | Ok (items, resource_version) ->
        backoff := 0.5;
        (* Every successful LIST (the first one, and any re-LIST after a
           reconnect) is a full resync, not just a cache refresh: it must
           also deliver synthetic events to [on_event] for every object —
           Added/Modified for everything in the fresh list (Modified for
           anything already known, since a relist can't tell "unchanged"
           from "changed while disconnected" apart, so both must be
           reconciled), and Deleted for anything that was cached before
           but is missing now. Without this, objects that exist before the
           reflector starts (or that changed while a watch was down) would
           never reach a Controller's reconciler. Mirrors client-go's
           reflector, which does the same full-resync-as-sync-events dance
           via its DeltaFIFO on every List/Relist. *)
        let previously_cached = Cache.list t.cache in
        let previously_known = Hashtbl.create (List.length previously_cached) in
        List.iter (fun old -> Hashtbl.replace previously_known (request_of old) ()) previously_cached;
        let currently_listed = Hashtbl.create (List.length items) in
        List.iter (fun item -> Hashtbl.replace currently_listed (request_of item) ()) items;
        Cache.Writer.replace_all t.cache (List.map (fun item -> request_of item, item) items);
        Context.log t.ctx "reflector[%s]: synced %d object(s), resourceVersion=%s"
          (Gvk.to_string R.gvk) (List.length items) resource_version;
        List.iter
          (fun item ->
            let request = request_of item in
            let kind = if Hashtbl.mem previously_known request then Watch_event.Modified else Added in
            t.on_event { Watch_event.kind; object_ = item; request })
          items;
        List.iter
          (fun old ->
            let request = request_of old in
            if not (Hashtbl.mem currently_listed request)
            then t.on_event { Watch_event.kind = Deleted; object_ = old; request })
          previously_cached;
        watch_from resource_version
    and watch_from resource_version =
      match
        Client.watch t.client ~resource:(module R) ?namespace:t.namespace
          ?label_selector:t.label_selector ?field_selector:t.field_selector ~resource_version
          ~on_event:on_watch_event ()
      with
      | Ok () ->
        Context.log t.ctx "reflector[%s]: watch stream closed, re-listing" (Gvk.to_string R.gvk);
        sleep_backoff ();
        list_and_watch ()
      | Error (Client.Error.Gone _ as e) ->
        (* Expected/routine: the resourceVersion aged out of etcd's
           compaction window. Re-list immediately at whatever the current
           backoff is (no need to escalate on an error class that's
           inherently self-correcting via a fresh LIST). *)
        Context.log t.ctx "reflector[%s]: %s, re-listing" (Gvk.to_string R.gvk)
          (Client.Error.to_string e);
        list_and_watch ()
      | Error e ->
        Context.log t.ctx "reflector[%s]: watch failed: %s" (Gvk.to_string R.gvk)
          (Client.Error.to_string e);
        sleep_backoff ();
        list_and_watch ()
    in
    list_and_watch ()
end
