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
  ; env : Eio_unix.Stdenv.base
  ; client : Client.t
  ; sleep_fn : float -> unit
  ; now_fn : unit -> float
  ; log_fn : string -> unit
  ; metrics : Metrics.t
  }

let default_log msg = Eio.traceln "%s" msg

(* Takes the whole [env], not a bare [clock], so that everything hung off
   a [Context.t] -- [Controller.create], [Reflector.create], and anything
   else that needs a fiber-safe clock or a network handle to open its own
   connection (a Reflector's dedicated watch connection, via
   [Client.clone]) -- can be built from [~ctx] alone. Without this, [env]
   and [~clock:env#clock] end up threaded as two extra arguments through
   every [Controller.create] / [Reflector.create] call in every demo, even
   though they're always derived from the same [env] already folded into
   this [t]. *)
let create ~sw ~env ~client ?(log = default_log) ?(metrics = Metrics.noop) () =
  let clock = env#clock in
  { sw; env; client; sleep_fn = Eio.Time.sleep clock; now_fn = (fun () -> Eio.Time.now clock); log_fn = log; metrics }

let env t = t.env
let client t = t.client
let sleep t d = t.sleep_fn d
let now t = t.now_fn ()
let log t fmt = Printf.ksprintf t.log_fn fmt
let metrics t = t.metrics
let is_cancelled t = Eio.Switch.get_error t.sw <> None
