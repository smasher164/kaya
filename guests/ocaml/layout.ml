(* The layout scene, OCaml port — guests/rust/layout.rs,
   tools/scenes/layout.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let probe = signal_str ("Layout probe") in
     let tail = signal_str ("tail") in
     let mixed = signal_str ("mixed") in
     let nested = signal_str ("nested") in
     let deep = signal_str ("deep") in

     let root =
       column
         [
           label ~bind:probe (* label#0 *);
           row
             [
               button ~text:"A";
               button ~text:"longer";
               label ~bind:tail (* label#1 *);
             ];
           row
             [
               checkbox ~text:"check";
               label ~bind:mixed (* label#2 *);
               slider ~grow:1.0 ~min:0.0 ~max:1.0 ~value:0.5;
             ];
           row
             [
               slider ~grow:1.0 ~min:0.0 ~max:1.0 ~value:0.25;
               slider ~grow:3.0 ~min:0.0 ~max:1.0 ~value:0.75;
             ];
           column
             [
               label ~bind:nested (* label#3 *);
               row [ label ~bind:deep (* label#4 *); button ~text:"x" ];
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
