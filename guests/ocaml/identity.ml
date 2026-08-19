(* The app-identity conformance scene, OCaml port: an app declares what
   it is called and what it looks like, and the platform shows both.
   Canonical semantics in guests/rust/identity.rs; the byte-frozen
   contract in tools/scenes/identity.steps.

   THE MARK IS THE VENDORED ONE (four flat quadrants) because no
   platform's own default icon can land on four declared colours, so a
   lowering that never applied can never read as a pass.

   THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
   blank an app's NAME fills on every platform. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* The fold: widget-owned state arrives as occurrences, and the app's
     copy is this ref rather than a widget read. *)
  let draft = ref "" in

  build app (fun () ->
      (* BEFORE THE FIRST MOUNT, per the declared-once wall. The bytes
         never enter this guest's heap — the handle goes straight to the
         blob channel. [~icon_asset] rather than [~icon] because the two
         are exclusive: one icon slot on the wire. The close is explicit
         and the redemption has already happened by then. *)
     let icon = asset "icons/kaya-mark.png" in
     app_identity ~icon_asset:icon "Aurora Notes";
     asset_close icon;
     (* ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows mints
        its custom caption from the first promotion and from nothing else,
        and a custom caption REPLACES the system one — taking the
        system-drawn app icon with it. That is why the identity has a
        second Windows sink at all, and a scene with no promotion anywhere
        would leave that sink's arm unreached. *)
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

      (* THE UNTITLED WINDOW. It declares no title at all rather than an
         empty one: an empty string is a title an app WROTE, and the rule
         under test is what a window with nothing written shows.

         THE HOST IS ASKED, in all eight ports of this scene, even where
         the answer is never no: the eight ports are one scene, and a
         binding surface no guest calls is one no lane exercises. *)
     if (capabilities ()).aux_windows then begin
       create_window ~width:360.0 ~height:240.0 1L;
       let caption = signal (Str "no title of its own") in
       let aux = column [ label ~bind:caption (* label#2 *) ] () in
       mount_in 1L aux
     end);

  exit (run app)
