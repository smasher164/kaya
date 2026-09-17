(* The correction slice's X1 negative: a picked file is re-opened with a
   closed File_mode.t, never the wire's own integer. Run by
   ../negatives.py. *)
open Kaya_app

let () =
  let file = { handle = 1L; name = "n"; local_path = "" } in
  ignore (open_picked file 0)
