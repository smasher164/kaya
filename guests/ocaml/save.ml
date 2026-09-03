(* The save scene, OCaml port — guests/rust/save.rs, tools/scenes/save.steps. *)

open Kaya_wire
open Kaya_app

(* The pid keeps legs apart, and [Filename.get_temp_dir_name] honours TMPDIR
   exactly as the harness's $TMP does. *)
let save_dir =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "kaya-save-%d" (Unix.getpid ()))

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* Read to EOF WITHOUT asking the descriptor its length: a picked handle
   need not be seekable — Android's provider streams. *)
let read_all ic =
  let buf = Buffer.create 64 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let n = input ic chunk 0 (Bytes.length chunk) in
    if n > 0 then (
      Buffer.add_subbytes buf chunk 0 n;
      loop ())
  in
  loop ();
  Buffer.contents buf

let read_back (file : picked_file) =
  try
    let fd, _seekable = Kaya_runtime.open_picked file.handle file_mode_read in
    let ic = Unix.in_channel_of_descr fd in
    let text = read_all ic in
    (* [close_in] closes the underlying descriptor; never [Unix.close] too. *)
    close_in ic;
    text
  with e -> "open failed: " ^ Printexc.to_string e

(* [file_mode_write] truncates; a save destination only adds the create. *)
let write_back (file : picked_file) bytes =
  match Kaya_runtime.open_picked file.handle file_mode_write with
  | exception e ->
      "save failed: " ^ Printexc.to_string e
  | fd, _seekable ->
      let oc = Unix.out_channel_of_descr fd in
      output_string oc bytes;
      (* Closed BEFORE the reopen, so the bytes are the file's. *)
      close_out oc;
      read_back file

let () =
  (* THE DECOY MUST SORT FIRST: with one file in the directory a dialog
     completes with it when nothing is selected (docs/traps.md). *)
  (try Unix.mkdir save_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat save_dir "draft") "first draft";
  write_file (Filename.concat save_dir "decoy") "decoy";

  let app = Kaya_app.create () in

  (* Handles, never paths: the phones hand back no re-openable name. *)
  let source : picked_file option ref = ref None in
  let destination : picked_file option ref = ref None in

  build app (fun () ->
      window ~title:"save" ();
      let status = signal (Str "no file") in

      let work job =
        ignore
          (Thread.create
             (fun () ->
               let text = job () in
               post app (fun () -> write status (Str text)))
             ())
      in

      let opened files =
        match files with
        | [] -> write status (Str "open cancelled")
        | first :: _ ->
            source := Some first;
            work (fun () -> "opened " ^ read_back first)
      in

      let saved destination_file =
        match destination_file with
        | None ->
            write status (Str "save cancelled")
        | Some file ->
            destination := Some file;
            work (fun () -> "saved " ^ write_back file "third draft")
      in

      let ask_open () =
        ignore (pick_file ~on_result:opened ())
      in
      let save_back () =
        (* A missing handle gets its OWN sentence, never an exception: a
           crashed guest masks the real failure (docs/deferred.md, save-jvm
           WATCH). *)
        match !source with
        | None -> write status (Str "nothing open to save")
        | Some file ->
            work (fun () -> "saved " ^ write_back file "second draft")
      in
      let save_as () =
        ignore (save_file ~on_result:saved "copy")
      in
      let reopen () =
        match (!source, !destination) with
        | Some first, Some second ->
            work (fun () ->
                Printf.sprintf "reopened %s %s" (read_back first)
                  (read_back second))
        | _ -> write status (Str "nothing to reopen")
      in

      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            button ~text:"open" ~on_click:ask_open (* button#0 *);
            button ~text:"save" ~on_click:save_back (* button#1 *);
            button ~text:"save as" ~on_click:save_as (* button#2 *);
            button ~text:"reopen" ~on_click:reopen (* button#3 *);
          ]
          ()
      in
      mount root);

  exit (run app)
