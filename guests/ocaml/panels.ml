(* The panels conformance scene, OCaml port — the auxiliary-window
   grammar via labeled arguments. See guests/rust/panels.rs and
   tools/scenes/panels.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app
    (let* () = window ~title:"panels" () in
     let* s = signal (Str "two panels") in
     status := Some s;

     let* root = column [ label ~bind:s () (* label#0 *) ] in
     let* () = mount root in

     (* The veto handler binds to the inspector at its declaration
        (handlers scope to the thing that creates them): it can only
        ever mean this window's close. *)
     let* () =
       create_window ~title:"inspector" ~width:480.0 ~height:320.0
         ~veto_close:true
         ~on_close_requested:(fun tx ->
           write s (Str "close requested") tx;
           destroy_window 1L tx)
         1L
     in
     let* caption = signal (Str "inspector pane") in
     let* aux = column [ label ~bind:caption () (* label#1 *) ] in
     mount_in 1L aux);

  ignore !status;

  exit (run app)
