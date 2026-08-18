(* The clipboard conformance scene, OCaml port — one clip in several
   representations, and the privileged read that takes one back
   (DESIGN.md, Clipboard; docs/clipboard-plan.md).

   Every assertion but the custom format's is made by a FOREIGN tool, so
   the lowerings are what gets checked rather than kaya's own parse. The
   image is asserted as a DECODED SIZE and never as bytes — every host
   re-encodes freely, so a byte count is a different number per lane.

   Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
   contract in tools/scenes/clipboard.steps. *)

open Kaya_wire
open Kaya_app

(* A 4x4 PNG spelled out rather than generated: a foreign decoder asserts
   its size, so the size has to be knowable from the script. *)
let pixel_png_bytes =
  [
             0x89; 0x50; 0x4E; 0x47; 0x0D; 0x0A; 0x1A; 0x0A (* signature *);
             0x00; 0x00; 0x00; 0x0D; 0x49; 0x48; 0x44; 0x52 (* IHDR length + type *);
             0x00; 0x00; 0x00; 0x04; 0x00; 0x00; 0x00; 0x04 (* 4 x 4 *);
             0x08; 0x02; 0x00; 0x00; 0x00; 0x26; 0x93; 0x09 (* 8-bit rgb + crc *);
             0x29; 0x00; 0x00; 0x00; 0x14; 0x49; 0x44; 0x41 (* IDAT length + type *);
             0x54; 0x78; 0xDA; 0x63; 0xF8; 0xCF; 0xC0; 0x00;
             0x47; 0x48; 0x4C; 0x74; 0xDE; 0x7F; 0x24; 0x00;
             0x00; 0xD2; 0x6F; 0x17; 0xE9; 0x51; 0xBB; 0x23;
             0x2D; 0x00; 0x00; 0x00; 0x00; 0x49; 0x45; 0x4E;
             0x44; 0xAE; 0x42; 0x60; 0x82 (* IEND + crc *);
  ]

let pixel_png =
  String.init (List.length pixel_png_bytes) (fun i ->
      Char.chr (List.nth pixel_png_bytes i))

(* Reverse-DNS and space-free: this id reaches every platform's own
   registry VERBATIM (a UTI, RegisterClipboardFormat, an X11 target
   atom, an Android MIME type). *)
let note_id = "dev.kaya/note"

(* NO QUOTES IN THE PAYLOAD: the step grammar escapes newline, carriage
   return and backslash but not a quote, so a quoted byte cannot be
   spelled in the expectation. (OCaml lexes a quote inside a comment as
   a string, so this one cannot show the escapes either.) *)
let note_bytes = "note=1"

(* Guest and interpreter are the same process and compute this path
   identically, with no runner involvement (the filedialog rule); the
   pid keeps parallel legs apart, and [Filename.get_temp_dir_name]
   honours TMPDIR, which is what makes the two halves agree. *)
let scene_dir =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "kaya-clip-%d" (Unix.getpid ()))

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let () =
  (try Unix.mkdir scene_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write_file (Filename.concat scene_dir "pixel.png") pixel_png;
  write_file (Filename.concat scene_dir "pasted.txt") "pasted bytes";

  let app = Kaya_app.create () in
  let rich = ref None in
  let plain = ref None in

  build app (fun () ->
      window ~title:"clipboard"
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Cut" ~role:role_cut;
                item ~label:"Copy" ~role:role_copy;
                item ~label:"Paste" ~role:role_paste;
              ];
          ]
        ();

      let status = signal (Str "ready") in
      let row_status = signal (Str "") in
      let notes = collection () in

      let answered clip =
        match clip with
        (* Empty cannot discriminate its causes — denied, unfocused,
           absent, or nothing this read accepted — so the guest does not
           claim to know which. *)
        | None -> write status (Str "empty")
        | Some (Text text) -> write status (Str (Printf.sprintf "text %s" text))
        | Some (Html html) -> write status (Str (Printf.sprintf "html %s" html))
        | Some (Custom (id, body)) ->
            write status (Str (Printf.sprintf "custom %s %s" id body))
        | Some (Image bytes) ->
            copy ~image:bytes ();
            write status (Str "image")
        | Some (Files []) -> write status (Str "files none")
        | Some (Files (first :: _)) ->
            let worker () =
              (* OFF THE APP THREAD: [open_picked] blocks, and a pasted
                 file redeems exactly like a picked one. *)
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
              post app (fun () ->
                  write status
                    (Str (Printf.sprintf "files %s %s" first.name text)))
            in
            ignore (Thread.create worker ());
            write status (Str "reading")
      in

      let copy_rich () =
        (* One clip, four representations. kaya derives NONE of them
           from any other, so an app that wants text beside html spells
           out both. *)
        copy ~text:"kaya clip" ~html:"<b>kaya</b> clip" ~image:pixel_png
          ~custom:[ (note_id, note_bytes) ] ();
        write status (Str "copied")
      in
      let read_custom () =
        ignore (read_clipboard ~on_result:answered [ note_id ])
      in
      let read_text () = ignore (read_clipboard ~on_result:answered [ accept_text ]) in
      let read_image () =
        ignore (read_clipboard ~on_result:answered [ accept_image ])
      in
      let read_files () =
        ignore (read_clipboard ~on_result:answered [ accept_files ])
      in

      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            button ~text:"copy" ~on_click:copy_rich (* button#0 *);
            button ~text:"read custom" ~on_click:read_custom (* button#1 *);
            button ~text:"read text" ~on_click:read_text (* button#2 *);
            button ~text:"read image" ~on_click:read_image (* button#3 *);
            button ~text:"read files" ~on_click:read_files (* button#4 *);
            button ~text:"focus rich"
              ~on_click:(fun () -> Option.iter focus !rich)
              (* button#5 *);
            button ~text:"focus plain"
              ~on_click:(fun () -> Option.iter focus !plain)
              (* button#6 *);
            (fun () ->
              (* A non-empty accept list is what turns the paste hook
                 on; without one the platform inserts and the app never
                 sees it. *)
              let w = entry ~a11y_id:"rich" () in
              set_accepts w [ accept_text ];
              on_paste app w (fun clip ->
                  match clip with
                  | Text text ->
                      write status (Str (Printf.sprintf "pasted %s" text))
                  | _ -> write status (Str "pasted other"));
              rich := Some w;
              w)
            (* entry#0 *);
            (fun () ->
              (* No accept list: the platform inserts and the field's
                 ordinary change path reports it. *)
              let w = entry ~a11y_id:"plain" () in
              plain := Some w;
              w)
            (* entry#1 *);
            (* The same two doors on a STAMPED copy: the accept list is
               declared on the TEMPLATE, and without it the node hook
               registers, dispatches and can never fire
               (docs/tpl-props-plan.md §1). The copy's own key arrives in
               front of the payload. *)
            label ~a11y_id:"row-status" ~bind:row_status (* label#1 *);
            each notes (fun () ->
                Tpl.(
                  let note = entry ~accepts:[ accept_text ] () in
                  on_paste_node app note (fun keys clip ->
                      let key =
                        match keys with Str k :: _ -> k | _ -> "no key"
                      in
                      match clip with
                      | Text text ->
                          write row_status
                            (Str (Printf.sprintf "row %s pasted %s" key text))
                      | other ->
                          write row_status
                            (Str
                               (Printf.sprintf "row %s pasted %s" key
                                  (match other with
                                  | Html _ -> "html"
                                  | Image _ -> "image"
                                  | Files _ -> "files"
                                  | Custom _ -> "custom"
                                  | Text _ -> "text"))));
                  note))
            (* entry#2 once r1 stamps *);
          ]
          ()
      in
      mount root;
      insert notes (Str "r1") (Str ""));

  exit (run app)
