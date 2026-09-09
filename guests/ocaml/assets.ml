(* The assets scene, OCaml port — guests/rust/assets.rs,
   tools/scenes/assets.steps. *)

open Kaya_wire
open Kaya_app

(* Deliberately absent, and a LEGAL name: the answer is the census sentence. *)
let missing_name = "icons/nope.png"

let mark_name = "icons/kaya-mark.png"

(* SCENERY, and deliberately tiny: an image widget's intrinsic size drives
   layout and the DECLARED mark is a user-supplied source of any size
   (the images/ family's README). The mark is still opened. *)
let picture_name = "images/a11y-logo.png"

(* 111400 bytes, so a reader that truncated into a fixed buffer shows here. *)
let font_name = "fonts/sora-wght.ttf"

let first_line sentence =
  match String.index_opt sentence '\n' with
  | Some at -> String.sub sentence 0 at
  | None -> sentence

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"assets" ~width:480.0 ~height:360.0 ();

     let mark = asset mark_name in
     let picture = asset picture_name in
     let font = asset font_name in
     let mark_length = Bytes.length (asset_bytes mark) in
     let picture_bytes = asset_bytes picture in
     let font_length = Bytes.length (asset_bytes font) in
     asset_close mark;
     asset_close picture;
     asset_close font;

     let census = first_line (asset_miss_sentence missing_name) in
     let complaint = asset_miss_sentence font_name in
     let verdict =
       if complaint = "" then "no complaint" else first_line complaint
     in

     let title = signal (Str "assets") in
     let found = signal (Str census) in
     (* [%d] renders an OCaml int with no separator and no locale. *)
     let present = if mark_length > 0 then "present" else "missing" in
     let sizes =
       signal
         (Str
            (Printf.sprintf "%s %s, %s: %d bytes, %s" mark_name present
               font_name font_length verdict))
     in

     let root =
       column
         [
           label ~bind:title (* label#0 *);
           image ~source:picture_bytes (* image#0 *);
           label ~bind:found (* label#1 *);
           label ~bind:sizes (* label#2 *);
         ]
         ()
     in
     mount root);

  exit (run app)
