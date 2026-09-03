(* The assets scene, OCaml port — guests/rust/assets.rs,
   tools/scenes/assets.steps. *)

open Kaya_wire
open Kaya_app

(* Deliberately absent, and a LEGAL name: the answer is the census sentence. *)
let missing_name = "icons/nope.png"

let mark_name = "icons/kaya-mark.png"

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
     let font = asset font_name in
     let mark_bytes = asset_bytes mark in
     let font_length = Bytes.length (asset_bytes font) in
     asset_close mark;
     asset_close font;

     let census = first_line (asset_miss_sentence missing_name) in
     let complaint = asset_miss_sentence font_name in
     let verdict =
       if complaint = "" then "no complaint" else first_line complaint
     in

     let title = signal (Str "assets") in
     let found = signal (Str census) in
     (* [%d] renders an OCaml int with no separator and no locale. *)
     let sizes =
       signal
         (Str (Printf.sprintf "%s: %d bytes, %s" font_name font_length verdict))
     in

     let root =
       column
         [
           label ~bind:title (* label#0 *);
           image ~source:mark_bytes (* image#0 *);
           label ~bind:found (* label#1 *);
           label ~bind:sizes (* label#2 *);
         ]
         ()
     in
     mount root);

  exit (run app)
