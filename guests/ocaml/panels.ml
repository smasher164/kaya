(* The panels conformance scene, OCaml port — the auxiliary-window
   grammar via labeled arguments. See guests/rust/panels.rs and
   tools/scenes/panels.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app
    (let* () = window_title "panels" in
     let* s = signal (Str "two panels") in
     status := Some s;

     let* root = column [ label ~bind:s () (* label#0 *) ] in
     let* () = mount root in

     let* () =
       create_window ~title:"inspector" ~width:480.0 ~height:320.0
         ~veto_close:true 1L
     in
     let* caption = signal (Str "inspector pane") in
     let* aux = column [ label ~bind:caption () (* label#1 *) ] in
     mount_in 1L aux);

  on_close_requested app (fun window tx ->
      (match !status with
      | Some s -> write s (Str "close requested") tx
      | None -> ());
      destroy_window window tx);

  exit (run app)
