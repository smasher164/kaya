(* The styling conformance scene, OCaml port — the brand accent, the
   role tier and the window inset, which are one design
   (docs/styling-plan.md slice 1): brand slots fill each platform's own
   token system, roles say what a widget MEANS, and the inset is the one
   layout knob the pass admitted.

   THREE OCAML SPELLINGS, ONE SEMANTICS.

   - [brand_accent 0x3584E4] — Adwaita blue, the derivation's empirical
     anchor. One hex is the whole call: the core derives the fills and
     the foregrounds, this app writes neither, and a platform may let
     its user override the result. [~light] and [~dark] are the
     per-appearance form for a brand book that has one; this scene has
     none, which is the common case the sugar is shaped for. It stands
     FIRST, before the mount, because brand is identity and the root
     refuses a second write or a late one.
   - [~role:Heading] on the title label and [~role:Destructive] /
     [~role:Prominent] on the two buttons — a labeled argument beside
     [~a11y_id], because a role is a property of the widget and not a
     wrapper around it. The kind is the root's judgement: swap the two
     and the scene dies at declare time.
   - [~inset:0.0] beside [~title] and the size, because the inset is
     LAYOUT. Full bleed is what the editor wants, and kaya's own padding
     is the only thing in the way, so 0 is honored everywhere.

   AND PRESSING THEM IS UNCHANGED, which is half of what the script
   asserts: a destructive button presses like any button, and this app's
   own handler is what acts.

   Canonical semantics in guests/rust/styling.rs; the byte-frozen
   contract is tools/scenes/styling.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* BEFORE THE FIRST MOUNT, per the set-once wall: brand is
        identity, not state. *)
     brand_accent 0x3584E4;
     window ~title:"styling" ~width:480.0 ~height:360.0 ~inset:0.0 ();

     let heading = signal (Str "Sections") in
     let status = signal (Str "ready") in

     let on_delete () = write status (Str "deleted") in
     let on_save () = write status (Str "saved") in

     let root =
       column
         [
           (* expect_ax resolves a target through its AUTHORED id into
              the real tree, so everything the script reads back is
              identified (the a11y scene's discipline). *)
           label ~role:Heading ~a11y_id:"title" ~bind:heading (* label#0 *);
           label ~bind:status (* label#1 *);
           button ~role:Destructive ~a11y_id:"delete" ~text:"Delete"
             ~on_click:on_delete (* button#0 *);
           button ~role:Prominent ~a11y_id:"save" ~text:"Save"
             ~on_click:on_save (* button#1 *);
         ]
         ()
     in
     mount root);

  exit (run app)
