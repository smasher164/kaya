(* The text-ranges conformance scene, OCaml port of guests/rust/ranges.rs
   against the byte-frozen tools/scenes/ranges.steps: the three
   primitives an editor cannot write for itself — HIGHLIGHT a set of
   ranges, SELECT one, REVEAL one — driven by a search this file writes
   in five lines.

   THE FIVE LINES ARE THE POINT. kaya ships no find engine, no find bar
   and no regex dialect: what to decorate is the app's question, and
   every editor answers it differently. What no app can write for itself
   is the other half — colouring a run of a native text view, moving its
   selection, scrolling it into view — and that is what the framework
   ships. [find_all] below is the whole search.

   THE OFFSETS ARE ORDINARY OCAML STRING INDICES. An OCaml [string] is a
   byte sequence, so [String.length] and a literal scan already count
   UTF-8 bytes — kaya's unit, on the wire and in every binding — and this
   guest hands the range pairs it computed straight to
   [highlight_ranges]. The document opens with a CJK word for a reason:
   every match therefore sits SIX BYTES further along than it sits in
   UTF-16, the unit four of the five backends count. A backend that
   forwarded kaya's byte offsets as if they were its own would decorate
   six characters early, and the scene's frozen offsets say so.

   WHAT EACH LEG PROVES, in the order the script runs them:
     * a set of three matches decorated at once, read back out of the
       platform's own accessibility tree;
     * one of them selected, likewise;
     * the third REVEALED — asserted [offscreen] first, so the leg
       cannot pass on a document that happened to fit;
     * a user's keystroke DROPPING the declared set (D2: ranges are
       app-owned and never tracked across an edit);
     * a [select_range] REFUSED because the user is mid-composition
       (D4), which is the one thing on this surface a backend is
       expected not to do.

   Build with [dune build], then run with KAYA_SELFTEST=ranges. *)

open Kaya_wire
open Kaya_app

(* The document, frozen and byte-identical to every other language's
   copy (813 bytes; the scene compares its offsets byte-for-byte on
   every lane). Three occurrences of [alpha] and nothing else containing
   that substring; forty short lines, so the last match is far below the
   viewport and REVEAL has something to do.

   A QUOTED STRING LITERAL, not a "..." one: [{doc|…|doc}] takes its
   bytes verbatim, so no escape and no line-continuation rule stands
   between this source file's UTF-8 and the document the offsets are
   measured against. *)
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

(* THE WHOLE SEARCH. Literal, forward, non-overlapping, in the byte
   offsets kaya's ranges are made of — [String.sub] over a byte string
   is exactly the comparison [match_indices] makes in the Rust guest,
   and the pairs come out identical. An editor that wants case folding,
   word boundaries or a regex dialect writes those here, in the app,
   where its users can be told what they mean. *)
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

  (* The app's own copy of the document, which is the ONLY authority on
     what the offsets mean. It advances on every edit, exactly as an
     editor's buffer does — kaya is never asked what the text is. *)
  let doc = ref doc_source in

  build app (fun () ->
      window ~title:"ranges" ();
      let status = signal (Str "0 matches") in

      (* The editor realizes here because every handler below needs its
         handle; [w editor] slots it into the child list. The a11y id is
         not decoration: every range assertion reads the platform's
         accessibility tree, and the id is how a leg finds this control
         there. *)
      let editor =
        textarea ~a11y_id:"doc" ~a11y_label:"Document"
          ~on_change:(fun text ->
            doc := text;
            (* THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO. kaya has
               already dropped the decorations — a declared set is bound
               to the text it was declared against — and this is the app
               agreeing rather than being told: an editor whose document
               moved has to search again before it can claim anything
               about where the matches are. *)
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
                 (* button#2 — focus editor, so the keystroke the script
                    types next goes in through the platform's own input
                    path and is a USER edit, not a write kaya made. *)
                 button ~text:"focus editor" ~on_click:(fun () -> focus editor);
                 (* button#3 — select first, which the script clicks while
                    a composition is live: the backend refuses it and the
                    caret stays where the marked text parked it. *)
                 button ~text:"select first"
                   ~on_click:(fun () ->
                     match find_all !doc needle with
                     | first :: _ -> select_range editor first
                     | [] -> ());
               ];
           ]
           ()));

  exit (run app)
