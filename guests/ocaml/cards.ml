(* The cards scene, OCaml port — guests/rust/cards.rs,
   tools/scenes/cards.steps, docs/styling-pass-plan.md Y4. *)

open Kaya_app

type playlist = { name : string; selected : bool; symbol : symbol } [@@deriving kaya_gen]

let cards = [ ("card1", "Daily Mix 1"); ("card2", "Daily Mix 2"); ("card3", "Discover Weekly") ]

(* The third card is taller, so the row's cards take its height (M16 (1)). *)
let tall = "card3"

(* Cut at two lines with the platform's ellipsis (M16 (2)). *)
let blurb = "Fresh picks every Monday, from the artists you play the most and the ones they listen to"
let library_rows = [ ("p1", "Liked Songs"); ("p2", "Late Night Jazz"); ("p3", "Focus") ]

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      window ~title:"cards" ~width:520.0 ~height:520.0 ();
      let status = signal Scalar.Str "opened: none" in
      let library = collection_of playlist_record in
      (* A section hidden by a When and an empty For take no space (M16 (3)). *)
      let hidden = signal Scalar.Bool false in
      let empty = collection_of playlist_record in
      let card (id, name) =
        column ~filled:Tint.Neutral ~a11y_id:id
          ~on_activate:(fun () -> write status ("opened: " ^ name))
          (([ label ~text:name; caption ~text:"Made for you" ] : (unit -> widget) list)
          @
          if id = tall then
            [
              (fun () ->
                let w = caption ~text:blurb ~a11y_id:"blurb" () in
                set_max_lines w 2;
                w);
            ]
          else [])
      in
      let shelf = ref None in
      let root =
        column ~spacing:16.0
          [
            (fun () ->
              let g = grid ~columns:1 ~columns_auto:140.0 ~spacing:12.0 ~a11y_id:"cards" (List.map card cards) () in
              shelf := Some g;
              g);
            button ~a11y_id:"more" ~text:"More"
              ~on_click:(fun () -> Option.iter (fun g -> within g [ card ("card4", "Release Radar") ]) !shelf);
            label ~bind:status ~a11y_id:"status";
            shown hidden (fun () -> Tpl.(label ~text:"never shown" ()));
            each (record_handle empty) (fun () -> Tpl.(row [ label ~bind_field:playlist_name ] ()));
            label ~text:"end" ~a11y_id:"end";
            each (record_handle library) (fun () ->
                Tpl.(
                  row
                    [
                      row ~a11y_id:"lib" ~selected_field:playlist_selected
                        ~on_activate:(fun keys ->
                          let picked = key_text (List.hd keys) in
                          List.iter
                            (fun (key, _) -> playlist_patch ~selected:(key = picked) library (Key.str key))
                            library_rows)
                        [ label ~bind_field:playlist_name ];
                      button ~a11y_id:"go" ~text:"Play" ~symbol_field:playlist_symbol
                        ~on_click:(fun keys ->
                          let played = key_text (List.hd keys) in
                          List.iter
                            (fun (key, _) ->
                              playlist_patch ~symbol:(if key = played then Pause else Play) library (Key.str key))
                            library_rows);
                    ]
                    ()));
          ]
          ()
      in
      mount root;
      List.iter
        (fun (key, name) -> insert_record library (Key.str key) { name; selected = false; symbol = Play })
        library_rows);
  exit (run app)
