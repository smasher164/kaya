(* The filedialog scene, OCaml port — guests/rust/filedialog.rs,
   tools/scenes/filedialog.steps. *)

open Kaya_wire
open Kaya_app

(* A plain Mutex + Condition: kaya supplies no waiting primitive. *)
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
  (* THE DECOY MUST SORT BEFORE "picked" and hold different bytes
     (docs/traps.md, "Pressing Open with nothing selected still returns a
     file"). *)
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
              (* Parks holding the result, standing in for a slow transfer. *)
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
        (* Filters are ADVISORY: a guest still validates what it got. *)
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
