(* The sizepolicy scene, OCaml port — guests/rust/sizepolicy.rs,
   tools/scenes/sizepolicy.steps. *)

(* No [open Kaya_wire]: this scene names no wire value constructor. *)
open Kaya_app

(* The declared box of the two CONSTANT-mode canvases: the one number
   `scale` and `fixed` disagree about. *)
let box : viewbox = (300.0, 120.0)

(* A rectangle at [l..r] and [t..b] as FRACTIONS of the box. *)
let panel d ((w, h) : viewbox) l t r b paint =
  move_to d (l *. w) (t *. h);
  line_to d (r *. w) (t *. h);
  line_to d (r *. w) (b *. h);
  line_to d (l *. w) (b *. h);
  close d;
  fill d ~paint ()

(* The figure the three drawing canvases share. The centre probe point is
   opaque, which is what [expect_ink] rests on. *)
let figure d box =
  panel d box 0.05 0.0 0.95 1.0 Ground;
  panel d box 0.25 0.0 0.75 1.0 Series_fill

(* The bar whose RIGHT EDGE is the frame number; the scene pins exact frames. *)
let bar d box frame =
  panel d box 0.25 0.0 (0.35 +. (0.10 *. float_of_int frame)) 1.0 Axis

(* Seconds back to the frame the harness drove, off the time the guest was
   HANDED and never one of its own (§15.4). *)
let frame_of time = int_of_float (Float.max 0.0 (Float.round (time *. 60.0)))

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"sizepolicy" ~width:480.0 ~height:420.0 ();

     let root =
       column
         [
           (* SCALE (the default) *)
           canvas ~grow:1.0 ~a11y_id:"fit" ~a11y_label:"Scaled panel"
             ~viewbox:box ~draw:(fun d -> figure d box);
           (* FIXED *)
           canvas ~grow:1.0 ~a11y_id:"mark" ~a11y_label:"Fixed mark"
             ~viewbox:box ~draw:(fun d -> figure d box) ~fixed:true;
           (* REDRAW *)
           canvas ~grow:1.0 ~a11y_id:"live" ~a11y_label:"Redrawn panel"
             ~viewbox:box ~on_draw:(fun d size -> figure d size);
           (* TICK: under the harness the clock is the core's own step. *)
           canvas ~grow:1.0 ~a11y_id:"clock" ~a11y_label:"Animated bar"
             ~viewbox:box
             ~on_tick:(fun d size time -> bar d size (frame_of time));
         ]
         ()
     in
     mount root);

  exit (run app)
