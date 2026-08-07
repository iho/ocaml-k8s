module Make (R : Resource.S) = struct
  type t =
    { ctx : Context.t
    ; namespace : string option
    ; label_selector : string option
    ; field_selector : string option
    ; on_event : R.t Watch_event.t -> unit
    ; cache : R.t Cache.t
    }

  let create ~ctx ?namespace ?label_selector ?field_selector ~on_event () =
    { ctx; namespace; label_selector; field_selector; on_event; cache = Cache.create () }

  let cache t = t.cache

  let run ~sw:_ (_t : t) =
    failwith
      "TODO(Phase 2): LIST into cache, mark_synced, then WATCH-forever via Client.watch, \
       re-listing with backoff on Client.Error.Gone / stream errors"
end
