(* The progress scene, OCaml port — guests/rust/progress.rs,
   tools/scenes/progress.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"progress" ();
     let root =
       column
         [
           progress ~value:0.25 (* progress#0 *);
           progress ~indeterminate:true (* progress#1 *);
         ]
         ()
     in
     mount root);

  exit (run app)
