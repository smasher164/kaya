(* The rich text scene, OCaml port — guests/rust/richtext.rs,
   tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the é in the
   first word is what makes a UTF-16 reader fail
   (docs/ranges-units.md). *)

open Kaya_app

let doc_source = "Héllo world\nSecond line"

(* The core's spelling of runs ([expect_runs]), so the binding's document
   and the core's mirror are compared as one string. *)
let spell (runs : Run.t list) =
  String.concat "|"
    (List.map
       (fun (r : Run.t) ->
         if r.value = "true" then
           Printf.sprintf "%d:%d %s" r.start r.stop r.name
         else Printf.sprintf "%d:%d %s=%s" r.start r.stop r.name r.value)
       runs)

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"richtext" ();
      let last = signal_str ("") in
      let runs = signal_str ("") in

      let editor =
        textarea ~rich:true ~a11y_id:"doc" ~a11y_label:"Document" ()
      in
      (* The two handlers read the editor's own folded document, so they
         are registered once it exists. *)
      on_edit app editor (fun e ->
          let mirror = spell (document editor).runs in
          write last
            (Printf.sprintf "edit %d:%d <%s> %s [%s]" e.start e.stop
               e.inserted
               (match e.source with
               | Some s -> edit_source_name s
               | None -> "?")
               (spell e.runs));
          write runs mirror);
      on_format app editor (fun act ->
          let mirror = spell (document editor).runs in
          write last
            (Printf.sprintf "format %d:%d %s=%s" act.start act.stop
               act.name
               (Option.value act.value ~default:"off"));
          write runs mirror);

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
                     write runs ((spell doc.runs)));
                 (* button#1 — the app's own edit, italic over the
                    inserted word *)
                 button ~text:"insert"
                   ~on_click:(fun () ->
                     apply_edit editor
                       (Edit.insert 6 ", big" |> Edit.mark (2, 5) "italic" "true");
                     write runs ((spell (document editor).runs)));
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
                     write runs ((spell (document editor).runs)));
               ];
           ]
           ()));

  exit (run app)
