(* The stamped-accessibility scene from OCaml: two entries stamped from
   ONE template, each carrying its own row's accessibility identity,
   read back out of the PLATFORM'S OWN accessibility tree
   (docs/tpl-props-plan.md P1).

   IT ASSERTS NO CONTAINER, deliberately. A For materializes as a column
   and harness registries are creation-order, so a scene that names
   [column#0] cannot host a For without meaning a different widget on
   every lane (guests/haskell/reorder.hs documents the ordering rule).

   See guests/rust/a11yrows.rs for the canonical note; the byte-frozen
   contract is tools/scenes/a11yrows.steps. *)

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
           (* [~a11y_id] would be one constant shared by every copy;
              [~a11y_id_field] is the copy's OWN, which is what
              [expect_ax] needs — it addresses the real tree by authored
              identifier and refuses an ambiguous one (docs/deferred.md).
              A scalar collection's element IS the string, so [element]
              is the whole source and there is no field name to give. *)
           each notes (fun () ->
              Tpl.(entry ~a11y_id_field:element ~a11y_label_field:element ()));
           (* A SECOND collection rather than two more widgets in the
              first, because a scalar row has exactly one field to spend
              on an id. [~role] and [~inset] take no [_field] flavor:
              they are facts about the PROTOTYPE, not the row. *)
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
