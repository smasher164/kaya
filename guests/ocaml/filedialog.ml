(* The filedialog conformance scene, OCaml port — the picker's
   request/result grammar and the capability it hands back (DESIGN.md,
   File dialogs).

   The guest does not assert that a dialog closed: it opens the handle it
   was given, reads the file with ORDINARY [Unix] calls, and writes what
   it read into a signal.

   THE FILE IS THE GUEST'S OWN, written before anything is shown, so
   guest and interpreter agree on a path with no runner involvement —
   [Filename.get_temp_dir_name] honours TMPDIR exactly as the harness's
   $TMP does.

   THE READ RUNS OFF THE APP THREAD, which is what [open_picked] tells
   every caller to do: it blocks, and a cloud provider may download the
   whole file first. The worker PARKS between reading and posting and
   only a click releases it, so a guest that read inline is caught by
   [expect label#0 "reading"] and one that did the work on the app thread
   wedges everything after.

   See guests/rust/filedialog.rs and tools/scenes/filedialog.steps. *)

open Kaya_wire
open Kaya_app

(* A plain Mutex + Condition, as background.ml's is: kaya supplies no
   waiting primitive and should not. *)
let release_lock = Mutex.create ()
let release_cond = Condition.create ()
let released = ref false

let picked_dir =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "kaya-picked-%d" (Unix.getpid ()))

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let () =
  (try Unix.mkdir picked_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* THE DECOY MATTERS: with one file in the directory a chooser
     completes with it when nothing is selected. "decoy" sorts before
     "picked" and holds different bytes, so a backend that skips
     selection fails both assertions (docs/traps.md, the file-dialog
     selection notes). *)
  write_file (Filename.concat picked_dir "picked.txt") "picked bytes";
  write_file (Filename.concat picked_dir "decoy.txt") "decoy";

  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"filedialog" ();
      let status = signal (Str "no file") in

      let picked files =
        match files with
        | [] ->
            (* The empty list IS cancel: no worker, no release. *)
            write status (Str "cancelled")
        | first :: _ ->
            let count = List.length files in
            let worker () =
              let text =
                try
                  let fd, _seekable =
                    Kaya_runtime.open_picked first.handle file_mode_read
                  in
                  let ic = Unix.in_channel_of_descr fd in
                  let len = in_channel_length ic in
                  let s = really_input_string ic len in
                  close_in ic;
                  s
                with e -> "open failed: " ^ Printexc.to_string e
              in
              (* Parks holding the result, standing in for the tail of a
                 slow transfer: on the app thread the release click could
                 never be processed and the scene would deadlock. *)
              Mutex.lock release_lock;
              while not !released do
                Condition.wait release_cond release_lock
              done;
              Mutex.unlock release_lock;
              post app (fun () ->
                  write status (Str (Printf.sprintf "%d %s" count text)))
            in
            ignore (Thread.create worker ());
            (* The handler RETURNED without reading. *)
            write status (Str "reading")
      in

      let ask () =
        (* Filters are ADVISORY on every platform — a default view,
           never a guarantee — so a guest still validates what it got. *)
        ignore (pick_files ~filters:[ ("Text", "txt") ] ~on_result:picked ())
      in
      let ask_one () =
        ignore (pick_file ~filters:[ ("Text", "txt") ] ~on_result:picked ())
      in
      let do_release () =
        Mutex.lock release_lock;
        released := true;
        Condition.broadcast release_cond;
        Mutex.unlock release_lock
      in
      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            button ~text:"open" ~on_click:ask (* button#0 *);
            button ~text:"open one" ~on_click:ask_one (* button#1 *);
            button ~text:"release" ~on_click:do_release (* button#2 *);
          ]
          ()
      in
      mount root);

  exit (run app)
