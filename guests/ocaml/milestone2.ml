(* The milestone-2 scene from OCaml, on the construction sugar over
   the let surface: constructors carry their props and handlers,
   containers take their children, and declarations are values
   ('a decl) composed with the let / let binding operators — so no
   call threads the transaction by hand, and a dropped declaration is a
   type error. A local open (Tpl.( ... )) switches into the template
   zone, operators and vocabulary together. Handles declared inside a
   template escape as the body's result.

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
       (* The group template, floor-flavored: the For realizes here
          because its result carries the handles (the per-group items
          collection, the remove button); [w group_list] slots the
          live For into the root's child list below. *)
       let group_list, (items, remove_button) =
         for_each groups (fun () ->
             Tpl.(
               let items = collection () in
               let remove_ref = ref None in
               let name = widget kind_label in
               bind_text_element name;
               let item_list, _cell =
                 for_each items (fun () ->
                     let text = widget kind_label in
                     bind_text_element text;
                     let remove_button = widget kind_button in
                     set_text remove_button "remove";
                     remove_ref := Some remove_button;
                     column [ w text; w remove_button ] ()) ()
               in
               let _ = column [ w name; w item_list ] () in
               (items, Option.get !remove_ref))) ()
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
             button ~text:"step" ~on_click:on_step;
             label ~bind:status;
             when_ extras (fun () ->
                 Tpl.(
                   let banner_label = widget kind_label in
                   set_text banner_label "extras on"));
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
