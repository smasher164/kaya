(* The confirm conformance scene, OCaml port — the modal-alert
   grammar via labeled arguments (the request/result grammar's first
   client): one button re-shows a two-action alert; the three rounds
   take the three answer paths (action 0, action 1, [alert_cancel] —
   every platform-native dismissal), and the status label records
   each result. The result handler rides the REQUEST (~on_result,
   the widget-handler precedent) and retires with its one answer;
   ids are binding-allocated. See guests/rust/confirm.rs and
   tools/scenes/confirm.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app
    (let* () = window ~title:"confirm" () in
     let* s = signal (Str "no decision") in
     status := Some s;
     (* The result handler rides the request and retires with its
        one answer; ids are binding-allocated — no counter
        plumbing. *)
     let delete_answered choice tx =
       match !status with
       | Some s ->
           let text =
             if choice = alert_cancel then "kept"
             else if choice = 1 then "archived"
             else "deleted"
           in
           write s (Str text) tx
       | None -> ()
     in
     (* A different dialog, a different handler: the association is
        the registration itself. *)
     let eject_answered choice tx =
       match !status with
       | Some s ->
           write s (Str (if choice = alert_cancel then "held" else "ejected")) tx
       | None -> ()
     in
     let on_delete tx =
       ignore
         (show_alert ~title:"delete item?"
            ~message:"this cannot be undone"
            ~actions:[ "Delete"; "Archive" ] ~cancel:"Keep"
            ~on_result:delete_answered tx)
     in
     let on_eject tx =
       ignore
         (show_alert ~title:"eject disk?" ~message:"it is still mounted"
            ~actions:[ "Eject" ] ~cancel:"Hold" ~on_result:eject_answered tx)
     in
     let* root =
       column
         [
           label ~bind:s () (* label#0 *);
           button ~text:"delete" ~on_click:on_delete ();
           button ~text:"eject" ~on_click:on_eject ();
         ]
     in
     mount root);

  exit (run app)
