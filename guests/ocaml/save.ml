(* The save conformance scene, OCaml port — the ROUND TRIP an editor
   actually walks (docs/save-plan.md D5): open, edit, save back, save
   AS, reopen both.

   WHAT THIS PROVES, and none of it is about a dialog closing:

   1. SAVE-BACK WORKS. Writing through the handle the OPEN picker handed
      over — what DESIGN.md has claimed since the picker landed, and
      what no scene, leg or test drove until this one.
   2. A SAVE DESTINATION IS OPENABLE AT ALL. The panel answers with a
      name for a file NOBODY HAS MADE (measured on macOS: exists=false
      after a clean Save), so opening it would fail with "No such file
      or directory" were it not for the core's create-capable
      destination (docs/save-plan.md D1). This scene is where that
      shows.
   3. THE TWO FILES STAY DIFFERENT. The last step reopens BOTH handles
      and reports both contents, so a save-as that quietly wrote back
      into the ORIGINAL — the plausible bug, since the guest holds two
      handles that look alike — passes every earlier line and fails
      there.
   4. CANCEL IS NOTHING, AND THE ID RETIRES. The scene shows a save
      dialog, cancels it, and shows another; a cancel that leaked the
      live slot would fail the second show.

   EVERY ASSERTION IS A READ-BACK OFF THE DISK. The guest never reports
   what it hoped it wrote: each status is the file reopened through the
   HANDLE kaya gave it — never through [local_path], which is empty on
   both phones — and read with OCaml's own [Unix]/[Stdlib] file API. A
   write that returned success and landed nowhere is exactly the failure
   "save" has, and only reopening can see it.

   THE STRINGS ARE BYTE-FROZEN across all nine guests
   (scratchpad/save-depth.md §8), which is what lets them carry CONTENT
   rather than a verdict: "saved second draft" is what came back off the
   disk.

   THE WORK RUNS OFF THE APP THREAD, which is what [open_picked] tells
   every caller to do: it blocks, and a cloud provider may download the
   whole file first. The parking dance that PROVES the hop belongs to
   filedialog.ml; this scene owns the round trip instead.

   NO EXTENSIONS ON ANY NAME, deliberately: a save panel publishes its
   name field with a known extension hidden when the user's Finder
   preference says so, and the assertion would then read the stem on one
   machine and the whole name on another. NO FILTER ON THE SAVE REQUEST
   either — with allowed content types set, NSSavePanel appends the
   first of them to an extension-less name.

   See guests/rust/save.rs and tools/scenes/save.steps. *)

open Kaya_wire
open Kaya_app

(* The scene's own directory, agreed with the interpreter by
   CONSTRUCTION rather than by protocol: guest and interpreter are the
   same process, [Filename.get_temp_dir_name] honours TMPDIR exactly as
   the harness's $TMP does, and the pid keeps parallel legs apart. *)
let save_dir =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "kaya-save-%d" (Unix.getpid ()))

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* Read a whole descriptor, WITHOUT asking it how long it is:
   [in_channel_length] needs a seekable file, and a picked handle need
   not be one — Android's provider streams. Reading to EOF is what the
   bytes mean here. *)
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

(* Redeem a handle for read and report what the FILE says. THE
   READ-BACK IS THE ASSERTION in every step below. *)
let read_back (file : picked_file) =
  try
    let fd, _seekable = Kaya_runtime.open_picked file.handle file_mode_read in
    let ic = Unix.in_channel_of_descr fd in
    let text = read_all ic in
    (* Closes the descriptor exactly once: it IS the Unix one. *)
    close_in ic;
    text
  with e -> "open failed: " ^ Printexc.to_string e

(* Write [bytes] through a handle and report what the file says
   AFTERWARDS. [file_mode_write] truncates, on a picked file and on a
   save destination alike — the destination only adds the create. *)
let write_back (file : picked_file) bytes =
  match Kaya_runtime.open_picked file.handle file_mode_write with
  | exception e ->
      (* THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
         without the create, a save destination cannot be opened at
         all. *)
      "save failed: " ^ Printexc.to_string e
  | fd, _seekable ->
      let oc = Unix.out_channel_of_descr fd in
      output_string oc bytes;
      (* Closed BEFORE the reopen, so what comes back is the file's and
         not this channel's buffer. *)
      close_out oc;
      read_back file

let () =
  (* Both files are written before anything is shown. THE DECOY IS
     LOAD-BEARING: with one file in the directory a dialog completes
     with it when nothing is selected, so [file_choose draft] would pass
     on a backend that never selected anything. "decoy" sorts first, so
     that backend gets the WRONG file and its five bytes fail the byte
     assertion too. *)
  (try Unix.mkdir save_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat save_dir "draft") "first draft";
  write_file (Filename.concat save_dir "decoy") "decoy";

  let app = Kaya_app.create () in

  (* The two capabilities the scene carries: the file the user OPENED,
     and the destination the user later NAMED. Held as handles, never as
     paths — the phones hand back no re-openable name at all. *)
  let source : picked_file option ref = ref None in
  let destination : picked_file option ref = ref None in

  build app (fun () ->
      window ~title:"save" ();
      let status = signal (Str "no file") in

      (* Every file operation runs on a thread of the guest's own,
         because [open_picked] blocks; the answer comes back through the
         poster. *)
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
            (* Cancel is [None]. Nothing was named, so nothing is
               written and NO DESTINATION IS REMEMBERED. *)
            write status (Str "save cancelled")
        | Some file ->
            destination := Some file;
            work (fun () -> "saved " ^ write_back file "third draft")
      in

      let ask_open () =
        (* NO FILTER: the names in this scene have no extensions. *)
        ignore (pick_file ~on_result:opened ())
      in
      let save_back () =
        (* SAVE-BACK NEEDS NO DIALOG. The user already chose this file,
           and the handle they chose it with is writable — the claim
           this step exists to drive. *)
        let file = Option.get !source in
        work (fun () -> "saved " ^ write_back file "second draft")
      in
      let save_as () =
        (* "copy" is the name the dialog OPENS with; the harness types
           over it, which is what a save dialog is for. *)
        ignore (save_file ~on_result:saved "copy")
      in
      let reopen () =
        (* BOTH, in order: the file that was opened must still hold the
           save-back, and the destination must hold the save-as. *)
        let first = Option.get !source in
        let second = Option.get !destination in
        work (fun () ->
            Printf.sprintf "reopened %s %s" (read_back first) (read_back second))
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
