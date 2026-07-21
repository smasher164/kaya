(* The window conformance scene, OCaml port — see guests/rust/window.rs
   and tools/scenes/window.steps. The primary surface's props as
   assertions: the title must materialize in the real title bar, the
   advisory 640x400 request must be honored on a desktop. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app
    (let* () = window_title "window probe" in
     let* () = window_size 640.0 400.0 in
     let* probe = signal (Str "window probe") in

     let* root = column [ label ~bind:probe () (* label#0 *) ] in
     mount root);

  exit (run app)
