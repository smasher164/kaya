(* The cards scene, OCaml port — guests/rust/cards.rs,
   tools/scenes/cards.steps, docs/styling-pass-plan.md Y4. *)

open Kaya_app

type playlist = { name : string; selected : bool } [@@deriving kaya_gen]

let cards = [ ("card1", "Daily Mix 1"); ("card2", "Daily Mix 2"); ("card3", "Discover Weekly") ]
let library_rows = [ ("p1", "Liked Songs"); ("p2", "Late Night Jazz"); ("p3", "Focus") ]

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      window ~title:"cards" ~width:520.0 ~height:520.0 ();
      let status = signal Scalar.Str "opened: none" in
      let library = collection_of playlist_record in
      let card (id, name) =
        column ~filled:Tint.Neutral ~a11y_id:id
          ~on_activate:(fun () -> write status ("opened: " ^ name))
          [ label ~text:name; caption ~text:"Made for you" ]
      in
      let root =
        column ~spacing:16.0
          [
            grid ~columns:3 ~spacing:12.0 (List.map card cards);
            label ~bind:status ~a11y_id:"status";
            each (record_handle library) (fun () ->
                Tpl.(
                  row ~a11y_id:"lib" ~selected_field:playlist_selected
                    ~on_activate:(fun keys ->
                      let picked = key_text (List.hd keys) in
                      List.iter
                        (fun (key, _) -> playlist_patch ~selected:(key = picked) library (Key.str key))
                        library_rows)
                    [ label ~bind_field:playlist_name ]
                    ()));
          ]
          ()
      in
      mount root;
      List.iter
        (fun (key, name) -> insert_record library (Key.str key) { name; selected = false })
        library_rows);
  exit (run app)
