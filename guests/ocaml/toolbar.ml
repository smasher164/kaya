(* The toolbar conformance scene, OCaml port: the [primary] bit as real
   window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
   and marks two actions primary; every host promotes the same first two
   in catalog preorder — the desktop's toolbar, the phones' top bar — and
   the rest of the catalog stays reachable where that host keeps it.
   There is no toolbar vocabulary to spell, which is the point.

   Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
   contract in tools/scenes/toolbar.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* The guest's own copy of the enablement: the signal is the model, and
     this ref is only what "the other one" means. *)
  let save_enabled = ref true in

  build app (fun () ->
     let status = signal (Str "ready") in
     (* The app writes enablement against the MENU ITEM and says nothing
        about any button: the promoted button IS that item, so it follows
        or the lowering kept a copy. *)
     let can_save = signal (Bool true) in

     (* CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
        menubar-append order, then each node's children in append order,
        depth-first. Save is the first primary and Find the second, so
        every host's promoted set is [Save, Find] however large its own
        k is. *)
     window ~title:"toolbar"
       ~menus:
         [
           menu ~label:"File"
             [
               (* [Done] is the checkmark idiom: the vocabulary has no
                  save-specific glyph, and neither does Apple's own catalog
                  (docs/styling-plan.md D6). *)
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
