(* The toolbar conformance scene, OCaml port: the [primary] bit as real
   window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
   and marks two actions primary; every host promotes the same first two
   in catalog preorder — the desktop's toolbar, the phones' top bar —
   and the rest of the catalog stays reachable where that host keeps it.

   There is no toolbar vocabulary to spell here, and that is the point:
   this guest is the menus guest with a promotion bit and no new call.
   Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
   contract in tools/scenes/toolbar.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* The guest's own copy of the enablement, flipped by the button. The
     signal is the model; this ref is only what "the other one" means. *)
  let save_enabled = ref true in

  build app (fun () ->
     let status = signal (Str "ready") in
     (* The one signal the enablement round-trip turns on. The app writes
        it against the MENU ITEM and says nothing about any button: the
        promoted button is that same item, so it follows or the lowering
        kept a copy. *)
     let can_save = signal (Bool true) in

     (* CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
        menubar-append order, then each node's children in append order,
        depth-first. Save is the first primary and Find the second, so
        every host's promoted set is [Save, Find] however large its own k
        is. *)
     window ~title:"toolbar"
       ~menus:
         [
           menu ~label:"File"
             [
               (* [Done] is the checkmark idiom: the vocabulary has no
                  save-specific glyph, and neither does Apple's own
                  catalog (docs/styling-plan.md D6). *)
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
               (* The remainder: everything below is catalog, not chrome,
                  on every platform — which is what makes the bare
                  expect_toolbar's second half a real question. *)
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
