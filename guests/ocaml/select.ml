(* The select scene, OCaml port — guests/rust/select.rs,
   tools/scenes/select.steps. *)

open Kaya_app

let options = [ "Red"; "Green"; "Blue" ]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"select" ();
     let picked = signal_str ("picked: Red") in

     let on_pick index =
       write picked (("picked: " ^ List.nth options index))
     in

     let root =
       column
         [
           select ~selected:0 ~on_select:on_pick options;
           label ~bind:picked (* label#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
