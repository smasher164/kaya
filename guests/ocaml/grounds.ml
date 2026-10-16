(* The grounds scene, OCaml port — guests/rust/grounds.rs,
   tools/scenes/grounds.steps, docs/styling-pass-plan.md Y2, Y3. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      window ~title:"grounds" ~width:480.0 ~height:560.0 ();
      let art = asset_bytes (asset "covers/cover-600.jpg") in
      let colour =
        match image_dominant art with Some c -> c | None -> failwith "the cover decodes"
      in
      let root =
        column ~spacing:12.0
          [
            column ~inset:24.0 ~ground_gradient:colour ~a11y_id:"header"
              [ heading ~text:"Kind of Blue" ~a11y_id:"title"; caption ~text:"Miles Davis · 1959" ];
            column ~inset:24.0 ~ground_image:art ~a11y_id:"hero"
              [ row ~filled:Tint.Overlay ~a11y_id:"scrim" [ label ~text:"Miles Davis" ] ];
            column ~inset:24.0 ~a11y_id:"plain" [ label ~text:"Plain" ];
          ]
          ()
      in
      mount root);
  exit (run app)
