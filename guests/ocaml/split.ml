(* The split conformance scene, OCaml port — adaptive list-detail:
   [~list_detail] rides the window, [push_entry ~title ~on_popped] plus
   [mount_in] presents the detail.

   THE GUEST ASKS FOR THE PRESENTATION ONCE and then does nothing adaptive
   again: the platform re-decides as the size class changes, and there is
   no prop for WHICH way it presents.

   TWO scripts drive this ONE app: [split] resizes and names the
   presentation on each side, [listdetail] asserts the bare invariant at
   whatever width its host gives. See guests/rust/split.rs,
   tools/scenes/split.steps and tools/scenes/listdetail.steps. *)

open Kaya_wire
open Kaya_app

let detail = 7L

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* The one adaptive declaration in the whole guest. *)
     window ~title:"split" ~list_detail:true ();
     let s = signal (Str "list pane") in
     let on_detail () =
       push_entry ~title:"detail"
         (* Retention: the base root took this write while the detail was up. *)
         ~on_popped:(fun () -> write s (Str "popped detail"))
         detail;
       (let caption = signal (Str "detail pane") in
        let pane = column [ label ~a11y_id:"detail" ~bind:caption ] () in
        mount_in detail pane)
     in
     let root =
       column
         [
           (* Authored ids so the REAL-TREE read can address these: an index
              read passes whether or not anything reached the screen, which is
              what let a non-rendering split arm look green. *)
           label ~a11y_id:"list" ~bind:s (* label#0 *);
           button ~text:"open detail" ~on_click:on_detail;
         ]
         ()
     in
     mount root);

  exit (run app)
