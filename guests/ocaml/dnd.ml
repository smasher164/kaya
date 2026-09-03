(* The drag-and-drop scene, OCaml port — guests/rust/dnd.rs,
   tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
   reorderable For's container. *)

open Kaya_wire
open Kaya_app

type item = { title : string } [@@deriving kaya_gen]

let note_id = "dev.kaya/note"

let word = function
  | Some Op.Copy -> "copy"
  | Some Op.Move -> "move"
  | None -> "none"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let items = collection_of item_record in
      let drop_status = signal (Str "no drop yet") in
      let drag_status = signal (Str "no drag yet") in
      let source_text = signal (Str "hello") in
      let text_target = signal (Str "text target") in
      let note_target = signal (Str "note target") in
      let files_target = signal (Str "files target") in
      let source = ref None in
      let list = ref None in

      let dropped name target (d : dropped) =
        let op = word d.operation in
        (match d.clip with
        | Some (Text text) ->
            write drop_status (Str (Printf.sprintf "%s got text %s (%s)" name text op));
            write target (Str text)
        | Some (Custom (id, body)) ->
            write drop_status
              (Str
                 (Printf.sprintf "%s got %s %d bytes (%s)" name id
                    (String.length body) op))
        | _ -> write drop_status (Str (Printf.sprintf "%s got other (%s)" name op)));
        (* A same-app MOVE removes its original in the same batch (D2). *)
        if d.operation = Some Op.Move then begin
          write source_text (Str "moved out");
          Option.iter (fun w -> draggable w ()) !source
        end
      in

      window ~title:"dnd" ();
      let root =
        row
          [
            (fun () ->
              let w =
                each (record_handle items)
                  (fun () ->
                    Tpl.(label ~bind_field:item_title ~a11y_id:"row" ()))
                  ()
              in
              list := Some w;
              w);
            (fun () ->
              column
                [
                (fun () ->
                  let w = label ~bind:source_text () (* label#0 *) in
                  source := Some w;
                  w);
                (fun () ->
                  let w = label ~bind:text_target () (* label#1 *) in
                  set_accepts w [ accept_text ];
                  set_drop_target w [ Op.Copy ];
                  on_drop app w (dropped "text target" text_target);
                  w);
                (fun () ->
                  let w = label ~bind:note_target () (* label#2 *) in
                  set_accepts w [ note_id ];
                  set_drop_target w [ Op.Copy; Op.Move ];
                  on_drop app w (dropped "note target" note_target);
                  w);
                (fun () ->
                  let w = label ~bind:files_target () (* label#3 *) in
                  set_accepts w [ accept_files ];
                  set_drop_target w [ Op.Copy ];
                  w);
                  label ~bind:drop_status (* label#4 *);
                  label ~bind:drag_status (* label#5 *);
                ]
                ());
          ]
          ()
      in
      mount root;
      Option.iter
        (fun w ->
          draggable ~text:"hello" ~custom:[ (note_id, "note!") ]
            ~operations:[ Op.Copy; Op.Move ] w ();
          on_drag_ended app w (fun op ->
              write drag_status (Str (Printf.sprintf "drag ended %s" (word op)))))
        !source;
      (* The moved row's key rides as the kaya-private custom
         representation; the anchor is the row it landed on (D8). *)
      Option.iter
        (fun w ->
          set_reorderable w true;
          on_drop app w (fun (d : dropped) ->
              match (d.clip, d.anchor) with
              | Some (Custom (_, key)), Str anchor :: _ ->
                  if d.before then move_before (record_handle items) (Str key) (Str anchor)
                  else move_after (record_handle items) (Str key) (Str anchor)
              | _ -> ()))
        !list;
      insert_record items (Str "a") { title = "a" };
      insert_record items (Str "b") { title = "b" };
      insert_record items (Str "c") { title = "c" });

  exit (run app)
