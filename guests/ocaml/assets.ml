(* The assets conformance scene, OCaml port (docs/assets-plan.md,
   ratified 2026-08-18). The byte-frozen contract is
   tools/scenes/assets.steps.

   THIS ONE PROVES THE BYTES. [asset] has two redemptions and the
   typeface scene already covers the other — a font whose bytes go from
   the core's read straight to the platform's font machinery and never
   enter the OCaml heap. Here the guest IS the consumer: [asset_bytes]
   copies the mark out, [image ~source] hands those bytes on, and the
   platform's own decoder answers 64x64 off the real view.

   THE MISS IS A QUESTION, NOT A [try ... with]. [asset_miss_sentence]
   answers the same sentence [asset] would raise with, without raising,
   and that is the only shape nine languages share: Swift's raise is a
   trap rather than an exception, so a Swift sibling cannot catch its own
   miss at all. OCaml could catch [Failure] here and deliberately does
   not — one shape for the observation, in every language.

   LINE 1 ONLY. Line 2 of that sentence names the place the core resolved
   and the route that chose it, which a bundle, a device directory and a
   repo checkout spell three different ways; line 1 is the same
   everywhere, so it is the line a scene can freeze. *)

open Kaya_wire
open Kaya_app

(* Deliberately not there, and a LEGAL name — relative, one component
   deep — so what comes back is the census sentence and not a name-fault
   one. *)
let missing_name = "icons/nope.png"

(* The one the mark is under, and the one the census must list. *)
let mark_name = "icons/kaya-mark.png"

(* The large one: 111400 bytes, so a reader that truncated into a fixed
   buffer shows up here rather than passing quietly. *)
let font_name = "fonts/sora-wght.ttf"

(* The census half of the sentence. Empty in, empty out. *)
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
     (* Read both while the handles are open; the close is explicit, as
        the typeface scene's is. *)
     let mark_bytes = asset_bytes mark in
     let font_length = Bytes.length (asset_bytes font) in
     asset_close mark;
     asset_close font;

     let census = first_line (asset_miss_sentence missing_name) in
     let complaint = asset_miss_sentence font_name in
     (* The other arm is never taken on a healthy lane, and it shows the
        sentence rather than a word about it: a failure here has to say
        what was measured. *)
     let verdict =
       if complaint = "" then "no complaint" else first_line complaint
     in

     let title = signal (Str "assets") in
     let found = signal (Str census) in
     (* [%d] renders an OCaml int with no separator and no padding, and
        [Printf] consults no locale. *)
     let sizes =
       signal
         (Str (Printf.sprintf "%s: %d bytes, %s" font_name font_length verdict))
     in

     let root =
       column
         [
           label ~bind:title (* label#0 *);
           (* THE BYTES, not the blob redemption: this scene is the
              consumer, so what reaches the decoder is what
              [asset_bytes] handed back. *)
           image ~source:mark_bytes (* image#0 *);
           label ~bind:found (* label#1 *);
           label ~bind:sizes (* label#2 *);
         ]
         ()
     in
     mount root);

  (* Nothing to drive: every observation is a read of the first mount. *)
  exit (run app)
