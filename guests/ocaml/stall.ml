(* The stall scene, OCaml port — guests/rust/stall.rs,
   tools/scenes/stall.steps. *)

open Kaya_wire
open Kaya_app

(* Past the watchdog's one-second threshold. *)
let block_seconds = 2.5

(* A day, never a literal park (docs/traps.md, the stall scene wedges for a
   DAY). *)
let wedge_seconds = 86400.

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"stall" ();
      let status = signal (Str "ready") in

      (* DELIBERATELY WRONG, and the only place in this repo that is. *)
      let block () = Thread.delay block_seconds in
      let ping () = write status (Str "pinged") in
      let wedge () = Thread.delay wedge_seconds in

      (* Children are THUNKS: omitting the trailing unit leaves one
         (DESIGN.md, Binding conventions). *)
      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            button ~text:"block" ~on_click:block (* button#0 *);
            button ~text:"ping" ~on_click:ping (* button#1 *);
            button ~text:"wedge" ~on_click:wedge (* button#2 *);
          ]
          ()
      in
      mount root);

  exit (run app)
