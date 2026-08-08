(** Kubernetes admission webhooks. A [ValidatingWebhookConfiguration] and
    a [MutatingWebhookConfiguration] both POST the exact same
    [AdmissionReview] JSON envelope to a webhook's HTTPS endpoint and
    expect the same response schema back — only the *registration*
    (which [WebhookConfiguration] fires the call) differs; nothing in the
    request/response shape itself distinguishes "validating" from
    "mutating". So one {!serve} handles both: return {!Deny} to reject
    (validating), {!Allow_with_patch} to mutate, {!Allow} for "no
    objection" either way. *)

module Request : sig
  type operation =
    [ `Create
    | `Update
    | `Delete
    | `Connect
    | `Other of string
    ]

  type t =
    { uid : string
    ; operation : operation
    ; kind : Gvk.t
    ; namespace : string option
    ; name : string
    ; object_ : Yojson.Safe.t option  (** [None] on DELETE. *)
    ; old_object : Yojson.Safe.t option  (** [Some] on UPDATE/DELETE. *)
    ; dry_run : bool
    }

  val decode_object : resource:(module Resource.S with type t = 'a) -> t -> ('a, string) result
  (** Decodes {!object_} via [R.of_json] — [Error] if there's no object
      (a DELETE request) or if [R.of_json] itself fails. *)

  val decode_old_object : resource:(module Resource.S with type t = 'a) -> t -> ('a, string) result
  (** Same, for {!old_object}. *)

  val of_json : Yojson.Safe.t -> t
  (** Decodes a full [AdmissionReview] request envelope's [.request] into
      [t]. Exposed (unlike most of this library's internal JSON parsing)
      specifically so it — and {!response_json} below — can be unit-tested
      against realistic fixture JSON with no server/TLS/cluster involved;
      {!serve} is what actually calls it. *)
end

type decision =
  | Allow
  | Deny of string
  (** Rejects the request; the message reaches the end user's [kubectl]
      output verbatim (as the underlying [meta/v1.Status]'s [message]),
      so it's worth writing for a human, not a log. *)
  | Allow_with_patch of Yojson.Safe.t
  (** A JSON Patch (RFC 6902) document — a JSON array of
      [{"op":...,"path":...,"value":...}] operations — applied to the
      object by the API server if allowed. Only meaningful for a
      [MutatingWebhookConfiguration]; a validating one returning this
      just has the patch silently ignored, since Kubernetes only ever
      applies patches from mutating admission. *)

val response_json : api_version:string -> kind:string -> uid:string -> decision -> Yojson.Safe.t
(** Builds the [AdmissionReview] response envelope [serve] sends back —
    [api_version]/[kind] should be echoed from the request envelope's own
    (Kubernetes doesn't hardcode "admission.k8s.io/v1" as a requirement,
    just that the response matches whatever the request declared). Public
    for the same testability reason as {!Request.of_json}. *)

val serve :
   sw:Eio.Switch.t
  -> Eio_unix.Stdenv.base
  -> port:int
  -> cert:Piaf.Cert.t
  -> private_key:Piaf.Cert.t
  -> path:string
  -> (Request.t -> decision)
  -> unit
(** Starts an HTTPS server, forked onto [sw], answering [POST path] with
    the [AdmissionReview] response built from calling the handler, and
    404 for any other path or method. TLS is not optional here — unlike
    {!Metrics_prometheus.serve}, the API server refuses to call a webhook
    over plain HTTP — so [cert]/[private_key] are required, not a
    convenience default. Getting a certificate the API server will
    actually trust isn't a from-this-library concern (X.509 generation
    needs its own dependency this library doesn't otherwise want) — see
    "Admission webhooks" in the README, where the demo shells out to
    [openssl] instead.

    Deliberately does not catch exceptions raised by the handler — same
    rule as {!Controller}'s reconcile loop: an unexpected exception is a
    bug, allowed to propagate (Piaf's own default error handler turns it
    into a 500) rather than being silently converted into an [Allow]/
    [Deny] that would misrepresent a crash as a real decision. *)
