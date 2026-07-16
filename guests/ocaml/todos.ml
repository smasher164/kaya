(* The todos scene from OCaml, on the let* surface with the
   construction sugar: the record declaration is the schema
   ([@@deriving kaya]), constructors carry their props and handlers,
   containers take their children, and the tree reads as a tree. The
   sugar lowers eagerly to the same records as the explicit floor —
   milestone2.ml keeps that style on purpose.

   Build like milestone2.ml, then run with KAYA_SELFTEST=todos. *)

open Kaya_wire
open Kaya_app

type todo = { title : string; done_ : bool } [@@deriving kaya]

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in
  let next_key = ref 0 in

  build app
    (let* items_left = signal (Str "0 items left") in
     let* todos = collection_of todo_record in

     let items_left_text =
       let* entries = record_items todos in
       let n = List.length (List.filter (fun (_, t) -> not t.done_) entries) in
       io (fun () -> if n = 1 then "1 item left" else Printf.sprintf "%d items left" n)
     in
     let on_add =
       let* key = io (fun () -> incr next_key; Printf.sprintf "t%d" !next_key) in
       let* () = insert_record todos (Str key) { title = !draft; done_ = false } in
       let* status = items_left_text in
       write items_left (Str status)
     in
     let on_toggle keys checked =
       (* One field's delta: the title never travels. todo_patch is
          ppx-generated — one optional labelled argument per field,
          each supplied one recording one update_field. *)
       let* () = todo_patch ~done_:checked todos (List.hd keys) in
       let* status = items_left_text in
       write items_left (Str status)
     in

     let* root =
       column
         [
           entry ~on_change:(fun text -> io (fun () -> draft := text)) ();
           button ~text:"Add" ~on_click:on_add ();
           label ~bind:items_left ();
           each (record_handle todos)
             Tpl.(
               let+ _ =
                 row
                   [
                     checkbox ~checked_field:todo_done_ ~on_toggle ();
                     label ~bind_field:todo_title ();
                   ]
               in
               ());
         ]
     in
     mount root);

  exit (run app)
