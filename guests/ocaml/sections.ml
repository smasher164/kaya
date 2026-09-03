(* The sections scene, OCaml port — guests/rust/sections.rs,
   tools/scenes/sections.steps. *)

open Kaya_wire
open Kaya_app

let feed = 7L
let archive = 8L

(* The SIDEBAR half rides an AUX WINDOW opened only from the desktop tail's
   click, so [create_window] never runs where the capability is absent. *)
let library = 1L
let shelves = 2L
let loans = 3L

let () =
  let app = Kaya_app.create () in

  let visit_count = ref 0 in
  build app (fun () ->
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
     (* A symbol names a CONCEPT (docs/styling-plan.md D6). *)
     add_section ~title:"Feed" ~symbol:Home feed;
     add_section ~title:"Archive" ~symbol:Star ~on_selected:on_archive_shown
       archive;
     let go_archive () =
       (* Programmatic selection does NOT echo: [~on_selected] must not fire. *)
       select_section archive
     in
     let open_library () =
       create_window ~title:"library"
         ~sections_presentation:
           (Int64.of_int Kaya_wire.sections_presentation_sidebar)
         library;
       add_section ~window:library ~title:"Shelves" ~symbol:Search shelves;
       add_section ~window:library ~title:"Loans" ~symbol:Lock loans;
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
