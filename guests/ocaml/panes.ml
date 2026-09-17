(* The panes scene, OCaml port — guests/rust/panes.rs,
   tools/scenes/panes.steps. *)

open Kaya_app

let content = 7L
let detail = 8L

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"panes" ~panes:3 ();

     let on_detail () =
       push_entry ~title:"detail" detail;
       let caption = signal Scalar.Str ("detail pane") in
       let pane = column [ label ~a11y_id:"detail" ~bind:caption ] () in
       mount_in detail pane
     in
     let on_content () =
       push_entry ~title:"content" content;
       let caption = signal Scalar.Str ("content pane") in
       let pane =
         column
           [
             label ~a11y_id:"content" ~bind:caption (* label#1 *);
             button ~text:"open detail" ~on_click:on_detail (* button#1 *);
           ]
           ()
       in
       mount_in content pane
     in

     let caption = signal Scalar.Str ("root pane") in
     let root =
       column
         [
           (* Authored ids: an index read passes whether or not anything
              reached the screen. *)
           label ~a11y_id:"root" ~bind:caption (* label#0 *);
           button ~text:"open content" ~on_click:on_content (* button#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
