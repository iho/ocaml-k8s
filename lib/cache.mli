(** Local, in-memory mirror of one Kind's objects, keyed by {!Request.t}.
    Owned and written only by a [Reflector]; reconcilers only read it. *)
type 'a t

val create : unit -> 'a t
val get : 'a t -> Request.t -> 'a option
val list : 'a t -> 'a list

val wait_for_sync : 'a t -> unit
(** Blocks the calling fiber until the initial LIST has landed. A
    [Controller]'s worker fibers wait on this before pulling from the
    workqueue, so the very first reconcile of any object already sees a
    warm cache (mirrors controller-runtime's WaitForCacheSync gate). *)

(** Write access, used only by [Reflector]. Kept in a submodule (rather
    than a separate library / .mli pair) so the type stays the same ['a
    t] — callers outside this library are expected to just never open
    [Writer]. *)
module Writer : sig
  val set : 'a t -> Request.t -> 'a -> unit
  val remove : 'a t -> Request.t -> unit
  val mark_synced : 'a t -> unit
end
