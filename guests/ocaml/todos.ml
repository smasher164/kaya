(* The todos scene, OCaml port — guests/rust/todos.rs,
   tools/scenes/todos.steps. *)

open Kaya_wire
open Kaya_app

type todo = { title : string; done_ : bool } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  let draft = ref "" in

  build app (fun () ->
     let todos = collection_of todo_record in
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
         (* [clear] inside an undoable group is refused at apply
            (docs/undo-plan.md D4). [post], not a nested [build]: a handler
            already is a transaction (tools/check-ambient-tx.py). *)
         post app (fun () ->
             clear field;
             focus field)
       end
     in
     let on_toggle keys checked =
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
