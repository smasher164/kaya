(* The menus conformance scene, OCaml port: the command vocabulary (a
   File/View/Sort menu bar, context menus on a live label and on stamped
   rows), the uncontrolled-menu echo doctrine, and a late
   rename/append/promotion rework. Canonical semantics in
   guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let groups, items =
    build app (fun () ->
       let status = signal (Str "ready") in
       let can_export = signal (Bool false) in
       let details = signal (Bool false) in
       let sort = signal (F64 0.0) in

       let on_share () = write status (Str "shared") in

       (* File and its Export leaf share one enablement signal: one write
          moves both. File and Share realize early because the extend
          handler needs their handles; [w] slots them back in. *)
       let share = item ~label:"Share" ~primary:true ~on_activate:on_share () in
       let file =
         menu ~label:"File" ~bind_enabled:can_export
           [
             item ~label:"Save" ~shortcut:"primary+s"
               ~on_activate:(fun () -> write status (Str "saved"));
             item ~label:"Export" ~bind_enabled:can_export;
             w share;
           ]
           ()
       in
       window ~title:"menus"
         ~menus:
           [
             w file;
             menu ~label:"View"
               [
                 toggle ~label:"Details" ~bind_checked:details
                   ~on_toggle:(fun on ->
                     write status
                       (Str (if on then "details on" else "details off")));
               ];
             (* Option order IS the index vocabulary: Name = 0, Date = 1. *)
             radio_group ~label:"Sort" ~bind_value:sort
               ~on_select:(fun index ->
                 write status
                   (Str (if index = 1 then "sorted date" else "sorted name")))
               [ option ~label:"Name"; option ~label:"Date" ];
           ]
         ();

       let groups = collection () in
       let items_ref = ref None in
       (* Catalog built live: items are shared across stamped copies; the
          template only attaches. The Remove handler predates the items
          collection, so it reads it back through [items_ref]. *)
       let catalog =
         context_catalog
           [
             item ~label:"Remove"
               ~on_activate_node:(fun keys ->
                 match keys with
                 | [ Str group; Str item ] ->
                     remove (at (Option.get !items_ref) (Str group)) (Str item);
                     write status
                       (Str (Printf.sprintf "removed %s/%s" group item))
                 | _ -> ());
           ]
       in

       (* The group For escapes its items collection (the seed and the
          Remove handler need it); [w group_list] slots the live For into
          the root below. Remove's activation names BOTH keys (group, item). *)
       let group_list, items =
         for_each groups
           (fun () ->
             Tpl.(
               let items = collection () in
               let _ =
                 column
                   [
                     (* THE INNER FOR AS A CHILD. Its body keeps no
                        handle — the Remove handler hangs off the
                        catalog, not off a stamped node — so [each]
                        drops the result and the partial application
                        slots into this list like any constructor. The
                        [w item_list] line it replaces was there
                        because this zone had no [each] until now. *)
                     each items (fun () ->
                         (* label#2 once g2/a stamps. [element] is the
                            scalar collection's own token — its element
                            IS the value, so there is no field name to
                            give — and it lowers to the same
                            bind_element this line used to spell at the
                            widget-kind floor. *)
                         let row = label ~bind_field:element () in
                         context_menu row catalog);
                   ]
                   ()
               in
               items))
           ()
       in
       items_ref := Some items;

       let target_text = signal (Str "rename target") in
       let root =
         column
           [
             label ~bind:status (* label#0 *);
             button ~text:"enable export"
               ~on_click:(fun () -> write can_export (Bool true)) (* button#0 *);
             button ~text:"reset menu state"
               ~on_click:(fun () ->
                 (* The folds never echo the user's pick, so details/sort
                    still hold false/0; these two prop writes are real
                    checked/value records (never coalesced) that reset the
                    backend's user-state mirror. *)
                 write details (Bool false);
                 write sort (F64 0.0);
                 write status (Str "ready")) (* button#1 *);
             button ~text:"extend menus"
               ~on_click:(fun () ->
                 (* Append-only: rename the retained File, move the promotion
                    hint from Share to Publish, grow the bar by Tools. *)
                 set_menu_primary share false;
                 set_menu_label file "Document";
                 menu_append file
                   [ item ~label:"Publish" ~primary:true ~on_activate:on_share ];
                 window
                   ~menus:[ menu ~label:"Tools" [ item ~label:"Inspect" ] ]
                   ()) (* button#2 *);
             (fun () ->
               let target = label ~bind:target_text () (* label#1 *) in
               context_menu target
                 [
                   item ~label:"Rename"
                     ~on_activate:(fun () -> write status (Str "renamed"));
                 ];
               target);
             w group_list;
           ]
           ()
       in
       mount root;
       (groups, items))
  in

  (* Seed after mount: the stamp path attaches the shared catalog and keys. *)
  build app (fun () ->
     insert groups (Str "g2") (Str "Home");
     insert (at items (Str "g2")) (Str "a") (Str "water plants"));

  exit (run app)
