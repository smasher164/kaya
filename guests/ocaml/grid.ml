(* The grid conformance scene, OCaml port. See
   guests/rust/grid.rs and tools/scenes/grid.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"grid" ();
     let root =
       column
         [
           grid ~columns:2
             [
               label ~text:"Name:" (* label#0 *);
               label ~text:"Ada Lovelace" (* label#1 *);
               label ~text:"Role:" (* label#2 *);
               label ~text:"Engine programmer" (* label#3 *);
             ];
           row ~grow:1.0
             [
               button ~text:"left" (* button#0 *);
               spacer ~grow:1.0;
               button ~text:"right" (* button#1 *);
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
