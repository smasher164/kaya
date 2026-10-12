(* The safearea scene, OCaml port — guests/rust/safearea.rs,
   tools/scenes/safearea.steps (docs/safe-area-plan.md A3, A8). *)

open Kaya_app

let ground_box : viewbox = (300.0, 200.0)

let ground d ((w, h) : viewbox) =
  move_to d 0.0 0.0;
  line_to d w 0.0;
  line_to d w h;
  line_to d 0.0 h;
  close d;
  fill d ~paint:Series_fill ()

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"safearea" ~width:420.0 ~height:640.0 ();
     let caption = signal Scalar.Str "inset 16" in
     let photo = asset "images/photo.jpg" in
     let root =
       column
         [
           (fun () ->
             let picture =
               image ~a11y_id:"picture" ~a11y_label:"Photo" ~source_asset:photo ~bleed:true ()
             in
             set_max_height picture 160.0;
             picture);
           label ~a11y_id:"caption" ~bind:caption;
           button ~a11y_id:"inset" ~text:"No inset"
             ~on_click:(fun () ->
               window ~inset:0.0 ();
               write caption "inset 0");
           button ~a11y_id:"full" ~text:"Fullscreen"
             ~on_click:(fun () ->
               window ~fullscreen:true ();
               write caption "fullscreen");
           canvas ~grow:1.0 ~a11y_id:"ground" ~a11y_label:"Ground" ~viewbox:ground_box
             ~on_draw:ground ~bleed:true;
         ]
         ()
     in
     asset_close photo;
     mount root);

  exit (run app)
