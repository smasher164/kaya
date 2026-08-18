(* The milestone-2 scene from OCaml, on the let surface with the
   construction sugar. A local open (Tpl.( ... )) switches into the
   template zone; handles declared inside a template escape as the
   body's result.

   THIS SCENE CARRIES THE EXPLICIT REGISTRATION TIER (DESIGN.md, scope
   ratified 2026-08-05): the remove handler is registered CENTRALLY,
   after the build, against the handle the build returned
   ([on_click_node app remove_button]) rather than through the
   [~on_click] argument todos.ml and undo.ml pass. Both spellings land
   in the same table. It is also why the group For keeps its result —
   [each] discards what the template body returns.

   The app authors "g1" and "a" itself because it looks them up again
   (rename g1, remove g2/a); [insert_fresh] is for data that identifies
   nothing.

   Build the library first (cargo build), then, from a scratch dir
   holding this file plus the contents of bindings/ocaml:
       ocamlfind ocamlopt -package ctypes,ctypes-foreign,threads.posix \
           -linkpkg kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml \
           kaya_app.ml milestone2.ml -o milestone2-ocaml *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let steps = ref 0 in
  let status, items, remove_button =
    build app (fun () ->
       let status = signal (Str "step 0") in
       let extras = signal (Bool false) in

       let groups = collection () in
       (* Both Fors keep their results because the central registration
          below needs the handles they carry. A nested For whose body
          keeps nothing is [Tpl.each] instead, and sits in a child list
          directly (guests/ocaml/menus.ml). *)
       let group_list, (items, remove_button) =
         for_each groups (fun () ->
             Tpl.(
               let items = collection () in
               (* A scalar collection's element IS its value, so
                  [element] is the whole source. *)
               let name = label ~bind_field:element () in
               let item_list, (_cell, remove_button) =
                 for_each items (fun () ->
                     let text = label ~bind_field:element () in
                     (* The stamped copies are what the script clicks
                        (button#last, the most recent stamp). *)
                     let remove_button = button ~text:"remove" () in
                     let cell = column [ w text; w remove_button ] () in
                     (cell, remove_button)) ()
               in
               let _ = column [ w name; w item_list ] () in
               (items, remove_button))) ()
       in

       let on_step () =
         let n = (incr steps; !steps) in
         let () =
           match n with
           | 1 ->
               insert groups (Str "g1") (Str "Work");
               let todos = at items (Str "g1") in
               insert todos (Str "a") (Str "send report");
               insert todos (Str "b") (Str "buy milk")
           | 2 ->
               insert groups (Str "g2") (Str "Home");
               insert (at items (Str "g2")) (Str "a") (Str "water plants");
               update groups (Str "g1") (Str "Office")
           | _ -> ()
         in
         write extras (Bool (n = 1));
         write status (Str (Printf.sprintf "step %d" n))
       in

       let root =
         column
           [
             button ~text:"step" ~on_click:on_step (* button#0 *);
             label ~bind:status (* label#0 *);
             when_ extras (fun () -> Tpl.(label ~text:"extras on" ()));
             w group_list;
           ]
           ()
       in
       mount root;
       (status, items, remove_button))
  in

  on_click_node app remove_button (fun keys ->
      match keys with
      | [ Str group; Str item ] ->
          let todos = at items (Str group) in
          remove todos (Str item);
          let left = count todos in
          write status (Str (Printf.sprintf "removed %s/%s, %d left" group item left))
      | _ -> ());

  exit (run app)
