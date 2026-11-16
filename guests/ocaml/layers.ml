(* The layers scene, OCaml port — guests/rust/layers.rs,
   tools/scenes/layers.steps, docs/layering-plan.md LY13. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  let log = ref [ "taps:" ] in
  build app (fun () ->
      window ~title:"layers" ~width:480.0 ~height:860.0 ();
      let answered = signal Scalar.Str "taps:" in
      let veiled = signal Scalar.Bool false in
      let answer word () =
        log := !log @ [ word ];
        write answered (String.concat " " !log);
        if word = "hide" then write veiled true
      in
      let veil () =
        let v =
          column ~align:Center ~fill:true ~a11y_id:"busy"
            [ row ~filled:Tint.Overlay [ label ~text:"Busy" ] ]
            ()
        in
        bind_hidden v veiled;
        v
      in
      let root =
        column ~spacing:16.0
          [
            layers ~inset:8.0 ~a11y_id:"photostack"
              [
                image ~source_asset:(asset "covers/cover-600.jpg") ~max_width:320.0
                  ~a11y_label:"Kind of Blue cover" ~a11y_id:"photo";
                placed Place.Top_trailing
                  (row ~filled:Tint.Accent ~a11y_id:"badge" [ label ~text:"3" ~a11y_id:"badge_text" ]);
                placed Place.Bottom
                  (row ~filled:Tint.Overlay_fade ~a11y_id:"caption"
                     [ label ~text:"Kind of Blue" ~a11y_id:"caption_text" ]);
                placed Place.Bottom_trailing
                  (button ~text:"Share" ~a11y_id:"share" ~on_click:(answer "share"));
              ];
            layers ~a11y_id:"veilstack"
              [ button ~text:"Press the base button here" ~a11y_id:"base" ~on_click:(answer "base"); veil ];
            layers ~a11y_id:"sidestack"
              [
                button ~text:"Open the inbox" ~a11y_id:"side" ~on_click:(answer "side");
                placed Place.Trailing (row ~filled:Tint.Accent ~a11y_id:"sidebadge" [ label ~text:"5" ]);
              ];
            layers ~inset:8.0 ~a11y_id:"flatstack"
              [
                image ~source_asset:(asset "covers/cover-320.jpg") ~max_width:200.0 ~a11y_label:"Small cover"
                  ~a11y_id:"smallphoto";
                placed Place.Top_leading
                  (row ~filled:Tint.Overlay ~a11y_id:"flat" [ label ~text:"Flat panel" ~a11y_id:"flat_text" ]);
              ];
            label ~bind:answered ~a11y_id:"answered";
            button ~text:"Hide the veil" ~a11y_id:"hideveil" ~on_click:(answer "hide");
          ]
          ()
      in
      mount root);
  exit (run app)
