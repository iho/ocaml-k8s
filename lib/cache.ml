type 'a t =
  { mutex : Eio.Mutex.t
  ; table : (Request.t, 'a) Hashtbl.t
  ; synced : unit Eio.Promise.t
  ; resolve_synced : unit Eio.Promise.u
  ; mutable is_synced : bool
  }

let create () =
  let synced, resolve_synced = Eio.Promise.create () in
  { mutex = Eio.Mutex.create ()
  ; table = Hashtbl.create 64
  ; synced
  ; resolve_synced
  ; is_synced = false
  }

let get t req = Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.find_opt t.table req)
let list t = Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.fold (fun _ v acc -> v :: acc) t.table [])
let wait_for_sync t = Eio.Promise.await t.synced
let is_synced t = t.is_synced

module Writer = struct
  let set t req v = Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> Hashtbl.replace t.table req v)
  let remove t req = Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> Hashtbl.remove t.table req)

  let mark_synced t =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
      if not t.is_synced
      then (
        t.is_synced <- true;
        Eio.Promise.resolve t.resolve_synced ()))

  let replace_all t items =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
      Hashtbl.reset t.table;
      List.iter (fun (k, v) -> Hashtbl.replace t.table k v) items;
      if not t.is_synced
      then (
        t.is_synced <- true;
        Eio.Promise.resolve t.resolve_synced ()))
end
