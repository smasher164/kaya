(* F1 negative: a 'a signal is phantom-typed, so writing the wrong
   OCaml type into a typed signal is a compile error, not a wire
   mismatch discovered by running the scene. Run by ../negatives.py. *)
open Kaya_app

let () =
  let s = signal_str "x" in
  write s true
