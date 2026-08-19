(* The dirty-state conformance scene, OCaml port — unsaved work as
   window chrome (docs/dirty-plan.md). The app declares STATE and the
   backend spells its platform's own affordance.

   TWO DECLARATIONS, ON PURPOSE: kaya does not watch your signals and
   guess. An edit writes the document AND says [~dirty:true].

   SETTING IT LATER IS THE CONSTRUCT AGAIN — there is no loose setter.

   Canonical semantics in guests/rust/dirty.rs; the byte-frozen contract
   in tools/scenes/dirty.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let doc = signal (Str "notes") in
     let status = signal (Str "saved") in

     let on_edit () =
       write doc (Str "notes and a line");
       write status (Str "unsaved");
       window ~dirty:true ()
     in
     let on_save () =
       write status (Str "saved");
       window ~dirty:false ()
     in

     (* The choice is an action index or [alert_cancel], every
        platform-native dismissal. NOTHING HAS EVER RUN THE DISCARD ARM:
        [destroy_window 0L] is refused by assertion and aborts the
        process (docs/traps.md, "An app can VETO a close but cannot AGREE
        to one"), so the scene answers cancel. *)
     let close_answered choice =
       if choice = alert_cancel then write status (Str "kept editing")
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

     (* [~dirty] and [~veto_close] are orthogonal — either rides the
        construct without the other. No [~dirty] here: the default false
        is what the script's first assertion reads. *)
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
