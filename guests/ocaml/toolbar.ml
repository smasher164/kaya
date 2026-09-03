(* The toolbar scene, OCaml port — guests/rust/toolbar.rs,
   tools/scenes/toolbar.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let save_enabled = ref true in

  build app (fun () ->
     let status = signal (Str "ready") in
     (* Written against the MENU ITEM: the promoted button IS that item. *)
     let can_save = signal (Bool true) in

     (* CATALOG PREORDER DECIDES PROMOTION — menubar-append order, then
        children depth-first, so every host promotes [Save, Find]. *)
     window ~title:"toolbar"
       ~menus:
         [
           menu ~label:"File"
             [
               (* No save-specific glyph in the vocabulary, nor in Apple's own
                  catalog; [Done] is the checkmark idiom (docs/styling-plan.md D6). *)
               item ~label:"Save" ~symbol:Done ~primary:true
                 ~bind_enabled:can_save ~shortcut:"primary+s"
                 ~on_activate:(fun () -> write status (Str "saved"));
               item ~label:"Export" ~symbol:Forward ~on_activate:(fun () ->
                   write status (Str "exported"));
             ];
           menu ~label:"Edit"
             [
               item ~label:"Find" ~symbol:Search ~primary:true
                 ~on_activate:(fun () -> write status (Str "found"));
               item ~label:"Replace" ~symbol:Edit;
             ];
           menu ~label:"View"
             [ item ~label:"Refresh" ~symbol:Refresh; item ~label:"Info" ~symbol:Info ];
         ]
       ();

     let root =
       column
         [
           label ~bind:status (* label#0 *);
           button ~text:"toggle save"
             ~on_click:(fun () ->
               save_enabled := not !save_enabled;
               write can_save (Bool !save_enabled)) (* button#0 *);
         ]
         ()
     in
     mount root);

  exit (run app)
