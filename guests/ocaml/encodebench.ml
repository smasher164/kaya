(* The encode benchmark: pins "derives target the encoder, not a value
   tree" (DESIGN.md, milestone 3) as a suite leg. Encodes N
   collection_insert records through the generated wire encoder and
   requires a floor rate with ~10x headroom — only a structural
   regression (per-record reflection, tree building) can trip it. *)

open Kaya_wire

let () =
  let n = 200_000 in
  let floor_rate = 100_000 (* records/second *) in

  let start = Unix.gettimeofday () in
  let sink = ref 0 in
  for i = 0 to n - 1 do
    let rec_ =
      tx_collection_insert 1L []
        (Str (Printf.sprintf "k%d" (i land 1023)))
        0
        [ Str "send report"; Bool false ]
    in
    sink := !sink + String.length rec_
  done;
  let elapsed = Unix.gettimeofday () -. start in

  let rate = int_of_float (float_of_int n /. elapsed) in
  ignore !sink;
  if rate >= floor_rate then
    Printf.printf "ENCODE_BENCH: OK (ocaml: %d rec/s)\n" rate
  else begin
    Printf.eprintf "ENCODE_BENCH: FAIL (ocaml: %d rec/s, floor %d)\n" rate floor_rate;
    exit 1
  end
