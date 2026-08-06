(* The dirty-state conformance scene, OCaml port — unsaved work as
   window chrome (docs/dirty-plan.md). One labelled argument beside
   [~title] and [~veto_close]: the app declares STATE and the backend
   spells its platform's own affordance (the dot in the close button on
   macOS, a leading [*] in the rendered caption on Windows, a bullet in
   the GTK header bar, nothing on the phones, which have none).

   TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
   [~dirty:true]; saving writes it back and says [~dirty:false]. kaya
   does not watch your signals and guess — "the document has unsaved
   changes" is a statement only the app can make, and the window
   construct is where it makes it.

   THE OCAML SPELLING OF SETTING IT LATER IS THE CONSTRUCT AGAIN. There
   is no loose setter — no window attribute lives outside [window] — and
   none is needed: a handler in an ambient binding ALREADY is a
   transaction, so [window ~dirty:true ()] inside one rides it, next to
   the [write]s, and the three statements the edit makes land together.

   AND THE MARK ARMS NOTHING. The close attempt fires the veto class this
   window already opted into, the app opens its own alert, and cancelling
   keeps the window with the mark still up. That flow is composed out of
   parts that predate this prop — which is the whole reason [~dirty] is
   presentation and nothing else.

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
       (* ONE TRANSACTION, THREE STATEMENTS. The document changed, the
          app's own status says so, and the window is declared dirty —
          none of the three implies either of the others. *)
       write doc (Str "notes and a line");
       write status (Str "unsaved");
       window ~dirty:true ()
     in
     let on_save () =
       write status (Str "saved");
       window ~dirty:false ()
     in

     (* The answer rides the request (~on_result) and retires with it;
        the choice is an action index or [alert_cancel], which is every
        platform-native dismissal. Agreeing destroys the surface, which
        for the PRIMARY window is the process itself — so the scene
        answers cancel and this arm stays the honest spelling of "yes,
        close it" rather than a step. Answering a dialog is not saving:
        the mark stays up either way. *)
     let close_answered choice =
       if choice = alert_cancel then write status (Str "kept editing")
       else destroy_window 0L
     in
     (* Nothing has closed: the veto class says so. An editor with
        unsaved work asks; a clean one agrees at once. *)
     let on_close_requested () =
       ignore
         (show_alert ~title:"unsaved changes"
            ~message:"the document has unsaved changes"
            ~actions:[ "Discard" ] ~cancel:"Keep Editing"
            ~on_result:close_answered ())
     in

     (* [~dirty] and [~veto_close] are orthogonal — either rides the
        construct without the other, on every platform. This window takes
        the veto because it is an editor: it owns its close so it can
        ask. It does NOT take ~dirty here; the default false is what the
        script's first assertion reads.

        The close handler binds to THE WINDOW at its declaration
        (handlers scope to the thing that creates them): it can only ever
        mean this surface's close was asked for. *)
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
