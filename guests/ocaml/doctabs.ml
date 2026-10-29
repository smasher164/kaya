(* The document-tabs scene, OCaml port — guests/rust/doctabs.rs,
   tools/scenes/doctabs.steps (docs/doctabs-plan.md §5): three documents, one
   armed against a close, a shared region beside them, the "+", and a
   programmatic select that echoes nothing. *)

open Kaya_app

let doc_a = 10L
let doc_b = 11L
let doc_c = 12L
let notes = 30L
let names = [ (doc_a, "a"); (doc_b, "b"); (doc_c, "c") ]

let () =
  let app = Kaya_app.create () in
  let untitled = ref 0L in
  let regions = ref 0L in

  build app (fun () ->
     let status = signal Scalar.Str "ready" in

     (* THE ONE BUILDER every window's shared region comes from, the first
        window's and a torn-out one's alike (docs/doctabs-plan.md §1.2). *)
     let region window id =
       add_region ~window id Region_edge.Leading;
       mount_in id
         (column
            [
              (fun () -> label ~a11y_id:"status" ~bind:status ());
              (fun () -> entry ~a11y_id:"note" ());
              (fun () -> button ~a11y_id:"first" ~text:"to a" ~on_click:(fun () -> select_document doc_a) ());
            ]
            ())
     in

     let on_new_document () =
       untitled := Int64.add !untitled 1L;
       let name = Printf.sprintf "untitled %Ld" !untitled in
       let id = Int64.add 100L !untitled in
       add_document ~title:name id;
       select_document id;
       let caption = signal Scalar.Str (name ^ " body") in
       mount_in id (column [ (fun () -> label ~bind:caption ()) ] ());
       write status ("new " ^ name)
     in
     let on_documents_detached window documents =
       regions := Int64.add !regions 1L;
       region window (Int64.add 300L !regions);
       let moved =
         List.map
           (fun d -> Option.value (List.assoc_opt d names) ~default:"untitled")
           documents
       in
       write status ("detached " ^ String.concat " " moved)
     in
     window ~title:"doctabs" ~width:640. ~height:420. ~new_document:true ~on_new_document
       ~on_documents_close_requested:(fun documents ->
         write status (Printf.sprintf "asked about %d" (List.length documents)))
       ~on_documents_detached ();

     let ask_close () =
       let* choice =
         show_alert ~title:"unsaved changes" ~message:"b has unsaved changes"
           ~actions:[ "Discard" ] ~cancel:"Keep Editing" ()
       in
       if choice = Alert_choice.Cancel then write status "kept b"
       else begin
         close_document doc_b;
         write status "discarded b"
       end
     in
     List.iter
       (fun (id, name) ->
         let armed = id = doc_b in
         add_document ~title:name ~tooltip:("/documents/" ^ name)
           ?intercept_close:(if armed then Some true else None)
           ~on_selected:(fun () -> write status ("selected " ^ name))
           ?on_close_requested:(if armed then Some ask_close else None)
           ~on_closed:(fun () -> write status ("closed " ^ name))
           ~on_moved:(fun _ index -> write status (Printf.sprintf "moved %s to %d" name index))
           id;
         let caption = signal Scalar.Str (name ^ " body") in
         let mark () =
           update_document ~dirty:true doc_b;
           write status "marked b"
         in
         mount_in id
           (column
              ([ (fun () -> label ~a11y_id:("body-" ^ name) ~bind:caption ()); (fun () -> entry ~a11y_id:("field-" ^ name) ()) ]
              @ if armed then [ (fun () -> button ~a11y_id:"mark" ~text:"mark b" ~on_click:mark ()) ] else [])
              ()))
       names;
     region 0L notes);

  exit (run app)
