(* The entry scene from OCaml, on the let* surface: the uncontrolled
   contract end to end. The field owns its text and reports each edit
   through on_change; the app folds those into a plain ref (draft) —
   its own model, per doctrine. The add button inserts the draft and
   answers with the count read from the collection model.

   Build like milestone2.ml, then run with KAYA_SELFTEST=entry. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status, field, add, todos =
    build app
      (let* status = signal (Str "no todos") in

       let* column = widget kind_column in
       let* field = widget kind_entry in
       let* add = widget kind_button in
       let* () = set_text add "add" in
       let* status_label = widget kind_label in
       let* () = bind_text status_label status in

       let* todos = collection in
       let* todo_list, () =
         for_each todos
           Tpl.(
             let* label = widget kind_label in
             bind_text_element label)
       in

       let* () = add_child column field in
       let* () = add_child column add in
       let* () = add_child column status_label in
       let* () = add_child column todo_list in
       let+ () = mount column in
       (status, field, add, todos))
  in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in
  let next_key = ref 0 in
  on_change app field (fun text -> io (fun () -> draft := text));
  on_click app add
    (let* key = io (fun () -> incr next_key; Printf.sprintf "t%d" !next_key) in
     let* () = insert todos (Str key) (Str !draft) in
     let* total = count todos in
     write status (Str (Printf.sprintf "added %s, %d total" !draft total)));

  exit (run app)
