(* The restored shape, OCaml port — guests/rust/restoredocs.rs,
   tools/scenes/restoredocs.steps (docs/restoration-plan.md SR9): each
   document's title and text live in its own session scope, and act two
   recreates the documents the last launch left, takes each scope back, and
   selects the active one. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  let documents, active =
    match List.find_opt (fun w -> w.id = 0L) (restored_windows ()) with
    | Some w -> (w.documents, w.active_document)
    | None ->
        let first = [ (10L, "a"); (11L, "b"); (12L, "c") ] in
        List.iter (fun (id, title) -> (document_session id).set_string "title" title) first;
        (List.map fst first, 0L)
  in

  build app (fun () ->
      window ~title:"restoredocs" ~width:640.0 ~height:420.0 ();
      List.iter
        (fun id ->
          let scope = document_session id in
          let title = scope.get_string "title" "untitled" in
          add_document ~title ~restore:id id;
          let caption = signal Scalar.Str (title ^ " body") in
          mount_in id
            (column
               [
                 (fun () -> label ~a11y_id:("caption-" ^ title) ~bind:caption ());
                 (fun () ->
                   let field =
                     entry ~a11y_id:("body-" ^ title)
                       ~on_change:(fun text -> scope.set_string "body" text)
                       ()
                   in
                   set_text field (scope.get_string "body" "");
                   field);
                 (fun () ->
                   button ~a11y_id:("recall-" ^ title) ~text:"recall"
                     ~on_click:(fun () ->
                       write caption ((document_session id).get_string "title" "untitled" ^ " body"))
                     ());
               ]
               ()))
        documents;
      if active <> 0L then select_document active);
  exit (run app)
