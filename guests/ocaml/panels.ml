(* The panels scene, OCaml port — guests/rust/panels.rs,
   tools/scenes/panels.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"panels" ();
     let s = signal Scalar.Str ("two panels") in

     let root = column [ label ~bind:s (* label#0 *) ] () in
     mount root;

     let () =
       create_window ~title:"inspector" ~width:480.0 ~height:320.0
         ~veto_close:true
         ~on_close_requested:(fun () ->
           write s ("close requested");
           destroy_window 1L)
         1L
     in
     let caption = signal Scalar.Str ("inspector pane") in
     let aux = column [ label ~bind:caption (* label#1 *) ] () in
     mount_in 1L aux);

  exit (run app)
