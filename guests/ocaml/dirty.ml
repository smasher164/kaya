(* The dirty scene, OCaml port — guests/rust/dirty.rs,
   tools/scenes/dirty.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let doc = signal_str ("notes") in
     let status = signal_str ("saved") in

     let on_edit () =
       write doc ("notes and a line");
       write status ("unsaved");
       window ~dirty:true ()
     in
     let on_save () =
       write status ("saved");
       window ~dirty:false ()
     in

     (* NOTHING HAS EVER RUN THE DISCARD ARM: [destroy_window 0L] aborts
        the process (docs/traps.md, VETO a close but never AGREE). *)
     let close_answered choice =
       if choice = alert_cancel then write status ("kept editing")
       else destroy_window 0L
     in
     (* Nothing has closed yet: the veto class says so. *)
     let on_close_requested () =
       ignore
         (show_alert ~title:"unsaved changes"
            ~message:"the document has unsaved changes"
            ~actions:[ "Discard" ] ~cancel:"Keep Editing"
            ~on_result:close_answered ())
     in

     (* No [~dirty] here: the default false is the first assertion. *)
     window ~title:"dirty" ~veto_close:true ~on_close_requested ();

     let root =
       column
         [
           label ~bind:doc (* label#0 *);
           label ~bind:status (* label#1 *);
           button ~text:"edit" ~on_click:on_edit (* button#0 *);
           button ~text:"save" ~on_click:on_save (* button#1 *);
         ]
         ()
     in
     mount root);

  exit (run app)
