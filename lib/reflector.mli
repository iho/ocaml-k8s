(** The List+Watch engine: [bin/main.ml]'s original [list_pods]/
    [watch_pods] generalised over any {!Resource.S} (done, via
    {!Client}) and turned into a long-running, self-healing loop instead
    of a one-shot demo.

    STUB — signature is final, [run] is not implemented yet
    (roadmap Phase 2: populate the cache from LIST, stream WATCH events
    into [on_event], and on {!Client.Error.Gone} or a dropped connection,
    back off and re-LIST instead of stopping). *)
module Make (R : Resource.S) : sig
  type t

  val create :
     ctx:Context.t
    -> ?namespace:string
    -> ?label_selector:string
    -> ?field_selector:string
    -> on_event:(R.t Watch_event.t -> unit)
    -> unit
    -> t
  (** Creates (but does not start) a reflector with its own, freshly
      created cache. [on_event] fires for every ADDED/MODIFIED/DELETED
      after the cache has already been updated — a [Controller] wires this
      to [Workqueue.add]. *)

  val cache : t -> R.t Cache.t

  val run : sw:Eio.Switch.t -> t -> unit
  (** Runs LIST-then-WATCH inline in the calling fiber, forever, until [sw]
      is cancelled. Callers fork this onto a background fiber:
      [Fiber.fork ~sw (fun () -> run ~sw t)]. *)
end
