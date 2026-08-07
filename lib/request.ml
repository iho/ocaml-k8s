type t =
  { namespace : string option
  ; name : string
  }

let equal a b = String.equal a.name b.name && Option.equal String.equal a.namespace b.namespace

let compare a b =
  match Option.compare String.compare a.namespace b.namespace with
  | 0 -> String.compare a.name b.name
  | c -> c

let to_string t =
  match t.namespace with
  | Some ns -> ns ^ "/" ^ t.name
  | None -> t.name

let pp fmt t = Format.pp_print_string fmt (to_string t)
