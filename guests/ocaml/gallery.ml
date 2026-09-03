(* The gallery scene, OCaml port — guests/rust/gallery.rs,
   tools/scenes/gallery.steps. *)

open Kaya_wire
open Kaya_app

(* A 2x2 RGB PNG, 75 bytes, embedded as source. *)
let test_png =
  Bytes.of_string
    "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\
     \082\000\000\000\002\000\000\000\002\008\002\000\000\000\253\
     \212\154\115\000\000\000\018\073\068\065\084\120\156\099\248\
     \207\192\192\000\194\012\255\129\000\000\031\238\005\251\011\
     \217\104\139\000\000\000\000\073\069\078\068\174\066\096\130"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let status = signal (Str "urgent: false") in
     let volume = signal (Str "volume: 50%") in
     let pos = signal (F64 0.5) in

     let on_urgent checked =
       write status (Str (Printf.sprintf "urgent: %b" checked))
     in
     let on_volume v =
       (* Integer percent, so every language's formatting agrees. *)
       write volume
         (Str (Printf.sprintf "volume: %d%%"
                 (int_of_float (Float.round (v *. 100.)))))
     in
     (* A programmatic write must NOT come back as an occurrence. *)
     let on_quarter () = write pos (F64 0.25) in

     let root =
       column
         [
           row [ checkbox ~text:"urgent" ~on_toggle:on_urgent; label ~bind:status ];
           row
             [
               slider ~min:0.0 ~max:1.0 ~bind:pos ~on_change:on_volume;
               label ~bind:volume;
               button ~text:"quarter" ~on_click:on_quarter;
             ];
           (* Deliberately invalid bytes: a decode failure reads 0x0. *)
           row
             [
               image ~source:test_png;
               image ~source:(Bytes.of_string "not an image");
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
