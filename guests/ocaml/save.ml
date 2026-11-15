(* The save scene, OCaml port — guests/rust/save.rs, tools/scenes/save.steps. *)

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
    let fd, _seekable = open_picked file File_mode.Read in
    let ic = Unix.in_channel_of_descr fd in
    let text = read_all ic in
    (* [close_in] closes the underlying descriptor; never [Unix.close] too. *)
    close_in ic;
    text
  with e -> "open failed: " ^ Printexc.to_string e

(* [File_mode.Write] truncates; a save destination only adds the create. *)
let write_back (file : picked_file) bytes =
  match open_picked file File_mode.Write with
  | exception e ->
      "save failed: " ^ Printexc.to_string e
  | fd, _seekable ->
      let oc = Unix.out_channel_of_descr fd in
      output_string oc bytes;
      (* Closed BEFORE the reopen, so the bytes are the file's. *)
      close_out oc;
      read_back file

(* What else the directory holds, as OCaml lists it: a temporary file the
   save left would show here. The scene's three names are left out
   (Android's scoped storage hides [final], which the provider made, from
   an app's listing), and so is the mac panel's [.DS_Store]. *)
let strays () =
  let names =
    Sys.readdir save_dir |> Array.to_list
    |> List.filter (fun n -> not (List.mem n [ "decoy"; "draft"; "final"; ".DS_Store" ]))
    |> List.sort compare
  in
  if names = [] then "nothing else in the folder" else "also " ^ String.concat " " names

(* The safe save (docs/rich-document-plan.md §4.1), read back. *)
let safe_save (file : picked_file) text =
  match save_picked file text with
  | exception e -> "safe save failed: " ^ Printexc.to_string e
  | () -> Printf.sprintf "safe saved %s; %s" (read_back file) (strays ())

let () =
  (* THE DECOY MUST SORT FIRST: with one file in the directory a dialog
     completes with it when nothing is selected (docs/traps.md). *)
  (try Unix.mkdir save_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat save_dir "draft") "the first draft";
  write_file (Filename.concat save_dir "decoy") "decoy";

  let app = Kaya_app.create () in

  (* Handles, never paths: the phones hand back no re-openable name. *)
  (* The dialogs' own answers, which arrive in a handler long after the
     scene is built: not a container body smuggling its result out. *)
  let source : picked_file option ref = ref None in
  let destination : picked_file option ref = ref None in

  build app (fun () ->
      window ~title:"save" ();
      let status = signal Scalar.Str ("no file") in

      let work job =
        ignore
          (Thread.create
             (fun () ->
               let text = job () in
               post app (fun () -> write status (text)))
             ())
      in

      let opened files =
        match files with
        | [] -> write status ("open cancelled")
        | first :: _ ->
            source := Some first;
            work (fun () -> "opened " ^ read_back first)
      in

      let saved destination_file =
        match destination_file with
        | None ->
            write status ("save cancelled")
        | Some file ->
            destination := Some file;
            work (fun () -> "saved " ^ write_back file "third draft")
      in

      let ask_open () =
        pick_file () opened
      in
      let save_back () =
        (* A missing handle gets its OWN sentence, never an exception: a
           crashed guest masks the real failure (docs/deferred.md, save-jvm
           WATCH). *)
        match !source with
        | None -> write status ("nothing open to save")
        | Some file ->
            work (fun () -> "saved " ^ write_back file "second draft")
      in
      let save_as () =
        save_file "copy" saved
      in
      let reopen () =
        match (!source, !destination) with
        | Some first, Some second ->
            work (fun () ->
                Printf.sprintf "reopened %s %s" (read_back first)
                  (read_back second))
        | _ -> write status ("nothing to reopen")
      in
      (* LONGER over the source's "second draft", then SHORTER over the
         destination's "third draft". *)
      let safe_save_back () =
        match !source with
        | None -> write status "nothing open to save"
        | Some file -> work (fun () -> safe_save file "the fourth draft, the longest of them")
      in
      let safe_save_as () =
        match !destination with
        | None -> write status "nothing to reopen"
        | Some file -> work (fun () -> safe_save file "fifth")
      in

      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            button ~text:"open" ~on_click:ask_open (* button#0 *);
            button ~text:"save" ~on_click:save_back (* button#1 *);
            button ~text:"save as" ~on_click:save_as (* button#2 *);
            button ~text:"reopen" ~on_click:reopen (* button#3 *);
            button ~text:"safe save" ~on_click:safe_save_back (* button#4 *);
            button ~text:"safe save as" ~on_click:safe_save_as (* button#5 *);
          ]
          ()
      in
      mount root);

  exit (run app)
