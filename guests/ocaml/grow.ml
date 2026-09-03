(* The grow scene, OCaml port — guests/rust/grow.rs, tools/scenes/grow.steps. *)

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
           textarea ~grow:2.0 (* textarea#0 *);
           row ~grow:1.0 ~spacing:12.0
             [
               label ~grow:1.0 ~bind:one (* label#1 *);
               button ~grow:3.0 ~text:"three";
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
