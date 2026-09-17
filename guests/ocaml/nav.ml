(* The nav scene, OCaml port — guests/rust/nav.rs, tools/scenes/nav.steps. *)

open Kaya_app

let detail = 7L
let settings = 8L

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"nav" ();
     let s = signal Scalar.Str ("at root") in
     let on_detail () =
       push_entry ~title:"detail"
         ~on_popped:(fun () -> write s ("popped detail"))
         detail;
       (let caption = signal Scalar.Str ("detail pane") in
        let pane = column [ label ~bind:caption ] () in
        mount_in detail pane;
        write s ("pushed detail"))
        
     in
     let on_settings () =
       push_entry ~title:"settings" ~intercept_back:true
         ~on_back_requested:(fun () ->
           write s ("back requested");
           pop_entry ())
         settings;
       (let caption = signal Scalar.Str ("settings pane") in
        let pane = column [ label ~bind:caption ] () in
        mount_in settings pane;
        write s ("pushed settings"))
        
     in
     let root =
       column
         [
           label ~bind:s (* label#0 *);
           button ~text:"open detail" ~on_click:on_detail;
           button ~text:"open settings" ~on_click:on_settings;
         ]
         ()
     in
     mount root);

  exit (run app)
