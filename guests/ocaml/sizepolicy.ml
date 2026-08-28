(* The canvas SIZE-POLICY scene, OCaml port — see guests/rust/sizepolicy.rs
   for the full rationale and tools/scenes/sizepolicy.steps for the
   byte-frozen contract (docs/canvas-plan.md §3.2.1).

   ALL FOUR CANVASES GROW, which is the only reason the scene can see
   anything: an ungrown canvas is its natural size, so its track IS its
   viewbox and every policy agrees.

   EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, so one
   frozen expectation serves four different tracks. *)

(* No [open Kaya_wire]: this scene declares no signal and no collection,
   so it names no wire value constructor. *)
open Kaya_app

(* The declared box of the two CONSTANT-mode canvases: a `scale` canvas
   keeps drawing in it at any size and a `fixed` one refuses to leave it,
   so it is the one number the two of them disagree about. *)
let box : viewbox = (300.0, 120.0)

(* An axis-aligned rectangle at [l..r] and [t..b] as FRACTIONS of the
   box, filled with one paint role. *)
let panel d ((w, h) : viewbox) l t r b paint =
  move_to d (l *. w) (t *. h);
  line_to d (r *. w) (t *. h);
  line_to d (r *. w) (b *. h);
  line_to d (l *. w) (b *. h);
  close d;
  fill d ~paint ()

(* The figure the three drawing canvases share: a ground panel inset a
   twentieth of the WIDTH with a translucent series panel over its middle
   half. The centre probe point is opaque, which is what [expect_ink]
   rests on. *)
let figure d box =
  panel d box 0.05 0.0 0.95 1.0 Ground;
  panel d box 0.25 0.0 0.75 1.0 Series_fill

(* The animating canvas's bar, whose RIGHT EDGE is the frame number: 35
   hundredths plus ten per frame. The scene asserts exact frames. *)
let bar d box frame =
  panel d box 0.25 0.0 (0.35 +. (0.10 *. float_of_int frame)) 1.0 Axis

(* Seconds back to the frame the harness drove. The guest reads the time
   it was HANDED and never one of its own (§15.4). *)
let frame_of time = int_of_float (Float.max 0.0 (Float.round (time *. 60.0)))

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"sizepolicy" ~width:480.0 ~height:420.0 ();

     let root =
       column
         [
           (* SCALE, the default: nothing is declared, and the core
              re-rasterizes this same display list at whatever track the
              column hands over, fitted uniformly and centred. *)
           canvas ~grow:1.0 ~a11y_id:"fit" ~a11y_label:"Scaled panel"
             ~viewbox:box ~draw:(fun d -> figure d box);
           (* FIXED: the one true property. This one draws at [box]
              whatever the column does with it, and the backend blits it
              1:1 with the leftover as margin. *)
           canvas ~grow:1.0 ~a11y_id:"mark" ~a11y_label:"Fixed mark"
             ~viewbox:box ~draw:(fun d -> figure d box) ~fixed:true;
           (* REDRAW: the drawing IS a function of size, and saying so is
              providing the function. The viewbox declared here is only
              the size before the first answer. *)
           canvas ~grow:1.0 ~a11y_id:"live" ~a11y_label:"Redrawn panel"
             ~viewbox:box ~on_draw:(fun d size -> figure d size);
           (* TICK: the same, once a frame, at the time the platform
              supplied. Under the harness that clock is the core's own
              step and a verb advances it. *)
           canvas ~grow:1.0 ~a11y_id:"clock" ~a11y_label:"Animated bar"
             ~viewbox:box
             ~on_tick:(fun d size time -> bar d size (frame_of time));
         ]
         ()
     in
     mount root);

  (* The asks arrive after the first layout; [run]'s dispatch loop
     answers them inside the binding's own transaction. *)
  exit (run app)
