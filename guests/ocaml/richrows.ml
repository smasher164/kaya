(* The rich rows scene, OCaml port — guests/rust/richrows.rs,
   tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
   document is a FIELD of the row (docs/rich-text-plan.md §19). The app
   writes a copy's document by patching its row, and a copy's own act
   folds into the row the app reads back. *)

open Kaya_wire
open Kaya_app

type note = { title : string; body : document } [@@deriving kaya_gen]

(* The core's spelling of runs ([expect_runs]), so the row's field and the
   core's mirror are compared as one string. *)
let spell runs =
  String.concat "|"
    (List.map
       (fun r ->
         if r.r_value = "true" then
           Printf.sprintf "%d:%d %s" r.r_start r.r_stop r.r_name
         else Printf.sprintf "%d:%d %s=%s" r.r_start r.r_stop r.r_name r.r_value)
       runs)

let key_text = function
  | Str s -> s
  | I64 n -> Int64.to_string n
  | _ -> "?"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let notes = collection_of note_record in
      let last = signal (Str "") in
      let view = signal (Str "") in

      let row_of key =
        match List.assoc_opt key (record_items notes) with
        | Some note -> note
        | None -> failwith (Printf.sprintf "richrows: no row %s" (key_text key))
      in
      (* An undo or redo moved the row back: the app reads ITS OWN mirror
         of row b, which is the fold a restored Blob field lands in. *)
      let restored _step _delta =
        let note = row_of (Str "b") in
        write view
          (Str (Printf.sprintf "%s | %s" note.body.d_text (spell note.body.d_runs)))
      in

      window ~title:"richrows"
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Undo" ~role:role_undo;
                item ~label:"Redo" ~role:role_redo;
              ];
          ]
        ~on_undone:restored ~on_redone:restored ();

      (* The row's field already carries the copy's act when this fires:
         the app reads the row, never the widget. *)
      let acted keys =
        let key = List.hd keys in
        let note = row_of key in
        write last
          (Str (Printf.sprintf "%s: %s" (key_text key) (spell note.body.d_runs)))
      in

      mount
        (column
           [
             label ~bind:last (* label#0 *);
             label ~bind:view (* label#1 *);
             row
               [
                 (* button#0 — the app writes a copy by patching its row *)
                 button ~text:"patch b"
                   ~on_click:(fun () ->
                     undoable "patch b";
                     note_patch
                       ~body:(Document.create "Patched" |> Document.italic (0, 7))
                       notes (Str "b"));
                 (* button#1 — the row the copy's own act folded into *)
                 button ~text:"read a"
                   ~on_click:(fun () ->
                     let note = row_of (Str "a") in
                     write view
                       (Str
                          (Printf.sprintf "%s | %s" note.body.d_text
                             (spell note.body.d_runs))));
               ];
             each (record_handle notes) (fun () ->
                 Tpl.(
                   column
                     [
                       label ~bind_field:note_title;
                       (fun () ->
                         let body =
                           textarea ~document_field:note_body ~a11y_id:"body" ()
                         in
                         on_edit_node app body (fun keys _ -> acted keys);
                         on_format_node app body (fun keys _ -> acted keys);
                         body);
                     ]
                     ()));
           ]
           ());

      insert_record notes (Str "a")
        {
          title = "a";
          body = Document.create "Héllo world" |> Document.bold (0, 6);
        };
      insert_record notes (Str "b")
        {
          title = "b";
          body =
            Document.create "Second note"
            |> Document.link (7, 11) "https://kaya.dev";
        });

  exit (run app)
