(* The layout scene, OCaml port — the native-default observation
   vehicle; see guests/rust/layout.rs for the axes it stresses. The two
   label expects (KAYA_SELFTEST=layout) only prove the tree built; the
   scene asserts no geometry — container targets index by creation
   order, which legitimately differs per language. The grow contract is
   asserted in the grow scene instead. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app
    (let* probe = signal (Str "Layout probe") in
     let* tail = signal (Str "tail") in
     let* mixed = signal (Str "mixed") in
     let* nested = signal (Str "nested") in
     let* deep = signal (Str "deep") in

     let* root =
       column
         [
           label ~bind:probe () (* label#0 *);
           (* Main-axis free space: three unequal children with
              leftover room. *)
           row
             [
               button ~text:"A" ();
               button ~text:"longer" ();
               label ~bind:tail () (* label#1 *);
             ];
           (* Cross-axis alignment: three different intrinsic heights,
              one grower filling the leftover row width. *)
           row
             [
               checkbox ~text:"check" ();
               label ~bind:mixed () (* label#2 *);
               slider ~grow:1.0 ~min:0.0 ~max:1.0 ~value:0.5 ();
             ];
           (* Proportional grow: two growers of unequal weight in one
              row. *)
           row
             [
               slider ~grow:1.0 ~min:0.0 ~max:1.0 ~value:0.25 ();
               slider ~grow:3.0 ~min:0.0 ~max:1.0 ~value:0.75 ();
             ];
           (* Nesting: a column inside the root column, a row inside
              that. *)
           column
             [
               label ~bind:nested () (* label#3 *);
               row [ label ~bind:deep () (* label#4 *); button ~text:"x" () ];
             ];
         ]
     in
     mount root);

  exit (run app)
