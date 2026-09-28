(* The fullscreen scene, OCaml port — guests/rust/fullscreen.rs,
   tools/scenes/fullscreen.steps. The app keeps its own copy of the state:
   a toggle writes [not on], and the user's door moves the copy through
   [~on_fullscreen_changed]. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  let on = ref false in
  let pinged = ref 0 in

  build app (fun () ->
     let asked = signal Scalar.Str "windowed" in
     let user = signal Scalar.Str "no change from the user" in
     let pings = signal Scalar.Str "pings 0" in

     let on_toggle () =
       on := not !on;
       window ~fullscreen:!on ();
       write asked (if !on then "asked for fullscreen" else "asked for a window")
     in
     let on_ping () =
       incr pinged;
       write pings (Printf.sprintf "pings %d" !pinged)
     in
     let on_fullscreen_changed now =
       on := now;
       write user
         (if now then "the user turned fullscreen on"
          else "the user turned fullscreen off")
     in

     window ~title:"fullscreen" ~on_fullscreen_changed ();

     let root =
       column
         [
           label ~bind:asked (* label#0 *);
           label ~bind:user (* label#1 *);
           label ~bind:pings (* label#2 *);
           button ~text:"toggle fullscreen" ~on_click:on_toggle (* button#0 *);
           button ~text:"ping" ~on_click:on_ping (* button#1 *);
         ]
         ()
     in
     mount root);

  exit (run app)
