(* The dock scene, OCaml port — guests/rust/dock.rs, tools/scenes/dock.steps,
   docs/styling-pass-plan.md Y8. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      let art = asset_bytes (asset "covers/cover-600.jpg") in
      let playing = signal Scalar.Bool true in
      window ~title:"dock" ~width:720.0 ~height:480.0 ();
      let now_playing = player ~muted:true () in
      dock ~player:now_playing 40L (fun () ->
          let root =
            column
              [
                shown playing (fun () ->
                    Tpl.(
                      row ~a11y_id:"bar"
                        [
                          image ~source:art ~fit:Fit.Cover ~max_width:40.0 ~max_height:40.0
                            ~shape:`Rounded;
                          column [ label ~text:"Blue in Green"; caption ~text:"Miles Davis" ];
                          slider ~min:0.0 ~max:1.0 ~value:0.4 ~a11y_id:"progress";
                          button ~text:"Pause" ~a11y_id:"pause";
                        ]
                        ()));
              ]
              ()
          in
          (root, ()));
      let root =
        column
          [
            label ~text:"Library";
            button ~text:"stop" ~a11y_id:"stop" ~on_click:(fun () -> write playing false);
            button ~text:"play" ~a11y_id:"play" ~on_click:(fun () -> write playing true);
          ]
          ()
      in
      mount root);
  exit (run app)
