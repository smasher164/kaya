(* The sheet scene, OCaml port — guests/rust/sheet.rs, tools/scenes/sheet.steps. *)

open Kaya_app

let task = 11L
let details = 12L

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"sheet" ();
     let status = signal Scalar.Str "closed" in
     let draft = signal Scalar.Str "draft: none" in
     let open_details () =
       present_sheet ~parent:task ~title:"details"
         ~on_dismissed:(fun () -> write status "details dismissed")
         details;
       let more = signal Scalar.Str "more about it" in
       let pane = column [ label ~bind:more ] () in
       mount_in details pane;
       write status "details open"
     in
     let done_ () =
       (* Programmatic: no sheet_dismissed follows, so "done" stays. *)
       dismiss_sheet task;
       write status "done"
     in
     let open_task armed () =
       (* Nothing has gone when the request fires; the app keeps the sheet
          up and says so. *)
       let on_ask =
         if armed then Some (fun () -> write status "dismiss requested")
         else None
       in
       present_sheet ~title:"new task" ~detent:Detent.Medium
         ~intercept_dismiss:armed
         ~on_dismissed:(fun () -> write status "dismissed")
         ?on_dismiss_requested:on_ask task;
       let caption = signal Scalar.Str "what needs doing?" in
       let field =
         entry ~on_change:(fun text -> write draft ("draft: " ^ text)) ()
       in
       let body =
         column
           [
             label ~bind:caption (* label#1 *);
             w field (* entry#0 *);
             label ~bind:draft (* label#2 *);
             button ~text:"details" ~on_click:open_details (* button#2 *);
             button ~text:"done" ~on_click:done_ (* button#3 *);
           ]
           ()
       in
       mount_in task body;
       write status "open";
       write draft "draft: none"
     in
     let root =
       column
         [
           label ~bind:status (* label#0 *);
           button ~text:"new task" ~on_click:(open_task false);
           button ~text:"new task, armed" ~on_click:(open_task true);
         ]
         ()
     in
     mount root);

  exit (run app)
