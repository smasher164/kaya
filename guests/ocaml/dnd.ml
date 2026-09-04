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

let key_word = function Str s :: _ -> s | _ -> ""

(* The file the scene drops as a FOREIGN source (D6), written by the guest
   at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
   convention. *)
let write_dropped_file () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "kaya-dnd-%d" (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let out = open_out_bin (Filename.concat dir "dropped.txt") in
  output_string out "dropped bytes";
  close_out out

let read_back (f : picked_file) =
  try
    let fd, _seekable = Kaya_runtime.open_picked f.handle file_mode_read in
    let ic = Unix.in_channel_of_descr fd in
    let len = in_channel_length ic in
    let s = really_input_string ic len in
    close_in ic;
    s
  with e -> "open failed: " ^ Printexc.to_string e

let () =
  write_dropped_file ();
  let app = Kaya_app.create () in

  build app (fun () ->
      let items = collection_of item_record in
      let items2 = collection_of item_record in
      let drop_status = signal (Str "no drop yet") in
      let drag_status = signal (Str "no drag yet") in
      let source_text = signal (Str "hello") in
      let text_target = signal (Str "text target") in
      let note_target = signal (Str "note target") in
      let files_target = signal (Str "files target") in
      let source = ref None in
      let list = ref None in
      let row_label = ref None in
      let item_label = ref None in

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
        | Some (Files files) ->
            (* A dropped file IS a picked file (D6): read it back through
               the same table the picker fills. *)
            let said =
              String.concat ", "
                (List.map
                   (fun (f : picked_file) ->
                     Printf.sprintf "%s %s" f.name (read_back f))
                   files)
            in
            write drop_status (Str (Printf.sprintf "%s got %s (%s)" name said op))
        | _ -> write drop_status (Str (Printf.sprintf "%s got other (%s)" name op)));
        (* A same-app MOVE removes its original in the same batch (D2). *)
        if d.operation = Some Op.Move then begin
          write source_text (Str "moved out");
          Option.iter (fun w -> draggable w ()) !source
        end
      in

      (* The bound payload follows the row's record (docs/dnd-plan.md §4). *)
      let on_rename () =
        update_record items2 (Str "y") { title = "yy" }
      in

      window ~title:"dnd" ();
      let root =
        row
          [
            (fun () ->
              let w =
                each (record_handle items)
                  (fun () ->
                    let n = Tpl.(label ~bind_field:item_title ~a11y_id:"row" ()) in
                    row_label := Some n;
                    n)
                  ()
              in
              list := Some w;
              set_a11y_id w "rows";
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
                  on_drop app w (dropped "files target" files_target);
                  w);
                  label ~bind:drop_status (* label#4 *);
                  label ~bind:drag_status (* label#5 *);
                ]
                ());
            (* THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item
               is a text destination, and its payload IS the row's own
               field — resolved per copy, re-declared when it changes. *)
            (fun () ->
              let w =
                each (record_handle items2)
                  (fun () ->
                    let n = Tpl.(label ~bind_field:item_title ~a11y_id:"item" ()) in
                    Tpl.set_accepts n [ accept_text ];
                    Tpl.set_drop_target n [ Op.Copy ];
                    Tpl.draggable ~text_field:item_title ~operations:[ Op.Copy ] n ();
                    item_label := Some n;
                    n)
                  ()
              in
              set_a11y_id w "items";
              w);
            button ~text:"rename y" ~on_click:on_rename (* button#0 *);
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
      let node_ended what keys op =
        write drag_status
          (Str (Printf.sprintf "%s %s drag ended %s" what (key_word keys) (word op)))
      in
      Option.iter (fun n -> on_drag_ended_node app n (node_ended "row")) !row_label;
      Option.iter
        (fun n ->
          on_drag_ended_node app n (node_ended "item");
          on_drop_node app n (fun keys (d : dropped) ->
              let op = word d.operation in
              match d.clip with
              | Some (Text text) ->
                  write drop_status
                    (Str
                       (Printf.sprintf "item %s got text %s (%s)" (key_word keys) text
                          op))
              | _ ->
                  write drop_status
                    (Str (Printf.sprintf "item %s got other (%s)" (key_word keys) op))))
        !item_label;
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
      insert_record items (Str "c") { title = "c" };
      List.iter
        (fun key -> insert_record items2 (Str key) { title = key })
        [ "x"; "y" ]);

  exit (run app)
