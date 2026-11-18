(* The references scene, OCaml port — guests/rust/references.rs,
   tools/scenes/references.steps (docs/restoration-plan.md SR11, SR12): a
   picked file's durable reference rides the session store across a
   relaunch and redeems for its bytes; a foreign token and a deleted file
   are refused by name. *)

open Kaya_app

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* The bytes a token redeems for, or the refusal's branch; the sentence goes
   to stderr, where the leg log keeps it. *)
let read_back token =
  match redeem token with
  | exception Reference_error (refusal, message) ->
      prerr_endline ("references: " ^ message);
      refusal
  | redeemed -> (
      try
        let fd, _ = open_picked redeemed.file File_mode.Read in
        let ic = Unix.in_channel_of_descr fd in
        let s = really_input_string ic (in_channel_length ic) in
        close_in ic;
        "redeemed: " ^ s
      with e -> "open failed: " ^ Printexc.to_string e)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "kaya-refs-%d" (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat dir "picked.txt") "picked bytes";
  write_file (Filename.concat dir "decoy.txt") "decoy";

  let app = Kaya_app.create () in
  let session = session () in
  let saved = session.get_string "doc" "" in

  build app (fun () ->
      window ~title:"references" ();
      let status = signal Scalar.Str (if saved = "" then "no reference" else "redeeming") in
      let reader token =
        ignore
          (Thread.create
             (fun () ->
               let said = read_back token in
               post app (fun () -> write status said))
             ())
      in
      let picked files =
        match files with
        | [] -> write status "cancelled"
        | first :: _ -> (
            match reference first with
            | exception Reference_error (refusal, message) ->
                prerr_endline ("references: " ^ message);
                write status refusal
            | token ->
                session.set_string "doc" token;
                session.set_string "dir" dir;
                write status "minted")
      in
      mount
        (column
           [
             (fun () -> label ~a11y_id:"status" ~bind:status ());
             (fun () ->
               button ~a11y_id:"pick" ~text:"pick"
                 ~on_click:(fun () -> pick_file ~filters:[ ("Text", "txt") ] () picked)
                 ());
             (fun () ->
               button ~a11y_id:"foreign" ~text:"foreign"
                 ~on_click:(fun () -> reader "kaya-ref1:beos:AAAA:00000000")
                 ());
             (fun () ->
               button ~a11y_id:"delete" ~text:"delete"
                 ~on_click:(fun () ->
                   (try Sys.remove (Filename.concat (session.get_string "dir" "") "picked.txt")
                    with Sys_error _ -> ());
                   reader saved)
                 ());
           ]
           ());
      if saved <> "" then reader saved);
  exit (run app)
