(* The gallery scene from OCaml, on the let* surface with the
   construction sugar: a row with a checkbox and its status label, and
   a row with a slider and its volume label. Constructors carry their
   handlers, containers take their children, and the tree reads as a
   tree. Both controls own their state and report each change — the
   entry's uncontrolled contract, with a bool and a float.

   Build like milestone2.ml, then run with KAYA_SELFTEST=gallery. *)

open Kaya_wire
open Kaya_app

(* A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
   binary asset, embedded as source per the include_str! doctrine —
   scenes carry their inputs, no runtime file I/O. *)
let test_png =
  Bytes.of_string
    "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\
     \082\000\000\000\002\000\000\000\002\008\002\000\000\000\253\
     \212\154\115\000\000\000\018\073\068\065\084\120\156\099\248\
     \207\192\192\000\194\012\255\129\000\000\031\238\005\251\011\
     \217\104\139\000\000\000\000\073\069\078\068\174\066\096\130"

let () =
  let app = Kaya_app.create () in

  build app
    (let* status = signal (Str "urgent: false") in
     let* volume = signal (Str "volume: 50%") in

     let on_urgent checked =
       write status (Str (Printf.sprintf "urgent: %b" checked))
     in
     let on_volume v =
       (* Integer percent, so every language's formatting agrees. *)
       write volume
         (Str (Printf.sprintf "volume: %d%%"
                 (int_of_float (Float.round (v *. 100.)))))
     in

     let* root =
       column
         [
           row [ checkbox ~text:"urgent" ~on_toggle:on_urgent (); label ~bind:status () ];
           row
             [
               slider ~min:0.0 ~max:1.0 ~value:0.5 ~on_change:on_volume ();
               label ~bind:volume ();
             ];
           (* The content-buffer row: a valid 2x2 PNG decodes and
              reports its size, and deliberately invalid bytes read
              0x0 — decode failure is the placeholder class, never a
              crash, on every backend. *)
           row
             [
               image ~source:test_png ();
               image ~source:(Bytes.of_string "not an image") ();
             ];
         ]
     in
     mount root);

  exit (run app)
