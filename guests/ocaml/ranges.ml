(* The text-ranges conformance scene, OCaml port of guests/rust/ranges.rs
   against the byte-frozen tools/scenes/ranges.steps: highlight a set of
   ranges, select one, reveal one, driven by the search in [find_all].

   THE OFFSETS ARE UTF-8 BYTES, kaya's unit everywhere, and an OCaml
   [string] is already a byte sequence — so [String.length] and the scan
   below hand [highlight_ranges] the right numbers unchanged. The
   document opens with a CJK word deliberately: every match then sits
   SIX BYTES further along than it does in UTF-16, the unit four of the
   five backends count, so a backend that forwards kaya's offsets as its
   own decorates six characters early and the frozen offsets say so.

   Build with [dune build], then run with KAYA_SELFTEST=ranges. *)

open Kaya_wire
open Kaya_app

(* The document, byte-identical to every other language's copy (813
   bytes): three occurrences of [alpha] and forty short lines, so the
   last match is below the viewport and REVEAL has something to do.

   A QUOTED string literal, because [{doc|...|doc}] takes its bytes
   verbatim — no escape rule stands between this file's UTF-8 and the
   offsets the scene asserts. *)
let doc_source =
  {doc|line 00: 日本語 preface
line 01: gamma kappa
line 02: alpha beta gamma
line 03: epsilon theta
line 04: zeta nu
line 05: eta zeta
line 06: theta lambda
line 07: iota delta
line 08: kappa iota
line 09: alpha eta theta
line 10: mu eta
line 11: nu mu
line 12: beta epsilon
line 13: gamma kappa
line 14: delta gamma
line 15: epsilon theta
line 16: zeta nu
line 17: eta zeta
line 18: theta lambda
line 19: iota delta
line 20: kappa iota
line 21: lambda beta
line 22: mu eta
line 23: nu mu
line 24: beta epsilon
line 25: gamma kappa
line 26: delta gamma
line 27: epsilon theta
line 28: zeta nu
line 29: eta zeta
line 30: theta lambda
line 31: iota delta
line 32: kappa iota
line 33: lambda beta
line 34: mu eta
line 35: nu mu
line 36: beta epsilon
line 37: alpha iota kappa
line 38: delta gamma
line 39: the last line|doc}

let needle = "alpha"

(* The whole search: literal, forward, non-overlapping, in byte offsets.
   kaya ships no find engine — case folding, word boundaries and regex
   dialect are the app's to write, here. *)
let find_all doc needle =
  let n = String.length needle in
  let last = String.length doc - n in
  let rec go at acc =
    if at > last then List.rev acc
    else if String.sub doc at n = needle then go (at + n) ((at, at + n) :: acc)
    else go (at + 1) acc
  in
  go 0 []

let () =
  let app = Kaya_app.create () in

  (* The app's own copy is the ONLY authority on what the offsets mean;
     kaya is never asked what the text is. *)
  let doc = ref doc_source in

  build app (fun () ->
      window ~title:"ranges" ();
      let status = signal (Str "0 matches") in

      (* Every range assertion reads the platform's accessibility tree, and
         the a11y id is how a leg finds this control there. *)
      let editor =
        textarea ~a11y_id:"doc" ~a11y_label:"Document"
          ~on_change:(fun text ->
            doc := text;
            (* kaya has already dropped the decorations — a declared set
               is bound to the text it was declared against (D2) — so the
               app must search again before claiming anything. *)
            write status (Str "0 matches"))
          ()
      in
      set_text editor doc_source;

      mount
        (column
           [
             w editor (* textarea#0 *);
             label ~bind:status (* label#0 *);
             row
               [
                 (* button#0 — find *)
                 button ~text:"find"
                   ~on_click:(fun () ->
                     let hits = find_all !doc needle in
                     highlight_ranges editor hits;
                     (* The second match, so a leg can tell the selection
                        apart from "the first thing found". *)
                     (match List.nth_opt hits 1 with
                     | Some second -> select_range editor second
                     | None -> ());
                     write status
                       (Str (Printf.sprintf "%d matches" (List.length hits))));
                 (* button#1 — reveal last *)
                 button ~text:"reveal last"
                   ~on_click:(fun () ->
                     match List.rev (find_all !doc needle) with
                     | last :: _ -> reveal_range editor last
                     | [] -> ());
                 (* button#2 — focus editor, so the script's next
                    keystroke is a USER edit through the platform's own
                    input path, not a write kaya made. *)
                 button ~text:"focus editor" ~on_click:(fun () -> focus editor);
                 (* button#3 — select first, clicked while a composition
                    is live: the backend refuses it (D4) and the caret
                    stays where the marked text parked it. *)
                 button ~text:"select first"
                   ~on_click:(fun () ->
                     match find_all !doc needle with
                     | first :: _ -> select_range editor first
                     | [] -> ());
               ];
           ]
           ()));

  exit (run app)
