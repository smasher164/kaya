(* The adaptive conformance scene, OCaml port — see guests/rust/adaptive.rs
   for the full rationale and tools/scenes/adaptive.steps for the
   byte-frozen contract. row@dash flips by a HANDLER (D2's user-driven
   toggle); row@narrow carries the ONE-LABEL breakpoint (D3):
   [~stack_below] stacks it vertically while the window is narrower than
   520 logical points and reverts crossing back.

   The two labels' naturals DIFFER on purpose: the flip then always moves
   the container's box, so the geometry reader re-records on every
   crossing. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* Explicit size: the desktop start must sit ABOVE the breakpoint's
        threshold so the scene's resize half crosses it both ways
        deterministically. *)
     window ~title:"adaptive" ~width:900.0 ~height:600.0 ();

     let alpha = signal (Str "alpha") in
     let longer = signal (Str "a longer label") in
     let steady = signal (Str "steady") in
     let one = signal (Str "one") in
     let two = signal (Str "a wider two") in

     (* row#0: the flip subject, realized ahead of the column because the
        handler needs its handle; [w] slots it into the child list. *)
     let dash =
       row ~a11y_id:"dash"
         [ label ~bind:alpha (* label#0 *); label ~bind:longer (* label#1 *) ]
         ()
     in
     let vertical = ref false in
     let flip () =
       vertical := not !vertical;
       set_axis dash (if !vertical then Vertical else Horizontal)
     in

     let root =
       column
         [
           w dash;
           (* column#1: the control group — its axis answers the creation
              kind's own and never moves. *)
           column ~a11y_id:"steady" [ label ~bind:steady (* label#2 *) ];
           button ~text:"flip" ~on_click:flip (* button#0 *);
           (* row#1: the BREAKPOINT subject (D3) — declared data,
              core-evaluated. The handler never touches it. *)
           row ~a11y_id:"narrow" ~stack_below:520.0
             [ label ~bind:one (* label#3 *); label ~bind:two (* label#4 *) ];
         ]
         ()
     in
     mount root);

  exit (run app)
