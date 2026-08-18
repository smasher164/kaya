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
        to it. *)
     let font_path =
       match Sys.getenv_opt "KAYA_FONT_FILE" with
       | Some path -> path
       | None -> "guests/assets/fonts/sora-wght.ttf"
     in
     let missing reason =
       failwith
         (Printf.sprintf
            "kaya: the typeface scene needs the vendored font at %s (set \
             KAYA_FONT_FILE or run from the repo root): %s" font_path reason)
     in
     let font =
       match open_in_bin font_path with
       | exception Sys_error msg -> missing msg
       | ic ->
         Fun.protect
           ~finally:(fun () -> close_in_noerr ic)
           (fun () ->
             let len = in_channel_length ic in
             let buf = Bytes.create len in
             match really_input ic buf 0 len with
             | () -> buf
             | exception End_of_file ->
               missing "the file ended before its stated length")
     in
     brand_typeface ~font "Sora";
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
