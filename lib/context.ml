module Metrics = struct
  type t =
    { inc_counter : name:string -> labels:(string * string) list -> unit
    ; set_gauge : name:string -> labels:(string * string) list -> float -> unit
    ; observe : name:string -> labels:(string * string) list -> float -> unit
    }

  let noop =
    { inc_counter = (fun ~name:_ ~labels:_ -> ())
    ; set_gauge = (fun ~name:_ ~labels:_ _ -> ())
    ; observe = (fun ~name:_ ~labels:_ _ -> ())
    }

  let create ~inc_counter ~set_gauge ~observe = { inc_counter; set_gauge; observe }
  let inc_counter t = t.inc_counter
  let set_gauge t = t.set_gauge
  let observe t = t.observe
end

type t =
  { sw : Eio.Switch.t
  ; client : Client.t
  ; sleep_fn : float -> unit
  ; log_fn : string -> unit
  ; metrics : Metrics.t
  }

let default_log msg = Eio.traceln "%s" msg

let create ~sw ~client ~clock ?(log = default_log) ?(metrics = Metrics.noop) () =
  { sw; client; sleep_fn = Eio.Time.sleep clock; log_fn = log; metrics }

let client t = t.client
let sleep t d = t.sleep_fn d
let log t fmt = Printf.ksprintf t.log_fn fmt
let metrics t = t.metrics
let is_cancelled t = Eio.Switch.get_error t.sw <> None
