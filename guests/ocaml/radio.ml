(* The radio conformance scene, OCaml port. See
   guests/rust/radio.rs and tools/scenes/radio.steps. *)

open Kaya_wire
open Kaya_app

let options = [ "Small"; "Medium"; "Large" ]

let () =
  let app = Kaya_app.create () in

  build app
    (let* () = window ~title:"radio" () in
     let* size = signal (Str "size: Small") in

     let on_pick index =
       write size (Str ("size: " ^ List.nth options index))
     in

     let* root =
       column
         [
           radio ~selected:0 ~on_select:on_pick options ();
           label ~bind:size () (* label#0 *);
         ]
     in
     mount root);

  exit (run app)
