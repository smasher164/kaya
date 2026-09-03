(* The styling scene, OCaml port — guests/rust/styling.rs,
   tools/scenes/styling.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* BEFORE THE FIRST MOUNT, per the set-once wall. *)
     brand_accent 0x3584E4;
     window ~title:"styling" ~width:480.0 ~height:360.0 ~inset:0.0 ();

     (* [title], not [heading]: the bare constructor of that name builds
        label#0 below. *)
     let title = signal (Str "Sections") in
     let status = signal (Str "ready") in

     let on_delete () = write status (Str "deleted") in
     let on_save () = write status (Str "saved") in

     let root =
       column
         [
           (* expect_ax resolves a target through its AUTHORED id. *)
           heading ~a11y_id:"title" ~bind:title (* label#0 *);
           label ~bind:status (* label#1 *);
           button ~role:Destructive ~a11y_id:"delete" ~text:"Delete"
             ~on_click:on_delete (* button#0 *);
           button ~role:Prominent ~a11y_id:"save" ~text:"Save"
             ~on_click:on_save (* button#1 *);
           (* Declared so every backend's caption arm runs: no universal AX
              observable, so the walls are the arms' refusals. *)
           caption ~text:"captioned" (* label#2 *);
         ]
         ()
     in
     mount root);

  exit (run app)
