(* The split scene, OCaml port — guests/rust/split.rs,
   tools/scenes/split.steps. *)

open Kaya_app

let detail = 7L

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"split" ~panes:2 ();
     let s = signal_str ("list pane") in
     let on_detail () =
       push_entry ~title:"detail"
         ~on_popped:(fun () -> write s ("popped detail"))
         detail;
       (let caption = signal_str ("detail pane") in
        let pane = column [ label ~a11y_id:"detail" ~bind:caption ] () in
        mount_in detail pane)
     in
     let root =
       column
         [
           (* Authored ids: an index read passes whether or not anything
              reached the screen. *)
           label ~a11y_id:"list" ~bind:s (* label#0 *);
           button ~text:"open detail" ~on_click:on_detail;
         ]
         ()
     in
     mount root);

  exit (run app)
