(* The typeface conformance scene, OCaml port — the brand typeface swaps
   the FAMILY and leaves the platform's ramp alone (docs/styling-plan.md
   Slice 2b). The scene names no size anywhere: sizes, weights and
   metrics stay the platform's, and the role tier carries emphasis
   ([~role:Heading] on the title label below).

   WHY A BUNDLED FONT, and why no [~platforms] row: the canonical note is
   guests/rust/typeface.rs's doc comment. In short, the scene requests the
   VENDORED font's bytes so the resolved family is one string on every
   lane and no platform's fallback can equal it. [~font] is OCaml's
   spelling of the blob form.

   The byte-frozen contract is tools/scenes/typeface.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences, and the app's
     copy is this ref rather than a widget read. *)
  let draft = ref "" in

  build app (fun () ->
     (* The typeface is set BEFORE THE FIRST MOUNT, per the set-once wall:
        brand is identity, not state. The blob registers with the
        platform's app-font machinery and the "Sora" request then resolves
        to it.

        ONE CALL, AND NO FILE I/O IN THE GUEST. The path, the environment
        override and the sentence for a miss were all hand-written here
        (and in seven sibling scenes) until [asset] arrived; they live in
        the core now (crates/kaya/src/assets.rs), which is also why the
        bytes never enter this guest's heap — the handle goes straight to
        the blob channel. The close is explicit and the redemption has
        already happened by then: [brand_typeface] registered the bytes
        into the pending blob table, which keeps its own reference. *)
     let font = asset "fonts/sora-wght.ttf" in
     brand_typeface ~font_asset:font "Sora";
     asset_close font;
     window ~title:"typeface" ~width:480.0 ~height:360.0 ();

     let heading = signal (Str "typeface") in
     let status = signal (Str "ready") in

     let root =
       column
         [
           (* The heading's text style OVERRIDES the root font, so this label
              is the one a root-only lowering leaves in the system face;
              expect_ax resolves it through its authored id. *)
           label ~role:Heading ~a11y_id:"title" ~bind:heading (* label#0 *);
           label ~bind:status (* label#1 *);
           (* Both a field and a textarea: they take the swap by DIFFERENT
              routes (the field inherits the root font, the textarea names its
              own ramp rung), so one alone could not tell a half-applied
              lowering from a whole one. *)
           entry ~on_change:(fun text -> draft := text) (* entry#0 *);
           textarea (* textarea#0 *);
           button ~text:"Go"
             ~on_click:(fun () ->
               write status (Str (Printf.sprintf "clicked %s" !draft)))
             (* button#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
