(* The select conformance scene, OCaml port. See
   guests/rust/select.rs and tools/scenes/select.steps. *)

open Kaya_wire
open Kaya_app

let options = [ "Red"; "Green"; "Blue" ]

let () =
  let app = Kaya_app.create () in

  build app
    (let* () = window_title "select" in
     let* picked = signal (Str "picked: Red") in

     let on_pick index =
       write picked (Str ("picked: " ^ List.nth options index))
     in

     let* root =
       column
         [
           select ~selected:0 ~on_select:on_pick options ();
           label ~bind:picked () (* label#0 *);
         ]
     in
     mount root);

  exit (run app)
