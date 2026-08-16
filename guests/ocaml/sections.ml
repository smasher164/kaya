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

(* The SIDEBAR half of the presentation enum, in an AUX WINDOW so one
   shared scene covers BOTH arms: the primary stays `bar`, and this
   window opens from a handler only the desktop tail's click reaches —
   the phone runners cut the tail, the click never fires, and
   [create_window] never runs where the capability is absent. No
   capability read needed: reachability is the gate. *)
let library = 1L
let shelves = 2L
let loans = 3L

let () =
  let app = Kaya_app.create () in

  let visit_count = ref 0 in
  build app (fun () ->
     (* One construct carries the window's attributes (the
        unification rule). The hint is ADVISORY: `bar` is each
        desktop's horizontal spelling and the phones' physics
        regardless — no observable rides on it. *)
     let () =
       window ~title:"sections"
         ~sections_presentation:
           (Int64.of_int Kaya_wire.sections_presentation_bar)
         ()
     in
     let visits = signal (Str "archive: 0 visits") in
     let on_archive_shown () =
       incr visit_count;
       write visits
         (Str (Printf.sprintf "archive: %d visits" !visit_count))
        
     in
     add_section ~title:"Feed" feed;
     add_section ~title:"Archive" ~on_selected:on_archive_shown archive;
     let go_archive () =
       (* Programmatic selection: configuration, no echo —
          [~on_selected] must NOT fire (the scene asserts the count
          holds). *)
       select_section archive
     in
     let open_library () =
       create_window ~title:"library"
         ~sections_presentation:
           (Int64.of_int Kaya_wire.sections_presentation_sidebar)
         library;
       add_section ~window:library ~title:"Shelves" shelves;
       add_section ~window:library ~title:"Loans" loans;
       let shelves_ready = signal (Str "shelves ready") in
       let shelves_root =
         column [ label ~bind:shelves_ready (* label#2 *) ] ()
       in
       mount_in shelves shelves_root;
       let loans_ready = signal (Str "loans ready") in
       let loans_root = column [ label ~bind:loans_ready (* label#3 *) ] () in
       mount_in loans loans_root
     in
     let ready = signal (Str "feed ready") in
     let feed_root =
       column
         [
           label ~bind:ready (* label#0 *);
           button ~text:"to archive" ~on_click:go_archive (* button#0 *);
           button ~text:"open library" ~on_click:open_library (* button#1 *);
         ]
         ()
     in
     mount_in feed feed_root;
     let archive_root = column [ label ~bind:visits (* label#1 *) ] () in
     mount_in archive archive_root);

  exit (run app)
