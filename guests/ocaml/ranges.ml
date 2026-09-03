(* The ranges scene, OCaml port — guests/rust/ranges.rs,
   tools/scenes/ranges.steps. *)

open Kaya_wire
open Kaya_app

(* The document, 813 bytes, byte-identical to every other guest's copy. A
   QUOTED literal, because [{doc|...|doc}] takes its bytes verbatim. *)
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

(* The whole search: literal, forward, non-overlapping, in byte offsets. *)
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

  (* The offsets index this copy; kaya is never asked what the text is. *)
  let doc = ref doc_source in

  build app (fun () ->
      window ~title:"ranges" ();
      let status = signal (Str "0 matches") in

      (* Every range assertion finds this control by its authored id. *)
      let editor =
        textarea ~a11y_id:"doc" ~a11y_label:"Document"
          ~on_change:(fun text ->
            doc := text;
            (* A declared set is bound to the text it was declared against
               (D2), so the app must search again. *)
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
                     (* The SECOND match, so a leg can tell the selection
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
                 (* button#2 — focus editor, so the next keystroke is a USER
                    edit through the platform's own input path. *)
                 button ~text:"focus editor" ~on_click:(fun () -> focus editor);
                 (* button#3 — clicked while a composition is live: the
                    backend refuses it (D4). *)
                 button ~text:"select first"
                   ~on_click:(fun () ->
                     match find_all !doc needle with
                     | first :: _ -> select_range editor first
                     | [] -> ());
               ];
           ]
           ()));

  exit (run app)
