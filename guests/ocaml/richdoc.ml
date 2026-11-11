(* The rich document scene, OCaml port — guests/rust/richdoc.rs,
   tools/scenes/richdoc.steps (docs/rich-document-plan.md §9 step 2): a
   heading, a body paragraph with a preset colour, a bullet list with a
   nested item, a numbered list and a checklist, then the paragraph acts
   from buttons, the platform's colour picker and a [.kdoc] round trip.
   label#1 is the binding's own Document, folded from the same deltas, so
   it must spell what the core holds. *)

open Kaya_app

(* BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC. *)
let doc_source =
  "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs"

let spell (runs : Run.t list) =
  String.concat "|"
    (List.map
       (fun (r : Run.t) ->
         let start, stop = r.range in
         if Run.is_flag r then Printf.sprintf "%d:%d %s" start stop r.name
         else Printf.sprintf "%d:%d %s=%s" start stop r.name r.value)
       runs)

let seeded =
  Document.create doc_source
  |> Document.block (0, 9) Heading1
  |> Document.color (25, 31) "#016FEF"
  |> Document.list (33, 56) List_kind.Bullet
  |> Document.indent (40, 50) 1
  |> Document.list (57, 67) List_kind.Numbered
  |> Document.checked (68, 72)
  |> Document.list (68, 77) List_kind.Check

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"richdoc" ~width:560. ~height:620.
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Cut" ~role:Menu_role.Cut;
                item ~label:"Copy" ~role:Menu_role.Copy;
                item ~label:"Paste" ~role:Menu_role.Paste;
              ];
          ]
        ();
      let last = signal Scalar.Str "" in
      let runs = signal Scalar.Str (spell seeded.runs) in
      let kdoc = signal Scalar.Str "" in

      let editor =
        textarea ~rich:true ~grow:1. ~a11y_id:"doc" ~a11y_label:"Document" ()
      in
      (* The two handlers read the editor's own folded document, so they
         are registered once it exists. *)
      on_edit app editor (fun e ->
          let mirror = spell (document editor).runs in
          write last
            (Printf.sprintf "edit %d:%d <%s> %s [%s]" (fst e.range) (snd e.range)
               (String.concat "\\n" (String.split_on_char '\n' e.inserted))
               (match e.source with
               | Some s -> edit_source_name s
               | None -> "?")
               (spell e.runs));
          write runs mirror);
      on_format app editor (fun act ->
          let mirror = spell (document editor).runs in
          write last
            (Printf.sprintf "format %d:%d %s=%s" (fst act.range) (snd act.range)
               act.name
               (Option.value act.value ~default:"off"));
          write runs mirror);

      mount
        (column
           [
             w editor (* textarea#0 *);
             label ~bind:last (* label#0 *);
             label ~bind:runs (* label#1 *);
             label ~bind:kdoc (* label#2 *);
             row
               [
                 (* button#0 *)
                 button ~text:"numbered"
                   ~on_click:(fun () -> set_list editor List_kind.Numbered);
                 (* button#1 *)
                 button ~text:"indent" ~on_click:(fun () -> indent editor);
                 (* button#2 *)
                 button ~text:"red" ~on_click:(fun () -> color editor "#DD1F24");
                 (* button#3 *)
                 button ~text:"colour" ~on_click:(fun () -> pick_text_color editor);
                 (* button#4 *)
                 button ~text:"kdoc"
                   ~on_click:(fun () ->
                     let now = document editor in
                     let bytes = Document.to_kdoc now in
                     let back = Document.of_kdoc bytes in
                     set_document editor back.document;
                     write kdoc
                       (Printf.sprintf "kdoc %d bytes, read_only %s, same %b"
                          (String.length bytes)
                          (Option.value back.read_only ~default:"none")
                          (back.document = now));
                     write runs (spell back.document.runs));
               ];
           ]
           ());
      set_document editor seeded);

  exit (run app)
