(* The rich label scene, OCaml port — guests/rust/richlabel.rs,
   tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
   carries the inline vocabulary read-only — the app writes its document
   and edits it, and the widget draws the runs over the role's own font.
   THE OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md). *)

open Kaya_wire
open Kaya_app

let doc_source = "Héllo world, code"

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
      window ~title:"richlabel" ();
      let runs = signal (Str "") in
      let body_text = signal (Str "") in
      let heading_text = signal (Str "Heading with italic") in

      let body = label ~bind:body_text ~rich:true ~a11y_id:"body" () in
      let heading =
        label ~bind:heading_text ~role:Heading ~rich:true ~a11y_id:"heading" ()
      in

      mount
        (column
           [
             w body (* label#0 *);
             w heading (* label#1 *);
             label ~bind:runs ~a11y_id:"runs" (* label#2 *);
             row
               [
                 (* button#0 — the declaration: text and runs in one write *)
                 button ~text:"seed"
                   ~on_click:(fun () ->
                     let doc =
                       Document.create doc_source
                       |> Document.bold (0, 6)
                       |> Document.link (7, 12) "https://kaya.dev"
                       |> Document.mark (14, 18) "code" "true"
                     in
                     let title =
                       Document.create "Heading with italic"
                       |> Document.mark (13, 19) "italic" "true"
                     in
                     set_document body doc;
                     set_document heading title;
                     write runs (Str (spell doc.d_runs)));
                 (* button#1 — the app's own edit, italic over the
                    inserted word *)
                 button ~text:"insert"
                   ~on_click:(fun () ->
                     apply_edit body
                       (Edit.insert 6 ", big" |> Edit.mark (2, 5) "italic" "true");
                     write runs (Str (spell (document body).d_runs)));
                 (* button#2 — THE RANGED ACT ON A LABEL
                    (docs/rich-text-plan.md §17): an italic over a range
                    and the bold taken off another, the label's own
                    document written by range. *)
                 button ~text:"mark"
                   ~on_click:(fun () ->
                     format_range body (1, 4) "italic" "true";
                     (* "Hé": byte 2 is inside the é *)
                     unformat_range body (0, 3) "bold";
                     write runs (Str (spell (document body).d_runs)));
               ];
           ]
           ()));

  exit (run app)
