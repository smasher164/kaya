(* The correction slice's X2 negative: a run, an edit and a format carry
   a RANGE, so the two loose offsets are gone from the read side. Run by
   ../negatives.py. *)
open Kaya_app

let () =
  let r = { Run.range = (0, 2); name = "bold"; value = "true" } in
  ignore r.Run.start
