(* The milestone-2 scene from OCaml, on the construction sugar over
   the let* surface: constructors carry their props and handlers,
   containers take their children, and declarations are values
   ('a decl) composed with the let* / let+ binding operators — so no
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
    build app
      (let* status = signal (Str "step 0") in
       let* extras = signal (Bool false) in

       let* banner, () =
         when_ extras
           Tpl.(
             let* banner_label = widget kind_label in
             set_text banner_label "extras on")
       in

       let* groups = collection in
       let* group_list, (items, remove_button) =
         for_each groups
           Tpl.(
             let* name = widget kind_label in
             let* () = bind_text_element name in

             let* items = collection in
             let* item_list, remove_button =
               for_each items
                 (let* text = widget kind_label in
                  let* () = bind_text_element text in
                  let* remove_button = widget kind_button in
                  let* () = set_text remove_button "remove" in
                  let+ _ = column [ return text; return remove_button ] in
                  remove_button)
             in
             let+ _ = column [ return name; return item_list ] in
             (items, remove_button))
       in

       let on_step =
         let* n = io (fun () -> incr steps; !steps) in
         let* () =
           match n with
           | 1 ->
               let* () = insert groups (Str "g1") (Str "Work") in
               let todos = at items (Str "g1") in
               let* () = insert todos (Str "a") (Str "send report") in
               insert todos (Str "b") (Str "buy milk")
           | 2 ->
               let* () = insert groups (Str "g2") (Str "Home") in
               let* () = insert (at items (Str "g2")) (Str "a") (Str "water plants") in
               update groups (Str "g1") (Str "Office")
           | _ -> return ()
         in
         let* () = write extras (Bool (n = 1)) in
         write status (Str (Printf.sprintf "step %d" n))
       in

       let* root =
         column
           [
             button ~text:"step" ~on_click:on_step ();
             label ~bind:status ();
             return banner;
             return group_list;
           ]
       in
       let+ () = mount root in
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
          let* () = remove todos (Str item) in
          let* left = count todos in
          write status (Str (Printf.sprintf "removed %s/%s, %d left" group item left))
      | _ -> return ());

  exit (run app)
