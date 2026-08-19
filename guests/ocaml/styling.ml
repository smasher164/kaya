(* The styling conformance scene, OCaml port — the brand accent, the
   role tier and the window inset, which are one design
   (docs/styling-plan.md slice 1).

   [brand_accent 0x3584E4] is Adwaita blue, the derivation's empirical
   anchor; one hex is the whole call. [~light]/[~dark] are the
   per-appearance form for a brand book that has one.

   A ROLE IS CHECKED AGAINST THE KIND at declare time — swap Destructive
   and Heading here and the scene dies — and pressing is unchanged.

   Canonical semantics in guests/rust/styling.rs; the byte-frozen
   contract is tools/scenes/styling.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
        not state, and the root refuses a second write or a late one. *)
     brand_accent 0x3584E4;
     window ~title:"styling" ~width:480.0 ~height:360.0 ~inset:0.0 ();

     let heading = signal (Str "Sections") in
     let status = signal (Str "ready") in

     let on_delete () = write status (Str "deleted") in
     let on_save () = write status (Str "saved") in

     let root =
       column
         [
           (* expect_ax resolves a target through its AUTHORED id into the
              real tree, so everything the script reads back is identified. *)
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
