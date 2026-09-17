(* The correction slice's O3 negative: derive takes the GADT witness, so
   the old shape — ANY function of type ['a -> 'a signal], which the
   signature never constrained — no longer typechecks. Run by
   ../negatives.py. *)
open Kaya_app

let () =
  let app = create () in
  build app (fun () ->
      let todos = collection () in
      ignore
        (sum_derive (fun (v : string) -> signal Scalar.Str v) todos (fun _ -> "x")))
