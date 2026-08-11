(* The entry scene from OCaml, on the let surface with the construction
   sugar: the uncontrolled contract end to end. The field owns its text
   and reports each edit through on_change; the app folds those into a
   plain ref (draft) — its own model, per doctrine. The add button
   inserts the draft and answers with the count read from the collection
   model, then clears and refocuses the field — one-shot commands riding
   the insert's transaction; the clear's own text_changed "" re-enters
   through the fold and empties the draft, so a second add finds nothing
   to add.

   WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and that
   is the whole of its carve-out (DESIGN.md, scope ratified 2026-08-05).
   The handlers are registered CENTRALLY, after the build, against the
   handles the build returned: [on_change app field] and
   [on_click app add], the tier underneath the [~on_change] and
   [~on_click] arguments todos.ml and undo.ml pass to their
   constructors. Both spellings register the same handler in the same
   table; this file is where the explicit one is written down. It is
   also why these two widgets realize inside the build and slot into the
   child list with [w] — a central registration needs a handle to name.

   AND THE APP NAMES NO TODO. A draft is a line of text and nothing else
   — it has no identity of its own — so the key comes from
   [insert_fresh]: the binding mints one per collection instance and
   hands it back (docs/fresh-key-plan.md). This file used to carry
   [next_key], an [int ref] outliving every handler that adds; nothing
   here has a use for the name, so the call is made for effect and
   [ignore] says so.

   Build like milestone2.ml, then run with KAYA_SELFTEST=entry. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status, field, add, todos =
    build app (fun () ->
       let status = signal (Str "no todos") in
       let todos = collection () in

       (* The field and the add button realize here because the central
          registrations below need their handles; [w] slots an
          already-realized widget into the child list, where the column
          merely attaches it. *)
       let field = entry () in
       let add = button ~text:"add" () in

       let root =
         column
           [
             w field (* entry#0 *);
             w add (* button#0 *);
             label ~bind:status (* label#0 *);
             (* One stamped label per entry, bound to the ELEMENT
                itself: an entry of a scalar collection IS the string,
                so [element] is the whole of the source and there is no
                field name to give. It lowers to the same element bind
                this line used to spell at the floor. *)
             each todos (fun () -> Tpl.(label ~bind_field:element ()));
           ]
           ()
       in
       mount root;
       (status, field, add, todos))
  in

  (* The fold: widget-owned state arrives as occurrences; the app's
     copy is this ref, not a widget read. *)
  let draft = ref "" in
  on_change app field (fun text -> draft := text);
  on_click app add (fun () ->
     let d = !draft in
     (* The empty-draft guard every real form has — and the scene's
        proof that clear emptied the draft through the occurrence
        fold, not a side assignment. *)
     if d = "" then
       let total = count todos in
       write status (Str (Printf.sprintf "nothing to add, %d total" total))
     else begin
       (* NO KEY, AND NO COUNTER TO GET WRONG: the binding authors the
          name and hands it back, and an app that wants it (selecting
          the new row, say) takes it from here rather than inventing a
          second name for the same datum. *)
       ignore (insert_fresh todos (Str d));
       let total = count todos in
       write status (Str (Printf.sprintf "added %s, %d total" d total));
       (* Finish the form: drop the field's content and put the cursor
          back, atomically with the insert. The field answers with
          text_changed "" through its normal edit path, and the fold
          above empties the draft. *)
       clear field;
       focus field
     end);

  exit (run app)
