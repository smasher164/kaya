(* The typeface scene, OCaml port — guests/rust/typeface.rs,
   tools/scenes/typeface.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let draft = ref "" in

  build app (fun () ->
      (* BEFORE THE FIRST MOUNT, per the set-once wall: register, then
         resolve. *)
     let font = asset "fonts/sora-wght.ttf" in
     brand_typeface ~font_asset:font "Sora";
     asset_close font;
     window ~title:"typeface" ~width:480.0 ~height:360.0 ();

     let heading = signal (Str "typeface") in
     let status = signal (Str "ready") in

     let root =
       column
         [
           (* The heading's text style OVERRIDES the root font: a root-only
              lowering leaves this label in the system face. *)
           label ~role:Heading ~a11y_id:"title" ~bind:heading (* label#0 *);
           label ~bind:status (* label#1 *);
           (* Both a field and a textarea, because they take the swap by
              DIFFERENT routes. *)
           entry ~on_change:(fun text -> draft := text) (* entry#0 *);
           textarea (* textarea#0 *);
           button ~text:"Go"
             ~on_click:(fun () ->
               write status (Str (Printf.sprintf "clicked %s" !draft)))
             (* button#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
