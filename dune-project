(lang dune 3.11)
(name mlwm)
(generate_opam_files true)

(package
 (name mlwm)
 (synopsis "Minimal dynamic-tiling window manager in OCaml with C/X11 interop")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.11))))
