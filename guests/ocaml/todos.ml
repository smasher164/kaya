(* The todos scene from OCaml, on the let surface with the
   construction sugar: the record declaration is the schema
   ([@@deriving kaya_gen]), constructors carry their props and handlers,
   containers take their children, and the tree reads as a tree. The
   sugar lowers eagerly to the same records as the explicit floor —
   the C guests keep that style on purpose.

   AND THE APP NAMES NO TODO. A todo here is a title and a done flag,
   and neither of them identifies it, so the key comes from
   [insert_record_fresh]: the binding mints one per collection instance
   and hands it back (docs/fresh-key-plan.md). The row's checkbox
   carries that key back out through the stamped path and straight into
   [todo_patch], which is the whole of what this scene asks of a key —
   the app never reads it, formats it or compares it, and so has no
   reason to author it.

   THE ADD IS ONE STEP, AND THIS FILE WRITES NO UNDO CODE FOR IT.
   [undoable] names the insert's transaction; with the Edit menu below,
   that is the whole undo surface here. There is no [~on_undone], no
   history of this app's own, and no handler that so much as mentions
   the items-left label — yet the label comes back with the collection.
   It comes back because the derive's write RODE THAT SAME TRANSACTION
   ([insert_record] recomputes into the transaction it was called in),
   so the named group banked the derived value in both of its
   directions and the core restores the two halves together. Nothing
   recomputes on the way back either: [Kaya_app.absorb_undo] folds the
   payload and stops, deliberately (docs/deferred.md keeps the
   retracted "a derived signal goes stale after an undo" defect, and
   the expectations around the menu activations in
   tools/scenes/todos.steps are this observed rather than argued).

   Build like milestone2.ml, then run with KAYA_SELFTEST=todos. *)

open Kaya_wire
open Kaya_app

type todo = { title : string; done_ : bool } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in

  build app (fun () ->
     let todos = collection_of todo_record in
     (* The items-left label is a derived signal: the binding
        recomputes it from the collection after every mutation, so no
        handler mentions it. *)
     let items_left =
       derive todos (fun entries ->
           let n = List.length (List.filter (fun (_, t) -> not t.done_) entries) in
           Str (if n = 1 then "1 item left" else Printf.sprintf "%d items left" n))
     in
     (* The field realizes here because the handlers below need its
        handle; [w field] slots the existing widget into the child
        list, where the column merely attaches it. *)
     let field = entry ~on_change:(fun text -> draft := text) () in
     let on_add () =
       let d = !draft in
       (* The empty-draft guard every real form has: nothing to insert,
          nothing to command. *)
       if d = "" then ()
       else begin
         (* ONE CALL, AND THE STEP HAS A NAME. Everything else in this
            transaction is what the step did — the insert, and the
            items-left write the insert recomputed — so Edit>Undo takes
            back both of them or neither. *)
         undoable (Printf.sprintf "add %s" d);
         (* NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
            name and hands it back. This app has no use for the returned
            key — a todo is looked up by nothing, and the checkbox's own
            path names its row — so the call is made for effect and
            [ignore] says so. *)
         ignore (insert_record_fresh todos { title = d; done_ = false });
         (* FINISHING THE FORM IS NOT PART OF THE STEP, so it wants a
            transaction of its own — and in an ambient binding that is
            spelled [post], never a second [build]: a handler ALREADY is
            a transaction, and opening one inside it is the workaround
            that hid a real defect for months
            (tools/check-ambient-tx.sh). Posting from the app thread
            queues the thunk for immediately after this transaction, in
            its own. So undoing the add does not put "buy milk" back in
            the field beside a todo that is gone — and [clear] inside a
            group would be refused at apply anyway (D4), because undo
            restores state and widget-owned text is not state the core
            holds. The field empties on screen and reports
            text_changed "" through its normal edit path (the fold
            empties the draft), and the cursor lands back in it. *)
         post app (fun () ->
             clear field;
             focus field)
       end
     in
     let on_toggle keys checked =
       (* One field's delta: the title never travels; the derived
          signal updates itself. todo_patch is ppx-generated — one
          optional labelled argument per field. *)
       todo_patch ~done_:checked todos (List.hd keys)
     in

     (* THE GESTURE LAYER, and this scene declares all of it: two items
        carrying the platform's own roles. They act on what is focused,
        work out their own enablement from what the ledger holds, and
        need no handler here — the step's inverse is core state, so the
        core is what puts it back. The items ride the window because a
        ledger is per window. *)
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
