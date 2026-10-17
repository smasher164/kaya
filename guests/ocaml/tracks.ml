(* The tracks scene, OCaml port — guests/rust/tracks.rs,
   tools/scenes/tracks.steps, docs/styling-pass-plan.md Y5-Y7. *)

open Kaya_app

type track = {
  number : string;
  title : string;
  artist : string;
  album : string;
  art : bytes;
  tint : Tint.t;
  selected : bool;
}
[@@deriving kaya_gen]

let playlist_length = 60
let playing = 3

let names =
  [|
    ("Blue in Green", "Miles Davis", "Kind of Blue");
    ("So What", "Miles Davis", "Kind of Blue");
    ("Naima", "John Coltrane", "Giant Steps");
  |]

let table tracks id row_id pick =
  let table =
    each (record_handle tracks)
      (fun () ->
        ignore
          Tpl.(
            row ~a11y_id:row_id ~selected_field:track_selected
              ~on_activate:(fun keys -> pick (key_text (List.hd keys)))
              [
                label ~bind_field:track_number;
                row
                  [
                    image ~bind_field:track_art ~fit:Fit.Cover ~max_width:40.0 ~max_height:40.0
                      ~shape:`Rounded ~a11y_id:"art";
                    column
                      [
                        label ~bind_field:track_title ~tint_field:track_tint ~a11y_id:"name";
                        caption ~bind_field:track_artist;
                      ];
                  ];
                label ~bind_field:track_album;
              ]
              ()))
      ()
  in
  columns table [ "#"; "Title"; "Album" ] sort_none;
  set_a11y_id table id;
  table

let track i art =
  let title, artist, album = names.(i mod Array.length names) in
  {
    number = string_of_int (i + 1);
    title;
    artist;
    album;
    art;
    tint = (if i + 1 = playing then Tint.Accent else Tint.None);
    selected = false;
  }

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      window ~title:"tracks" ~width:720.0 ~height:640.0 ();
      let art = asset_bytes (asset "covers/cover-600.jpg") in
      let album = collection_of track_record in
      let playlist = collection_of track_record in
      let pick picked =
        Array.iteri
          (fun i _ ->
            let key = Printf.sprintf "a%d" (i + 1) in
            track_patch ~selected:(key = picked) album (Key.str key))
          names;
        for i = 0 to playlist_length - 1 do
          let key = Printf.sprintf "t%d" (i + 1) in
          track_patch ~selected:(key = picked) playlist (Key.str key)
        done
      in
      let album_table = table album "album" "a" pick in
      let long = table playlist "tracks" "t" pick in
      set_grow long 1.0;
      let root = column ~spacing:12.0 [ w album_table; w long ] () in
      mount root;
      Array.iteri
        (fun i _ -> insert_record album (Key.str (Printf.sprintf "a%d" (i + 1))) (track i art))
        names;
      for i = 0 to playlist_length - 1 do
        insert_record playlist (Key.str (Printf.sprintf "t%d" (i + 1))) (track i art)
      done);
  exit (run app)
