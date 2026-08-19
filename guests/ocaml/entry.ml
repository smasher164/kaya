(* The entry scene from OCaml: the uncontrolled contract end to end. The
   field owns its text and reports each edit through on_change; the app
   folds those into a plain ref.

   THIS SCENE CARRIES THE EXPLICIT REGISTRATION TIER: the handlers are
   registered CENTRALLY, after the build, against the handles the build
   returned, rather than through the [~on_change]/[~on_click] arguments
   todos.ml and undo.ml pass. Both spellings land in the same table.

   Build like milestone2.ml, then run with KAYA_SELFTEST=entry. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status, field, add, todos =
    build app (fun () ->
       let status = signal (Str "no todos") in
       let todos = collection () in

       let field = entry () in
       let add = button ~text:"add" () in

       let root =
         column
           [
             w field (* entry#0 *);
             w add (* button#0 *);
             label ~bind:status (* label#0 *);
             (* A scalar collection's entry IS the string, so [element]
                is the whole source and there is no field name. *)
             each todos (fun () -> Tpl.(label ~bind_field:element ()));
           ]
           ()
       in
       mount root;
       (status, field, add, todos))
  in

  (* The fold: widget-owned state arrives as occurrences, and the app's
     copy is this ref rather than a widget read. *)
  let draft = ref "" in
  on_change app field (fun text -> draft := text);
  on_click app add (fun () ->
     let d = !draft in
     if d = "" then
       let total = count todos in
       write status (Str (Printf.sprintf "nothing to add, %d total" total))
     else begin
       ignore (insert_fresh todos (Str d));
       let total = count todos in
       write status (Str (Printf.sprintf "added %s, %d total" d total));
       (* Finish the form ATOMICALLY with the insert: the field answers
          with text_changed "" through its normal edit path and the fold
          above empties the draft. *)
       clear field;
       focus field
     end);

  exit (run app)
