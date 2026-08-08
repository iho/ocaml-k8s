(lang dune 3.0)

(generate_opam_files true)

(package
 (name k8s)
 (synopsis "A strict, type-driven Eio + Piaf framework for writing Kubernetes operators in OCaml 5")
 (depends
  (ocaml (>= 5.1))
  dune
  eio
  eio_main
  piaf
  uri
  yojson
  base64))
