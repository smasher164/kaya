(* The window scene, OCaml port — guests/rust/window.rs,
   tools/scenes/window.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"window probe" ~width:640.0 ~height:400.0 ();
     let probe = signal (Str "window probe") in

     let root = column [ label ~bind:probe (* label#0 *) ] () in
     mount root);

  exit (run app)
