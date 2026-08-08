type key = string * (string * string) list

let normalize_labels labels = List.sort compare labels

(* Cumulative bucket upper bounds, ascending -- the Prometheus client
   libraries' own default set (5ms .. 10s), picked for typical HTTP/RPC
   latencies. Not configurable per metric name: nothing here needs that
   yet, and a bucket-configuration API would be pure speculation. *)
let default_buckets = [| 0.005; 0.01; 0.025; 0.05; 0.075; 0.1; 0.25; 0.5; 0.75; 1.; 2.5; 5.; 7.5; 10. |]

type histogram =
  { buckets : float array
  ; bucket_counts : int array
  ; mutable sum : float
  ; mutable count : int
  }

type t =
  { counters : (key, float) Hashtbl.t
  ; gauges : (key, float) Hashtbl.t
  ; histograms : (key, histogram) Hashtbl.t
  ; mutex : Eio.Mutex.t
  }

let create () = { counters = Hashtbl.create 16; gauges = Hashtbl.create 16; histograms = Hashtbl.create 16; mutex = Eio.Mutex.create () }

let inc_counter t ~name ~labels =
  let key = name, normalize_labels labels in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let current = Option.value (Hashtbl.find_opt t.counters key) ~default:0. in
    Hashtbl.replace t.counters key (current +. 1.))

let set_gauge t ~name ~labels value =
  let key = name, normalize_labels labels in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> Hashtbl.replace t.gauges key value)

let observe t ~name ~labels value =
  let key = name, normalize_labels labels in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let h =
      match Hashtbl.find_opt t.histograms key with
      | Some h -> h
      | None ->
        let h =
          { buckets = default_buckets; bucket_counts = Array.make (Array.length default_buckets) 0; sum = 0.; count = 0 }
        in
        Hashtbl.replace t.histograms key h;
        h
    in
    (* Each bucket counts observations <= its own upper bound, so a small
       [value] increments every bucket at or above it -- that's already
       the cumulative semantics Prometheus's histogram format expects, no
       separate running-sum pass needed at render time. *)
    Array.iteri (fun i le -> if value <= le then h.bucket_counts.(i) <- h.bucket_counts.(i) + 1) h.buckets;
    h.sum <- h.sum +. value;
    h.count <- h.count + 1)

let context_metrics t = Context.Metrics.create ~inc_counter:(inc_counter t) ~set_gauge:(set_gauge t) ~observe:(observe t)

(* ---------------------------------------------------------------------- *)
(* rendering                                                              *)
(* ---------------------------------------------------------------------- *)

let escape_label_value s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let render_labels labels =
  match labels with
  | [] -> ""
  | _ ->
    (* Sorted for deterministic, diffable output -- matters here
       specifically because histogram bucket lines append ["le", ...] to
       already-normalized labels, which would otherwise render with "le"
       always last instead of in its alphabetical place. *)
    let labels = normalize_labels labels in
    "{"
    ^ String.concat "," (List.map (fun (k, v) -> Printf.sprintf "%s=\"%s\"" k (escape_label_value v)) labels)
    ^ "}"

let names_of entries = entries |> List.map (fun ((name, _), _) -> name) |> List.sort_uniq compare

let render_scalars buf ~type_name entries =
  let names = names_of entries in
  List.iter
    (fun name ->
      Buffer.add_string buf (Printf.sprintf "# TYPE %s %s\n" name type_name);
      List.iter
        (fun ((n, labels), v) -> if n = name then Buffer.add_string buf (Printf.sprintf "%s%s %.6g\n" name (render_labels labels) v))
        entries)
    names

let render_histograms buf entries =
  let names = names_of entries in
  List.iter
    (fun name ->
      Buffer.add_string buf (Printf.sprintf "# TYPE %s histogram\n" name);
      List.iter
        (fun ((n, labels), h) ->
          if n = name
          then (
            Array.iteri
              (fun i le ->
                Buffer.add_string buf
                  (Printf.sprintf "%s_bucket%s %d\n" name
                     (render_labels (labels @ [ "le", Printf.sprintf "%g" le ]))
                     h.bucket_counts.(i)))
              h.buckets;
            Buffer.add_string buf
              (Printf.sprintf "%s_bucket%s %d\n" name (render_labels (labels @ [ "le", "+Inf" ])) h.count);
            Buffer.add_string buf (Printf.sprintf "%s_sum%s %.6g\n" name (render_labels labels) h.sum);
            Buffer.add_string buf (Printf.sprintf "%s_count%s %d\n" name (render_labels labels) h.count)))
        entries)
    names

let entries_of tbl = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []

let render t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let buf = Buffer.create 4096 in
    render_scalars buf ~type_name:"counter" (entries_of t.counters);
    render_scalars buf ~type_name:"gauge" (entries_of t.gauges);
    render_histograms buf (entries_of t.histograms);
    Buffer.contents buf)

(* ---------------------------------------------------------------------- *)
(* serving                                                                *)
(* ---------------------------------------------------------------------- *)

let serve ~sw env t ~port =
  let address = `Tcp (Eio.Net.Ipaddr.V4.any, port) in
  let config = Piaf.Server.Config.create address in
  let handler ({ request; _ } : _ Piaf.Server.ctx) =
    match Piaf.Request.target request with
    | "/metrics" -> Piaf.Response.of_string ~body:(render t) `OK
    | _ -> Piaf.Response.of_string ~body:"not found\n" `Not_found
  in
  let server = Piaf.Server.create ~config handler in
  let (_ : Piaf.Server.Command.t) = Piaf.Server.Command.start ~sw env server in
  ()
