(* The identity scene, OCaml port — guests/rust/identity.rs,
   tools/scenes/identity.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let draft = ref "" in

  build app (fun () ->
      (* BEFORE THE FIRST MOUNT, per the declared-once wall. [~icon_asset]
         rather than [~icon]: one icon slot on the wire. *)
     let icon = asset "icons/kaya-mark.png" in
     app_identity ~icon_asset:icon "Aurora Notes";
     asset_close icon;
     (* ONE PROMOTED COMMAND, and not about commands: Windows mints its
        custom caption from the first promotion, taking the system icon. *)
     window ~title:"identity" ~width:480.0 ~height:360.0
       ~menus:[ menu ~label:"File" [ item ~label:"Save" ~symbol:Done ~primary:true ] ]
       ();

     let heading = signal (Str "identity") in
     let status = signal (Str "ready") in

     let root =
       column
         [
           label ~bind:heading (* label#0 *);
           label ~bind:status (* label#1 *);
           entry ~on_change:(fun text -> draft := text) (* entry#0 *);
           button ~text:"Go"
             ~on_click:(fun () ->
               write status (Str (Printf.sprintf "clicked %s" !draft)))
             (* button#0 *);
         ]
         ()
     in
     mount root;

      (* No title at all rather than an empty one: an empty string is a
         title an app WROTE. *)
     if (capabilities ()).aux_windows then begin
       create_window ~width:360.0 ~height:240.0 1L;
       let caption = signal (Str "no title of its own") in
       let aux = column [ label ~bind:caption (* label#2 *) ] () in
       mount_in 1L aux
     end);

  exit (run app)
