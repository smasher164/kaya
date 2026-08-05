(* The undo scene, OCaml port: two tiers, one Edit menu, and one ledger
   that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).

   WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. [undoable] names
   the transaction it is called in, and that name is the step: the core
   keeps the inverse of what the batch did to signals and collections,
   and hands it back through [~on_undone]. There is no undo stack in
   this file, no command objects, and no re-run of any handler — an undo
   is a programmatic write of the state that was there before, which is
   why it emits nothing and why the occurrence carries the whole delta.

   THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
   nothing for it at all. Both tiers arrive through the same Edit>Undo
   item, and which one answers is kaya's routing question, not the
   app's (D6).

   THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
   the entry scene's add: it appends a todo AND empties the field. Two
   transactions, deliberately — the undoable group is the insert and the
   status it wrote, and the clear that finishes the form is not part of
   the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
   "milk" returns to the field, the todo stays, and the user is looking
   at a state that never existed (docs/undo-plan.md §2). Here it takes
   back the ADD.

   It is also the design saying the same thing twice: [clear] inside a
   group is REFUSED at apply, because it destroys widget-owned text the
   core never held (D4). Undo restores state, and state is signals plus
   collections.

   Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
   in tools/scenes/undo.steps. *)

open Kaya_wire
open Kaya_app

type todo = { title : string } [@@deriving kaya_gen]

(* What the history label says a step was. A typing episode has no
   authored name and kaya invents none ("Undo Typing" is an Apple
   convention, not a scene string — docs/undo-plan.md D8), so the empty
   label is the app's to spell. *)
let what label = if label = "" then "typing" else label

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences; the app's copy
     is these refs, not a widget read. *)
  let draft = ref "" in
  let next_key = ref 0 in

  build app (fun () ->
      let status = signal (Str "no todos") in
      let history = signal (Str "history empty") in
      let todos = collection_of todo_record in

      (* The field realizes here because the handlers below need its
         handle; [w field] slots the existing widget into the child
         list, where the column merely attaches it. *)
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
          incr next_key;
          (* ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what
             the step is called; everything in this transaction is what
             it did. *)
          undoable (Printf.sprintf "add %s" d);
          insert_record todos (Str (Printf.sprintf "t%d" !next_key)) { title = d };
          let total = count (record_handle todos) in
          write status (Str (Printf.sprintf "added %s, %d total" d total));
          (* A PURE EFFECT rides along and is simply not restored: undo
             restores state, not where you were looking (A2). *)
          focus field;
          (* FINISHING THE FORM IS NOT PART OF THE STEP, so it needs a
             transaction of its own — and in an ambient binding that is
             spelled [post], not a second [build]: a handler ALREADY is
             a transaction, and opening one inside it is the workaround
             that hid a real defect for months (tools/check-ambient-tx.sh).
             Posting from the app thread queues the thunk for
             immediately after this transaction, in its own. So undoing
             the add does not put the draft back beside a todo that is
             gone — and [clear] inside a group would be refused anyway.
             The field empties on screen and reports text_changed ""
             through its normal edit path, so the fold above empties the
             draft. *)
          post app (fun () -> clear field)
        end
      in

      (* A group at its smallest: one signal write, which is the
         undoable set's whole vocabulary on the reactive side. *)
      let on_star () =
        undoable "star";
        write status (Str "starred")
      in

      let on_focus () = focus field in

      (* Undo and redo differ by one word here, and that is the point:
         the two occurrences are byte-identical in layout because ONE
         encoder writes both, so the two directions cannot drift. *)
      let took_back verb step delta =
        (* THE DELTA IS THE ONLY NOTIFICATION for restored text:
           restoring an episode is a programmatic write, and a
           programmatic write never echoes, so an app that folds
           text_changed into its own model — which is every app, the
           field being uncontrolled — would go stale on exactly this
           step if the payload did not carry it (D5). *)
        (match List.rev delta.ud_texts with
        | (_, text) :: _ -> draft := text
        | [] -> ());
        (* The count is read from this app's own collection mirror,
           which the binding reconciled from that payload before this
           handler ran. *)
        let total = count (record_handle todos) in
        write history
          (Str (Printf.sprintf "%s %s, %d total" verb (what step) total))
      in

      (* THE GESTURE LAYER, one tier deeper: an app declares the two
         items and writes nothing else. They act on the focused widget,
         lower to the platform's own command where it has one, and work
         out their own enablement from what is focused and what the
         ledger holds.

         The history handlers ride the window because the ledger is per
         window, and they are PERSISTENT: a history is walked as often
         as the user likes. *)
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
            w field (* entry#0 *);
            button ~text:"add" ~on_click:on_add (* button#0 *);
            button ~text:"star" ~on_click:on_star (* button#1 *);
            (* THE SCENE'S WAY BACK TO THE FIELD. [star] does not move
               the cursor on its own — an app that reaches for focus
               after every action is deciding where the user is looking
               — so the scene says so itself, and the routing question
               ("what is focused?") stays visible in the script rather
               than hidden in a handler. *)
            button ~text:"focus" ~on_click:on_focus (* button#2 *);
            each (record_handle todos) (fun () ->
                Tpl.(row [ label ~bind_field:todo_title ] ()));
          ]
          ()
      in
      (* THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
         holding focus when it does — and focus is the routing
         question's other half. *)
      focus field;
      mount root);

  exit (run app)
