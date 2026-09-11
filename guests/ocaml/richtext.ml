(* The rich text scene, OCaml port — guests/rust/richtext.rs,
   tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the é in the
   first word is what makes a UTF-16 reader fail
   (docs/ranges-units.md). *)

open Kaya_wire
open Kaya_app

let doc_source = "Héllo world\nSecond line"

(* The core's spelling of runs ([expect_runs]), so the binding's document
   and the core's mirror are compared as one string. *)
let spell runs =
  String.concat "|"
    (List.map
       (fun r ->
         if r.r_value = "true" then
           Printf.sprintf "%d:%d %s" r.r_start r.r_stop r.r_name
         else Printf.sprintf "%d:%d %s=%s" r.r_start r.r_stop r.r_name r.r_value)
       runs)

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"richtext" ();
      let last = signal (Str "") in
      let runs = signal (Str "") in

      let editor =
        textarea ~rich:true ~a11y_id:"doc" ~a11y_label:"Document" ()
      in
      (* The two handlers read the editor's own folded document, so they
         are registered once it exists. *)
      on_edit app editor (fun e ->
          let mirror = spell (document editor).d_runs in
          write last
            (Str
               (Printf.sprintf "edit %d:%d <%s> [%s]" e.e_start e.e_stop
                  e.e_inserted (spell e.e_runs)));
          write runs (Str mirror));
      on_format app editor (fun act ->
          let mirror = spell (document editor).d_runs in
          write last
            (Str
               (Printf.sprintf "format %d:%d %s=%s" act.f_start act.f_stop
                  act.f_name
                  (Option.value act.f_value ~default:"off")));
          write runs (Str mirror));

      mount
        (column
           [
             w editor (* textarea#0 *);
             label ~bind:last (* label#0 *);
             label ~bind:runs (* label#1 *);
             row
               [
                 (* button#0 — the declaration: text and runs in one write *)
                 button ~text:"seed"
                   ~on_click:(fun () ->
                     let doc =
                       Document.create doc_source
                       |> Document.bold (0, 6)
                       |> Document.link (7, 12) "https://kaya.dev"
                       |> Document.block (13, 24) Heading2
                     in
                     set_document editor doc;
                     write runs (Str (spell doc.d_runs)));
                 (* button#1 — the app's own edit, italic over the
                    inserted word *)
                 button ~text:"insert"
                   ~on_click:(fun () ->
                     apply_edit editor
                       (Edit.insert 6 ", big" |> Edit.mark (2, 5) "italic" "true");
                     write runs (Str (spell (document editor).d_runs)));
                 (* button#2 — select the first word, for the toolbar act *)
                 button ~text:"select word"
                   ~on_click:(fun () -> select_range editor (0, 6));
                 (* button#3 — the toolbar: take bold off the selection *)
                 button ~text:"unbold"
                   ~on_click:(fun () -> unformat editor "bold");
                 (* button#4 — a block act over the selection's paragraphs *)
                 button ~text:"heading"
                   ~on_click:(fun () -> set_block editor Heading1);
                 (* button#5 — focus, so the next keystroke is a USER edit *)
                 button ~text:"focus" ~on_click:(fun () -> focus editor);
                 (* button#6 — clicked while a composition is live: the
                    core holds the edit, the app's document takes it now *)
                 button ~text:"prefix"
                   ~on_click:(fun () ->
                     apply_edit editor (Edit.insert 0 "> ");
                     write runs (Str (spell (document editor).d_runs)));
               ];
           ]
           ()));

  exit (run app)
