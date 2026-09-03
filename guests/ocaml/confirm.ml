(* The confirm scene, OCaml port — guests/rust/confirm.rs,
   tools/scenes/confirm.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app (fun () ->
     window ~title:"confirm" ();
     let s = signal (Str "no decision") in
     status := Some s;
     let delete_answered choice =
       match !status with
       | Some s ->
           let text =
             if choice = alert_cancel then "kept"
             else if choice = 1 then "archived"
             else "deleted"
           in
           write s (Str text)
       | None -> ()
     in
     let eject_answered choice =
       match !status with
       | Some s ->
           write s (Str (if choice = alert_cancel then "held" else "ejected"))
       | None -> ()
     in
     let on_delete () =
       ignore
         (show_alert ~title:"delete item?"
            ~message:"this cannot be undone"
            ~actions:[ "Delete"; "Archive" ] ~cancel:"Keep"
            ~on_result:delete_answered ())
     in
     let on_eject () =
       ignore
         (show_alert ~title:"eject disk?" ~message:"it is still mounted"
            ~actions:[ "Eject" ] ~cancel:"Hold" ~on_result:eject_answered ())
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
