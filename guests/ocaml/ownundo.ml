(* The app-owned undo scene, OCaml port — guests/rust/ownundo.rs,
   tools/scenes/ownundo.steps (docs/rich-text-plan.md R6, §14). *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  (* THE APP'S OWN HISTORY: the document before each user edit, and the
     documents an undo took away. The binding's mirror is the document
     AFTER the edit it just delivered. *)
  let undo = ref [] in
  let redo = ref [] in
  let current = ref (Document.create "") in

  build app (fun () ->
      let status = signal_str ("undo 0 redo 0") in

      let native =
        textarea ~rich:true ~a11y_id:"native" ~a11y_label:"Native" ()
      in
      let owned =
        textarea ~rich:true ~own_undo:true ~a11y_id:"owned"
          ~a11y_label:"Owned" ()
      in

      let publish () =
        write status
          (Printf.sprintf "undo %d redo %d" (List.length !undo)
             (List.length !redo));
        can_undo owned (!undo <> []);
        can_redo owned (!redo <> [])
      in

      on_edit app owned (fun _ ->
          undo := !current :: !undo;
          current := document owned;
          redo := [];
          publish ());

      let on_undo () =
        match !undo with
        | [] -> ()
        | before :: rest ->
            undo := rest;
            redo := !current :: !redo;
            current := before;
            set_document owned before;
            publish ()
      in
      let on_redo () =
        match !redo with
        | [] -> ()
        | after :: rest ->
            redo := rest;
            undo := !current :: !undo;
            current := after;
            set_document owned after;
            publish ()
      in

      window ~title:"ownundo"
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Undo" ~role:Menu_role.Undo ~on_activate:on_undo;
                item ~label:"Redo" ~role:Menu_role.Redo ~on_activate:on_redo;
              ];
          ]
        ();

      mount
        (column
           [
             label ~a11y_id:"status" ~bind:status (* label#0 *);
             w native (* textarea#0 *);
             w owned (* textarea#1 *);
             row
               [
                 (* button#0 *)
                 button ~text:"focus native" ~on_click:(fun () -> focus native);
                 (* button#1 *)
                 button ~text:"focus owned" ~on_click:(fun () -> focus owned);
               ];
           ]
           ()));

  exit (run app)
