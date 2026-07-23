(* The grow conformance scene, OCaml port — see guests/rust/grow.rs for
   the full rationale. Every child of the column and of the row is a
   grower, so each split is exactly weight/Σweight: 1,1,2 divide the
   column 25/25/50 and the row's 1,3 divide its width 25/75. The
   harness (KAYA_SELFTEST=grow) asserts both splits plus root-fills,
   byte-for-byte against every other language and backend.

   [grow] is the declarative combinator — it composes over any widget
   decl, containers included; [set_grow] is the dynamic path this
   scene has no reason to use. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let probe = signal (Str "grow probe") in
     let one = signal (Str "one") in

     let root =
       column
         [
           label ~grow:1.0 ~bind:probe (* label#0 *);
           button ~grow:1.0 ~text:"quarter";
           row ~grow:2.0 ~spacing:12.0
             [
               label ~grow:1.0 ~bind:one (* label#1 *);
               button ~grow:3.0 ~text:"three";
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
