(* The a11yrows scene, OCaml port — guests/rust/a11yrows.rs,
   tools/scenes/a11yrows.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let notes = collection () in
     let heads = collection () in

     let root =
       column
         [
           (* [~a11y_id_field], not [~a11y_id]: [expect_ax] refuses an
              ambiguous authored identifier (docs/deferred.md). *)
           each notes (fun () ->
              Tpl.(entry ~a11y_id_field:element ~a11y_label_field:element ()));
           (* A SECOND collection because a scalar row has one field to
              spend on an id. *)
           each heads (fun () ->
              Tpl.(
                row ~inset:8.0
                  [ label ~role:Heading ~bind_field:element ~a11y_id_field:element ]
                  ()));
         ]
         ()
     in
     mount root;
     ignore (insert_fresh notes (Str "First note"));
     ignore (insert_fresh notes (Str "Second note"));
     ignore (insert_fresh heads (Str "Heading one"));
     ignore (insert_fresh heads (Str "Heading two")));

  exit (run app)
