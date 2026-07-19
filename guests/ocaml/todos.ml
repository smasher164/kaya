(* The todos scene from OCaml, on the let* surface with the
   construction sugar: the record declaration is the schema
   ([@@deriving kaya_gen]), constructors carry their props and handlers,
   containers take their children, and the tree reads as a tree. The
   sugar lowers eagerly to the same records as the explicit floor —
   the C guests keep that style on purpose.

   Build like milestone2.ml, then run with KAYA_SELFTEST=todos. *)

open Kaya_wire
open Kaya_app

type todo = { title : string; done_ : bool } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in
  let next_key = ref 0 in

  build app
    (let* todos = collection_of todo_record in
     (* The items-left label is a derived signal: the binding
        recomputes it from the collection after every mutation, so no
        handler mentions it. *)
     let* items_left =
       derive todos (fun entries ->
           let n = List.length (List.filter (fun (_, t) -> not t.done_) entries) in
           Str (if n = 1 then "1 item left" else Printf.sprintf "%d items left" n))
     in
     let* field = entry ~on_change:(fun text -> io (fun () -> draft := text)) () in
     let on_add =
       let* d = io (fun () -> !draft) in
       (* The empty-draft guard every real form has: nothing to insert,
          nothing to command. *)
       if d = "" then return ()
       else
         let* key = io (fun () -> incr next_key; Printf.sprintf "t%d" !next_key) in
         let* () = insert_record todos (Str key) { title = d; done_ = false } in
         (* Finish the form: the field empties on screen and reports
            text_changed "" through its normal edit path (the fold
            empties the draft), and the cursor lands back in it. *)
         let* () = clear field in
         focus field
     in
     let on_toggle keys checked =
       (* One field's delta: the title never travels; the derived
          signal updates itself. todo_patch is ppx-generated — one
          optional labelled argument per field. *)
       todo_patch ~done_:checked todos (List.hd keys)
     in

     let* root =
       column
         [
           return field;
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
