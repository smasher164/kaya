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

   AND THE APP NAMES NO TODO. A todo is a title and nothing else — it
   has no identity of its own — so the key comes from
   [insert_record_fresh], which mints one per collection instance and
   hands it back (docs/fresh-key-plan.md). What that buys here is the
   whole point of the minter: this file used to carry [next_key], an
   [int ref] beside the collection whose safety rested on never
   rewinding, and an undo that rewound it would have handed the same
   name to two todos.

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

(* The app's own map of what is typed in the ROWS, keyed by the todo's
   minted name. A [Map] rather than a list because the rendering below
   is ASCENDING BY KEY on every lane and [bindings] is what says so —
   one script is compared byte-for-byte across five of them. *)
module Notes = Map.Make (Int64)

(* The row a stamped copy's occurrence names: the copy's key path, which
   for a top-level For is one key — the todo's own, minted by
   [insert_record_fresh] and read exactly as [key_list] reads the
   collection's keys. *)
let row_key path =
  match path with
  | I64 n :: _ -> n
  | _ -> invalid_arg "kaya: undo scene expects minted (I64) keys"

(* One note, written into the app's map. AN EMPTY NOTE IS NO NOTE, and
   that is what makes the undo assertion falsifiable: restoring a row's
   field to "" has to REMOVE the key, so an app that ignored the
   payload reads its stale note back out and the script says so.

   ONE SPELLING, TWO ARRIVAL PATHS — a live edit and a restore fold
   through this same function, so the script's assertion cannot pass
   through a second definition of "what a note is". *)
let put_note notes key text =
  if text = "" then Notes.remove key notes else Notes.add key text notes

(* The rows' notes, rendered. THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE
   DRAFT, so this map is the app's own and nothing reads it back off a
   widget. It is also where this scene proves the payload's new shape:
   an undone note arrives naming (template node, key path), and an app
   with two rows can only put it back in the right one because the path
   says which. *)
let note_list notes =
  match Notes.bindings notes with
  | [] -> "no notes"
  | ns ->
      "notes "
      ^ String.concat ","
          (List.map (fun (key, text) -> Printf.sprintf "%Ld=%s" key text) ns)

(* One texts run, folded into the app's two mirrors of widget-owned
   text. The EMPTY PATH is the draft — a live widget, whose id the app
   holds — and a path names a ROW, whose field has no id an app could
   hold at all.

   ALL OF IT, not just the last entry: one step can restore several
   fields, and each one names the field it restores. *)
let fold_texts draft notes texts =
  List.iter
    (fun (t : undo_text) ->
      if t.ut_path = [] then draft := t.ut_text
      else notes := put_note !notes (row_key t.ut_path) t.ut_text)
    texts

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences; the app's copy
     is these refs, not a widget read. Two of them, because there are
     two kinds of text field on screen — the draft, and one per row —
     and the payload's path is what tells them apart. *)
  let draft = ref "" in
  let row_notes = ref Notes.empty in

  build app (fun () ->
      let status = signal (Str "no todos") in
      let history = signal (Str "history empty") in
      let keys = signal (Str "no keys") in
      let notes = signal (Str "no notes") in
      let todos = collection_of todo_record in

      (* The app's collection mirror, rendered: every key it holds, in
         the order it holds them.

         THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored
         entry that came back under a fresh name, or at the end instead
         of where it was, leaves every total in this file correct — the
         entries and orders runs of the delta are what say otherwise,
         and this is where the scene reads them (D5). *)
      let key_list () =
        let spell (key, _) =
          match key with
          (* The minter's keys are I64, so this scene never meets
             another shape; a match that answered for one would be
             inventing a name the collection does not hold. *)
          | I64 n -> Int64.to_string n
          | _ -> invalid_arg "kaya: undo scene expects minted (I64) keys"
        in
        match List.map spell (record_items todos) with
        | [] -> "no keys"
        | ks -> "keys " ^ String.concat "," ks
      in

      (* The field realizes here because the handlers below need its
         handle; [w field] slots the existing widget into the child
         list, where the column merely attaches it. *)
      let field =
        entry ~a11y_id:"draft" ~on_change:(fun text -> draft := text) ()
      in

      let on_add () =
        let d = !draft in
        if d = "" then begin
          (* NOT A STEP, so it names no group and the forward history
             survives it. It is also the one place this app READS ITS
             OWN DRAFT out loud, which is how the script proves the
             restored text of an undone typing episode reached it at
             all. *)
          let total = count (record_handle todos) in
          write status (Str (Printf.sprintf "nothing to add, %d total" total))
        end
        else begin
          (* ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what
             the step is called; everything in this transaction is what
             it did. *)
          undoable (Printf.sprintf "add %s" d);
          (* NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
             name and hands it back. This app has no use for it — a todo
             is looked up by nothing — so the call is made for effect and
             [ignore] says so; an app that does want it (selecting the
             new row, say) takes it from here rather than inventing a
             second name for the same datum. *)
          ignore (insert_record_fresh todos { title = d });
          let total = count (record_handle todos) in
          write status (Str (Printf.sprintf "added %s, %d total" d total));
          write keys (Str (key_list ()));
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

      (* THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The core
         captured the entry and the instance's order before the removal,
         so undoing this puts the entry back under the key it already
         had, where it already was — neither of which this app has to
         remember. The target is the collection's FIRST entry, the
         model's own answer and never a widget's, so the entry that
         comes back has to come back BEFORE the one that stayed. *)
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

      (* A group at its smallest: one signal write, which is the
         undoable set's whole vocabulary on the reactive side. *)
      let on_star () =
        undoable "star";
        write status (Str "starred")
      in

      let on_focus () = focus field in

      (* A note typed into a ROW's field: the copy's key path and the
         text. The same occurrence [~on_change] carries for the draft,
         one identity deeper — the field is uncontrolled either way —
         and the path is how the app knows which row it was.

         NOT A STEP OF ITS OWN: this handler names no group, so the
         signal write below rides an ordinary transaction and the
         ledger banks only the typing episode the core opened. *)
      let on_note path text =
        row_notes := put_note !row_notes (row_key path) text;
        write notes (Str (note_list !row_notes))
      in

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
        fold_texts draft row_notes delta.ud_texts;
        (* The count is read from this app's own collection mirror,
           which the binding reconciled from that payload before this
           handler ran. *)
        let total = count (record_handle todos) in
        write history
          (Str (Printf.sprintf "%s %s, %d total" verb (what step) total));
        (* ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
           script reads that label first, so by the time it reads this
           one the app's own answer is what is on screen — not the value
           the core restored on its way past. The notes ride the same
           transaction for the same reason. *)
        write keys (Str (key_list ()));
        write notes (Str (note_list !row_notes))
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
            label ~a11y_id:"keys" ~bind:keys (* label#2 *);
            label ~a11y_id:"notes" ~bind:notes (* label#3 *);
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
            button ~text:"remove" ~on_click:on_remove (* button#3 *);
            each (record_handle todos) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:todo_title;
                      (* THE ROW'S OWN FIELD, and the reason this scene
                         grew: a copy's text edits are the same
                         occurrence a live field's are, one identity
                         deeper, and the ledger banks them the same way
                         now that the payload can name them. The
                         template tier has no [entry] sugar — there is
                         no source to bind — so the widget-kind floor is
                         the spelling here, in every language. *)
                      (fun () ->
                        let note = widget kind_entry in
                        on_change_node app note on_note;
                        note);
                    ]
                    ()));
          ]
          ()
      in
      (* THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
         holding focus when it does — and focus is the routing
         question's other half. *)
      focus field;
      mount root);

  exit (run app)
