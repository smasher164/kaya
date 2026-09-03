(* The todos scene from OCaml, on the let surface with the construction
   sugar: the record declaration is the schema ([@@deriving kaya_gen]).

   The app names no todo — the key comes from [insert_record_fresh]
   (docs/fresh-key-plan.md).

   THE ADD IS ONE STEP AND THIS FILE WRITES NO UNDO CODE FOR IT. The
   derive's write rides the same transaction, so the group banks both
   halves and the core restores them together.

   Build like milestone2.ml, then run with KAYA_SELFTEST=todos. *)

open Kaya_wire
open Kaya_app

type todo = { title : string; done_ : bool } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences, and the app's
     copy is this ref rather than a widget read. *)
  let draft = ref "" in

  build app (fun () ->
     let todos = collection_of todo_record in
     (* A derived signal: the binding recomputes it from the collection
        after every mutation, so no handler mentions it. *)
     let items_left =
       derive todos (fun entries ->
           let n = List.length (List.filter (fun (_, t) -> not t.done_) entries) in
           Str (if n = 1 then "1 item left" else Printf.sprintf "%d items left" n))
     in
     let field = entry ~on_change:(fun text -> draft := text) () in
     let on_add () =
       let d = !draft in
       if d = "" then ()
       else begin
         undoable (Printf.sprintf "add %s" d);
         ignore (insert_record_fresh todos { title = d; done_ = false });
         (* Emptying the form is NOT part of the step, so it needs its
            own transaction — and [clear] inside an undoable group is
            refused at apply anyway (docs/undo-plan.md D4). [post], not a
            nested [build]: a handler already is a transaction
            (tools/check-ambient-tx.py). *)
         post app (fun () ->
             clear field;
             focus field)
       end
     in
     let on_toggle keys checked =
       (* One field's delta: the title never travels. [todo_patch] is
          ppx-generated, one optional labelled argument per field. *)
       todo_patch ~done_:checked todos (List.hd keys)
     in

     window ~title:"todos"
       ~menus:
         [
           menu ~label:"Edit"
             [
               item ~label:"Undo" ~role:role_undo;
               item ~label:"Redo" ~role:role_redo;
             ];
         ]
       ();

     let root =
       column
         [
           w field;
           button ~text:"Add" ~on_click:on_add;
           label ~bind:items_left;
           each (record_handle todos) (fun () ->
               Tpl.(
                 row
                   [
                     checkbox ~bind_field:todo_done_ ~on_toggle;
                     label ~bind_field:todo_title;
                   ]
                   ()));
         ]
         ()
     in
     mount root);

  exit (run app)
