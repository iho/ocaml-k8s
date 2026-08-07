type kind =
  | Added
  | Modified
  | Deleted
  | Bookmark

type 'a t =
  { kind : kind
  ; object_ : 'a
  ; request : Request.t
  }
