(* The row menu scene, OCaml port — guests/rust/rowmenu.rs,
   tools/scenes/rowmenu.steps (docs/media-player-plan.md M26). *)

open Kaya_app

type rowmenu_entry = { title : string; mark : string; plain : bool } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"rowmenu" ();
     let status = signal Scalar.Str "ready" in
     let hide = signal Scalar.Bool true in
     let notes = collection_of rowmenu_entry_record in
     let files = collection_of rowmenu_entry_record in
     let toggle c on off did undid keys =
       match keys with
       | [ Key.Str key ] ->
           let set =
             match record_get c (Key.str key) with
             | Some entry -> entry.mark = on
             | None -> false
           in
           update_field c (Key.str key) rowmenu_entry_mark (if set then off else on);
           update_field c (Key.str key) rowmenu_entry_plain (not set);
           write status (Printf.sprintf "%s %s" (if set then did else undid) key)
       | _ -> ()
     in
     let open_row keys =
       match keys with
       | [ Key.Str key ] -> write status (Printf.sprintf "opened %s" key)
       | _ -> ()
     in
     let star =
       item ~label:"Star" ~on_activate_node:(toggle notes "Star" "Unstar" "starred" "unstarred") ()
     in
     let note_menu =
       context_catalog
         [ w star; separator; item ~label:"Open" ~on_activate_node:open_row ]
     in
     let pin =
       item ~label:"Pin" ~on_activate_node:(toggle files "Pin" "Unpin" "pinned" "unpinned") ()
     in
     let file_menu =
       context_catalog
         [ w pin; separator; item ~label:"Open" ~on_activate_node:open_row ]
     in
     let note_list, _ =
       for_each (record_handle notes)
         (fun () ->
           Tpl.(
             let flag () =
               let n = caption ~bind_field:rowmenu_entry_mark ~a11y_id:"flag" () in
               bind_hidden_field n rowmenu_entry_plain;
               n
             in
             let body =
               column
                 [ label ~bind_field:rowmenu_entry_title ~a11y_id:"title"; flag;
                   caption ~bind_field:rowmenu_entry_title ~a11y_id:"foot" ]
             in
             let line = row ~a11y_id:"note" [ body ] () in
             context_menu line note_menu;
             context_label line star rowmenu_entry_mark;
             line))
         ()
     in
     let table, _ =
       for_each (record_handle files)
         (fun () ->
           Tpl.(
             let line = row ~a11y_id:"file" [ label ~bind_field:rowmenu_entry_title ] () in
             context_menu line file_menu;
             context_label line pin rowmenu_entry_mark;
             line))
         ()
     in
     set_grow table 1.0;
     columns table [ "Name" ] sort_none;
     let b () =
       let b = label ~text:"B" ~a11y_id:"vb" () in
       bind_hidden b hide;
       b
     in
     let pair () =
       row
         [ column [ label ~text:"A" ~a11y_id:"va"; b; label ~text:"C" ~a11y_id:"vc" ];
           button ~text:"Show B" ~a11y_id:"show" ~on_click:(fun () -> write hide false) ]
         ()
     in
     let root = column [ label ~bind:status; pair; w note_list; w table ] () in
     mount root;
     insert_record notes (Key.str "a") { title = "apples"; mark = "Star"; plain = true };
     insert_record notes (Key.str "b") { title = "bread"; mark = "Unstar"; plain = false };
     insert_record files (Key.str "x") { title = "x.txt"; mark = "Pin"; plain = true };
     insert_record files (Key.str "y") { title = "y.txt"; mark = "Unpin"; plain = false });

  exit (run app)
