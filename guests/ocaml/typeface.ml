(* The typeface conformance scene, OCaml port — the brand typeface swaps
   the FAMILY and leaves the platform's ramp alone
   (docs/styling-plan.md Slice 2b).

   ONE CALL IS THE WHOLE SURFACE — a family name, plus the per-platform
   rows a lane needs — and everything after it is ordinary widgets,
   which is the claim the scene makes: a typeface is chrome, so the
   field still takes text and the button still fires. What it does NOT
   do is name a size anywhere. Sizes, weights and metrics stay the
   platform's; the role tier is what carries emphasis ([~role:Heading]
   on the title label below), and that is exactly what makes a family
   swap safe.

   WHY A BUNDLED FONT, and why no [~platforms] row: the reasoning is in
   guests/rust/typeface.rs's doc comment, which is the canonical note
   for this scene. In short, the scene requests the VENDORED font's
   bytes so the resolved family is one string on every lane and no
   platform's fallback can equal it. [~font] is OCaml's spelling of the
   blob form; [~platforms] is what a name-based app would reach for
   instead, and this scene needs none.

   The byte-frozen contract is tools/scenes/typeface.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences, and the app's
     copy is this ref rather than a widget read. *)
  let draft = ref "" in

  build app (fun () ->
     (* BEFORE THE FIRST MOUNT, per the set-once wall: brand is
        identity, not state, and a backend never sees a typeface it
        would have to un-apply.
        THE VENDORED BYTES, then the family they carry: the blob
        registers with the platform's app-font machinery and the "Sora"
        request resolves to it — register-then-resolve, the same call a
        brand book's licensed font would make. *)
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
           (* The heading's text style OVERRIDES the root font, so this
              label is the one a root-only lowering leaves in the system
              face. expect_ax resolves it through its authored id, the
              a11y scene's discipline. *)
           label ~role:Heading ~a11y_id:"title" ~bind:heading (* label#0 *);
           label ~bind:status (* label#1 *);
           (* A FIELD AND A TEXTAREA, because they are the two views the
              observation reads (NSTextField and NSTextView on this
              platform) and they arrive by DIFFERENT routes: the field
              inherits the root font, the textarea names its own ramp
              rung and takes the swap explicitly. A scene with one of
              them could not tell a half-applied lowering from a whole
              one. *)
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
