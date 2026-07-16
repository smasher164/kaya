(* The todos scene from OCaml, on the let* surface: records and field
   projection. The descriptor is the schema — the honest floor a future
   ppx deriver will generate — the template binds each field to its own
   widget through typed field tokens, and toggling a row sends one
   field's delta through update_field: the title never travels.

   Build like milestone2.ml, then run with KAYA_SELFTEST=todos. *)

open Kaya_wire
open Kaya_app

(* The record and its descriptor: schema, conversions, and field
   tokens, adjacent by discipline until [@@deriving kaya] deletes the
   obligation. *)
type todo = { title : string; done_ : bool }

let todo_type : todo record_type =
  {
    rt_schema = [ value_str; value_bool ];
    rt_to_values = (fun t -> [ Str t.title; Bool t.done_ ]);
    rt_of_values =
      (function
      | [ Str title; Bool done_ ] -> { title; done_ }
      | _ -> invalid_arg "kaya: todo fields out of order");
  }

let field_title : (todo, string) field = str_field 0
let field_done : (todo, bool) field = bool_field 1

let () =
  let app = Kaya_app.create () in

  let items_left_text todos =
    let* entries = record_items todos in
    let n = List.length (List.filter (fun (_, t) -> not t.done_) entries) in
    io (fun () -> if n = 1 then "1 item left" else Printf.sprintf "%d items left" n)
  in

  let items_left, field, add, todos, check =
    build app
      (let* items_left = signal (Str "0 items left") in

       let* column = widget kind_column in
       let* field = widget kind_entry in
       let* add = widget kind_button in
       let* () = set_text add "Add" in
       let* status = widget kind_label in
       let* () = bind_text status items_left in

       let* todos = collection_of todo_type in
       let* todo_list, check =
         for_each (record_handle todos)
           Tpl.(
             let* row = widget kind_row in
             let* check = widget kind_checkbox in
             let* () = bind_checked_field check field_done in
             let* title = widget kind_label in
             let* () = bind_text_field title field_title in
             let* () = add_child row check in
             let+ () = add_child row title in
             check)
       in

       let* () = add_child column field in
       let* () = add_child column add in
       let* () = add_child column status in
       let* () = add_child column todo_list in
       let+ () = mount column in
       (items_left, field, add, todos, check))
  in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in
  let next_key = ref 0 in
  on_change app field (fun text -> io (fun () -> draft := text));
  on_click app add
    (let* key = io (fun () -> incr next_key; Printf.sprintf "t%d" !next_key) in
     let* () = insert_record todos (Str key) { title = !draft; done_ = false } in
     let* status = items_left_text todos in
     write items_left (Str status));
  on_toggle_node app check (fun keys checked ->
      (* One field's delta: the title never travels. *)
      let* () = update_field todos (List.hd keys) field_done checked in
      let* status = items_left_text todos in
      write items_left (Str status));

  exit (run app)
