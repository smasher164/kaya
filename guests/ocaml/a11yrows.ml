(* The stamped-accessibility scene from OCaml, on the let surface with
   the construction sugar: two entries stamped from ONE template, each
   carrying its own row's accessibility identity, read back out of the
   PLATFORM'S OWN accessibility tree rather than kaya's model.

   The a11y scene makes that claim for LIVE widgets; this one makes it
   for COPIES — the case none of the accessibility milestone's 719 legs
   made, because until the template zone could spell the two props
   (docs/tpl-props-plan.md P1) no guest could author a stamped widget's
   name at all.

   A SEPARATE SCENE BY DESIGN, NOT BY SIZE. A For materializes as a
   column, harness registries are creation-order, and container creation
   order differs by language — so the a11y scene, which asserts every
   container kind ordinally, cannot host a For without [column#0] naming
   a different widget on every lane (guests/haskell/reorder.hs documents
   the ordering rule). This scene asserts no container at all, so the
   For's column may land at either end of the registry and both targets
   below still mean the same thing everywhere.

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
           (* BOTH PROPS COME FROM THE ROW, and this zone spells a source
              the way it spells every other — by the labeled argument's
              NAME. [~a11y_id] would be a constant shared by every copy;
              [~a11y_id_field] is the copy's own field of the element,
              and a scalar collection's element IS the string, so
              [element] is the whole of the source and there is no field
              name to give.

              THE LABEL IS THE POINT: a list row that announces its own
              name to assistive tech is what a sourced template label is
              for. THE ID IS FORCED: [expect_ax] resolves its target to
              the authored identifier and then searches the real tree by
              that identifier, so copies sharing one constant id are
              indistinguishable to it — and the read now refuses an
              ambiguous id with the count it measured rather than
              answering with whichever element it reached first, which is
              what it did the first time these assertions ran. A shared
              constant id stays legal in the core, since nothing there
              deduplicates; it is simply not a thing that verb can read
              back. *)
           each notes (fun () ->
              Tpl.(entry ~a11y_id_field:element ~a11y_label_field:element ()));
           (* THE STAMPED STYLING PROPS, and a SECOND collection rather
              than two more widgets in the first: [expect_ax] addresses
              the real accessibility tree by AUTHORED IDENTIFIER and
              refuses an ambiguous one, and a scalar row has exactly one
              field to spend on an id — so a second readable stamped
              element needs its own strings.

              BOTH ARE CONSTANTS, and this zone spells a constant the
              way it always has, by the labeled argument's bare name:
              [~role] beside [~bind_field], [~inset] on the container.
              Neither takes a [_field] flavor, deliberately — what a
              copy MEANS and how far its prototype holds children off
              its edge are facts about the PROTOTYPE, not about the
              row's data ([~accepts]'s rule, one prop over).

              ONE TEMPLATE SURFACE HERE, unlike Rust and Java: OCaml's
              template zone is [module Tpl] and nothing else, since
              [Tpl.for_each] hands back a plain node rather than a row
              trace with methods of its own. So both props are spelled
              on the one surface and there is no forward to prove. *)
           each heads (fun () ->
              Tpl.(
                row ~inset:8.0
                  [ label ~role:Heading ~bind_field:element ~a11y_id_field:element ]
                  ()));
         ]
         ()
     in
     mount root;
     (* The rows, seeded once the template is declared. Nothing here
        names a note — a line of text has no identity of its own — so the
        key comes from [insert_fresh], and the scene has no use for the
        name it hands back: [ignore] is OCaml's spelling for an insert
        made for effect. *)
     ignore (insert_fresh notes (Str "First note"));
     ignore (insert_fresh notes (Str "Second note"));
     ignore (insert_fresh heads (Str "Heading one"));
     ignore (insert_fresh heads (Str "Heading two")));

  exit (run app)
