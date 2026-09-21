(* The confirm scene, OCaml port — guests/rust/confirm.rs,
   tools/scenes/confirm.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"confirm" ();
     let s = signal Scalar.Str ("no decision") in
     let delete_answered choice =
       let text =
         if choice = Alert_choice.Cancel then "kept"
         else if choice = Alert_choice.Action1 then "archived"
         else "deleted"
       in
       write s (text)
     in
     let eject_answered choice =
       write s ((if choice = Alert_choice.Cancel then "held" else "ejected"))
     in
     let on_delete () =
       let* choice =
         show_alert ~title:"delete item?" ~message:"this cannot be undone"
           ~actions:[ "Delete"; "Archive" ] ~cancel:"Keep" ()
       in
       delete_answered choice
     in
     let on_eject () =
       let* choice =
         show_alert ~title:"eject disk?" ~message:"it is still mounted"
           ~actions:[ "Eject" ] ~cancel:"Hold" ()
       in
       eject_answered choice
     in
     let root =
       column
         [
           label ~bind:s (* label#0 *);
           button ~text:"delete" ~on_click:on_delete;
           button ~text:"eject" ~on_click:on_eject;
         ]
         ()
     in
     mount root);

  exit (run app)
