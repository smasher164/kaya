(* The filedialog conformance scene, OCaml port — the picker's
   request/result grammar and the capability it hands back (DESIGN.md,
   File dialogs).

   WHAT THIS PROVES, and why it goes all the way to the bytes: the
   design's whole claim is that kaya hands over a CAPABILITY and never
   moves the data. So the guest does not assert that a dialog closed —
   it opens the handle it was given, reads the file with ORDINARY
   [Unix] calls, and writes what it read into a signal.

   THE FILE IS THE GUEST'S OWN, written before anything is shown, so
   guest and interpreter agree on a path with no runner involvement —
   they are the same process. [Filename.get_temp_dir_name] honours
   TMPDIR, which is what makes both halves land on the same place
   without either consulting the other.

   THE READ RUNS OFF THE APP THREAD, which is what [open_picked] tells
   every caller to do: it blocks, and a cloud provider may download the
   whole file before it returns. The worker PARKS between reading and
   posting, and only a click releases it, so a guest that read inline is
   caught by [expect label#0 "reading"] and one that did the work on the
   app thread wedges everything after.

   See guests/rust/filedialog.rs and tools/scenes/filedialog.steps. *)

open Kaya_wire
open Kaya_app

(* The parking is a plain Mutex + Condition, as background.ml's is:
   kaya supplies no waiting primitive and should not. *)
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
  (* THE DECOY IS LOAD-BEARING: with one file in the directory, pressing
     Open with nothing selected returns that file, so [file_choose
     picked.txt] would pass on a backend that ignored the name entirely.
     Measured on GTK. "decoy" sorts before "picked", so a backend that
     skips selection gets the WRONG file, and its five bytes fail the
     byte assertion as well as the name. *)
  write_file (Filename.concat picked_dir "picked.txt") "picked bytes";
  write_file (Filename.concat picked_dir "decoy.txt") "decoy";

  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"filedialog" ();
      let status = signal (Str "no file") in

      let picked files =
        match files with
        | [] ->
            (* The empty list IS cancel. Nothing to read, so no worker
               and no release. *)
            write status (Str "cancelled")
        | first :: _ ->
            let count = List.length files in
            let worker () =
              (* THE CLAIM, and it is made HERE rather than in the
                 handler on purpose: the handle crossed a thread
                 boundary, and it is redeemed and read with OCaml's own
                 file API on the thread that received it. kaya is not in
                 this data path, and the open is documented to block. *)
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
                 slow transfer. Were this work running on the app
                 thread, the release click could never be processed and
                 the whole scene would deadlock — the point. *)
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
        (* ADVISORY on every platform: a default view, never a
           guarantee, so a guest still validates what it got. *)
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
