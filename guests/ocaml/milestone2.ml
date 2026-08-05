(* The milestone-2 scene from OCaml, on the let surface with the
   construction sugar: constructors carry their props, containers take
   their children, and the tree reads as a tree. A local open
   (Tpl.( ... )) switches into the template zone — the same vocabulary
   over template-node ids, plus the element bindings. Handles declared
   inside a template escape as the body's result.

   WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and that
   is the whole of its carve-out (DESIGN.md, scope ratified 2026-08-05).
   The remove handler is registered CENTRALLY, after the build, against
   the handle the build returned: [on_click_node app remove_button],
   the tier underneath the [~on_click] argument todos.ml and undo.ml
   pass to their constructors. Both spellings register the same handler
   in the same table; this file is where the explicit one is written
   down. It is also why the group For keeps its result — a central
   registration needs a handle to name, and [each] discards what the
   template body returns.

   AND THE APP NAMES EVERY GROUP AND ITEM ITSELF. "g1" and "a" are
   app-chosen identity, not filler: the scene reaches back for g1 to
   rename it and for g2/a to remove it, so those names are the app's
   own and [insert_fresh] — the minter todos.ml and entry.ml use for
   data that identifies nothing — would be the wrong tool here. A key
   the app looks up is a key the app authors.

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
       (* The group template. The For realizes here because its result
          carries the handles the registration below names (the
          per-group items collection, the remove button); [w group_list]
          slots the live For into the root's child list. The inner For
          is spelled the same way for a different reason: the template
          zone has no [each], so a nested For cannot sit in a child
          list and needs [w item_list] to get there. *)
       let group_list, (items, remove_button) =
         for_each groups (fun () ->
             Tpl.(
               let items = collection () in
               (* A group of a scalar collection IS its name, so the
                  label binds to the element itself — no field to
                  name. *)
               let name = label () in
               bind_text_element name;
               let item_list, (_cell, remove_button) =
                 for_each items (fun () ->
                     let text = label () in
                     bind_text_element text;
                     (* The stamped copies are what the script clicks
                        (button#last, the most recent stamp). *)
                     let remove_button = button ~text:"remove" () in
                     (* The body ends with its blueprint root paired
                        with the handle that escapes; the root is fixed
                        by what was recorded, not by what is returned,
                        so the pair costs nothing. *)
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
          (* The instance handle names the target once; mutation and
             read hang off the same value. The collection is the model:
             the count read is the fold of the patches, this one
             included. *)
          let todos = at items (Str group) in
          remove todos (Str item);
          let left = count todos in
          write status (Str (Printf.sprintf "removed %s/%s, %d left" group item left))
      | _ -> ());

  exit (run app)
