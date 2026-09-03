(* The menus scene, OCaml port — guests/rust/menus.rs,
   tools/scenes/menus.steps. *)

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

       let share = item ~label:"Share" ~primary:true ~on_activate:on_share () in
       let file =
         menu ~label:"File" ~bind_enabled:can_export
           [
             (* No `save` in the symbol vocabulary; [Done] is the checkmark
                idiom (docs/styling-plan.md D6). *)
             item ~label:"Save" ~symbol:Done ~shortcut:"primary+s"
               ~on_activate:(fun () -> write status (Str "saved"));
             item ~label:"Export" ~bind_enabled:can_export ~symbol:Forward;
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
                 toggle ~label:"Details" ~bind_checked:details ~symbol:Info
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
       (* One catalog shared across every stamped copy. [items_ref] is how
          the handler reaches a collection [for_each] has not returned yet. *)
       let catalog =
         context_catalog
           [
             item ~label:"Remove" ~symbol:Delete
               ~on_activate_node:(fun keys ->
                 match keys with
                 | [ Str group; Str item ] ->
                     remove (at (Option.get !items_ref) (Str group)) (Str item);
                     write status
                       (Str (Printf.sprintf "removed %s/%s" group item))
                 | _ -> ());
           ]
       in

       let group_list, items =
         for_each groups
           (fun () ->
             Tpl.(
               let items = collection () in
               let _ =
                 column
                   [
                     each items (fun () ->
                         (* label#2 once g2/a stamps. *)
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
                 write details (Bool false);
                 write sort (F64 0.0);
                 write status (Str "ready")) (* button#1 *);
             button ~text:"extend menus"
               ~on_click:(fun () ->
                 set_menu_primary share false;
                 set_menu_label file "Document";
                 menu_append file
                   [
                     item ~label:"Publish" ~primary:true ~symbol:Copy
                       ~on_activate:on_share;
                   ];
                 window
                   ~menus:
                     [
                       menu ~label:"Tools"
                         [ item ~label:"Inspect" ~symbol:Search ];
                     ]
                   ()) (* button#2 *);
             (fun () ->
               let target = label ~bind:target_text () (* label#1 *) in
               context_menu target
                 [
                   item ~label:"Rename" ~symbol:Edit
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

  (* Seeded after the mount, so the copy stamps from a closed template. *)
  build app (fun () ->
     insert groups (Str "g2") (Str "Home");
     insert (at items (Str "g2")) (Str "a") (Str "water plants"));

  exit (run app)
