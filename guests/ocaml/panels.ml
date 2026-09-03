(* The panels scene, OCaml port — guests/rust/panels.rs,
   tools/scenes/panels.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app (fun () ->
     window ~title:"panels" ();
     let s = signal (Str "two panels") in
     status := Some s;

     let root = column [ label ~bind:s (* label#0 *) ] () in
     mount root;

     let () =
       create_window ~title:"inspector" ~width:480.0 ~height:320.0
         ~veto_close:true
         ~on_close_requested:(fun () ->
           write s (Str "close requested");
           destroy_window 1L)
         1L
     in
     let caption = signal (Str "inspector pane") in
     let aux = column [ label ~bind:caption (* label#1 *) ] () in
     mount_in 1L aux);

  ignore !status;

  exit (run app)
