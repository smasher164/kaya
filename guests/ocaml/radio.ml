(* The radio scene, OCaml port — guests/rust/radio.rs,
   tools/scenes/radio.steps. *)

open Kaya_app

let options = [ "Small"; "Medium"; "Large" ]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"radio" ();
     let size = signal_str ("size: Small") in

     let on_pick index =
       write size (("size: " ^ List.nth options index))
     in

     let root =
       column
         [
           radio ~selected:0 ~on_select:on_pick options;
           label ~bind:size (* label#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
