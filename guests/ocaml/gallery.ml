(* The gallery scene from OCaml, on the let* surface with the
   construction sugar: a row with a checkbox and its status label, and
   a row with a slider and its volume label. Constructors carry their
   handlers, containers take their children, and the tree reads as a
   tree. Both controls own their state and report each change — the
   entry's uncontrolled contract, with a bool and a float.

   Build like milestone2.ml, then run with KAYA_SELFTEST=gallery. *)

open Kaya_wire
open Kaya_app

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
         ]
     in
     mount root);

  exit (run app)
