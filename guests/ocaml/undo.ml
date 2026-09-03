(* The undo scene, OCaml port — guests/rust/undo.rs, tools/scenes/undo.steps. *)

open Kaya_wire
open Kaya_app

type todo = { title : string } [@@deriving kaya_gen]

(* kaya invents no name for a typing episode (docs/undo-plan.md D8). *)
let what label = if label = "" then "typing" else label

(* A [Map], because [note_list] renders ASCENDING BY KEY and one script is
   compared byte-for-byte across every lane. *)
module Notes = Map.Make (Int64)

let row_key path =
  match path with
  | I64 n :: _ -> n
  | _ -> invalid_arg "kaya: undo scene expects minted (I64) keys"

let put_note notes key text =
  if text = "" then Notes.remove key notes else Notes.add key text notes

let note_list notes =
  match Notes.bindings notes with
  | [] -> "no notes"
  | ns ->
      "notes "
      ^ String.concat ","
          (List.map (fun (key, text) -> Printf.sprintf "%Ld=%s" key text) ns)

(* AN EMPTY PATH IS THE DRAFT; a path names a ROW, whose field has no id an
   app could hold. *)
let fold_texts draft notes texts =
  List.iter
    (fun (t : undo_text) ->
      if t.ut_path = [] then draft := t.ut_text
      else notes := put_note !notes (row_key t.ut_path) t.ut_text)
    texts

let () =
  let app = Kaya_app.create () in

  let draft = ref "" in
  let row_notes = ref Notes.empty in

  build app (fun () ->
      let status = signal (Str "no todos") in
      let history = signal (Str "history empty") in
      let keys = signal (Str "no keys") in
      let notes = signal (Str "no notes") in
      let todos = collection_of todo_record in

      let key_list () =
        let spell (key, _) =
          match key with
          | I64 n -> Int64.to_string n
          | _ -> invalid_arg "kaya: undo scene expects minted (I64) keys"
        in
        match List.map spell (record_items todos) with
        | [] -> "no keys"
        | ks -> "keys " ^ String.concat "," ks
      in

      let field =
        entry ~a11y_id:"draft" ~on_change:(fun text -> draft := text) ()
      in

      let on_add () =
        let d = !draft in
        if d = "" then begin
          let total = count (record_handle todos) in
          write status (Str (Printf.sprintf "nothing to add, %d total" total))
        end
        else begin
          undoable (Printf.sprintf "add %s" d);
          ignore (insert_record_fresh todos { title = d });
          let total = count (record_handle todos) in
          write status (Str (Printf.sprintf "added %s, %d total" d total));
          write keys (Str (key_list ()));
          focus field;
          (* [clear] inside an undoable group is refused at apply
             (docs/undo-plan.md D4). [post], not a nested [build]: a handler
             already is a transaction (tools/check-ambient-tx.py). *)
          post app (fun () -> clear field)
        end
      in

      let on_remove () =
        match record_items todos with
        | [] ->
            let total = count (record_handle todos) in
            write status
              (Str (Printf.sprintf "nothing to remove, %d total" total))
        | (key, todo) :: _ ->
            undoable (Printf.sprintf "remove %s" todo.title);
            remove (record_handle todos) key;
            let total = count (record_handle todos) in
            write status
              (Str (Printf.sprintf "removed %s, %d total" todo.title total));
            write keys (Str (key_list ()))
      in

      let on_star () =
        undoable "star";
        write status (Str "starred")
      in

      let on_focus () = focus field in

      let on_note path text =
        row_notes := put_note !row_notes (row_key path) text;
        write notes (Str (note_list !row_notes))
      in

      let took_back verb step delta =
        (* A programmatic write never echoes, so the delta is the ONLY
           notification for text an undo restored. *)
        fold_texts draft row_notes delta.ud_texts;
        let total = count (record_handle todos) in
        write history
          (Str (Printf.sprintf "%s %s, %d total" verb (what step) total));
        write keys (Str (key_list ()));
        write notes (Str (note_list !row_notes))
      in

      window ~title:"undo"
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Undo" ~role:role_undo;
                item ~label:"Redo" ~role:role_redo;
              ];
          ]
        ~on_undone:(took_back "undid") ~on_redone:(took_back "redid") ();

      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            label ~a11y_id:"history" ~bind:history (* label#1 *);
            label ~a11y_id:"keys" ~bind:keys (* label#2 *);
            label ~a11y_id:"notes" ~bind:notes (* label#3 *);
            w field (* entry#0 *);
            button ~text:"add" ~on_click:on_add (* button#0 *);
            button ~text:"star" ~on_click:on_star (* button#1 *);
            button ~text:"focus" ~on_click:on_focus (* button#2 *);
            button ~text:"remove" ~on_click:on_remove (* button#3 *);
            each (record_handle todos) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:todo_title;
                      (* UNBOUND ON PURPOSE: a bound field would push the
                         copy's own text back at the widget it came from. *)
                      entry ~on_change:on_note;
                    ]
                    ()));
          ]
          ()
      in
      (* The scene types with real keystrokes, so something must hold focus. *)
      focus field;
      mount root);

  exit (run app)
