type t =
  { group : string
  ; version : string
  ; kind : string
  }

let core ~version ~kind = { group = ""; version; kind }

let api_version t = if t.group = "" then t.version else t.group ^ "/" ^ t.version

let to_string t = Printf.sprintf "%s, Kind=%s" (api_version t) t.kind
