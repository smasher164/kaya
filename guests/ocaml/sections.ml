(* The sections conformance scene, OCaml port: two peer roots in the
   primary window's section set — presentation context, not
   lifecycle. The archive pane folds [~on_selected] into a visit
   count, pinning the echo doctrine from both sides: the user's
   switch emits (the harness drives the real switcher), while the
   feed button's programmatic [select_section] moves the selection
   silently. The count surviving switch round trips proves retention.
   See guests/rust/sections.rs and tools/scenes/sections.steps. *)

open Kaya_wire
open Kaya_app

let feed = 7L
let archive = 8L

let () =
  let app = Kaya_app.create () in

  let visit_count = ref 0 in
  build app
    (let* () = window_title "sections" in
     (* The ADVISORY hint, exercised on the wire: `bar` is each
        desktop's horizontal spelling and the phones' physics
        regardless — no observable rides on it. *)
     let* () =
       fun tx ->
        sections_presentation
          (Int64.of_int Kaya_wire.sections_presentation_bar)
          tx
     in
     let* visits = signal (Str "archive: 0 visits") in
     let on_archive_shown tx =
       incr visit_count;
       write visits
         (Str (Printf.sprintf "archive: %d visits" !visit_count))
         tx
     in
     let* () =
      fun tx ->
       add_section ~title:"Feed" feed tx;
       add_section ~title:"Archive" ~on_selected:on_archive_shown archive tx
     in
     let go_archive tx =
       (* Programmatic selection: configuration, no echo —
          [~on_selected] must NOT fire (the scene asserts the count
          holds). *)
       select_section archive tx
     in
     let* feed_root =
       column
         [
           (let* ready = signal (Str "feed ready") in
            label ~bind:ready () (* label#0 *));
           button ~text:"to archive" ~on_click:go_archive () (* button#0 *);
         ]
     in
     let* () = mount_in feed feed_root in
     let* archive_root = column [ label ~bind:visits () (* label#1 *) ] in
     mount_in archive archive_root);

  exit (run app)
