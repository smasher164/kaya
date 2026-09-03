(* The entry scene, OCaml port — guests/rust/entry.rs,
   tools/scenes/entry.steps. *)

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
             each todos (fun () -> Tpl.(label ~bind_field:element ()));
           ]
           ()
       in
       mount root;
       (status, field, add, todos))
  in

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
       (* The clear comes back as text_changed "", so the fold empties
          the draft. *)
       clear field;
       focus field
     end);

  exit (run app)
