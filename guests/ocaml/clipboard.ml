(* The clipboard conformance scene, OCaml port — one clip in several
   representations, and the privileged read that takes one back
   (DESIGN.md, Clipboard; docs/clipboard-plan.md).

   EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design
   of this scene. kaya's representation set is closed because the
   LOWERINGS are the hard part — CF_HTML's mandatory offset header,
   Android's content:// URI for an image, CF_HDROP's double-NUL struct —
   and a check where kaya reads what kaya wrote parses its own malformed
   header perfectly happily. That is not merely less coverage: it is a
   check that cannot fail for the reason the design exists.

   THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool on
   any platform writes an app-defined type, so the guest copies one and
   reads it back, with the foreign reader confirming from outside that
   the bytes really are there under that id.

   THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
   re-encodes freely between image types, so a byte count would be a
   different number on every lane for one picture.

   Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
   contract in tools/scenes/clipboard.steps. *)

open Kaya_wire
open Kaya_app

(* A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
   through a foreign decoder, so the picture has to be a real encoded
   image whose size is knowable from the script. Written to disk for the
   seeding tool AND handed to [copy] as bytes — the same picture both
   ways. *)
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

(* The app-defined format's id: reverse-DNS and space-free, because it
   reaches every platform's own registry VERBATIM — a UTI on Apple,
   RegisterClipboardFormat on Windows, a target atom on X11 and Wayland,
   a MIME type on Android. *)
let note_id = "dev.kaya/note"

(* NO QUOTES IN THE PAYLOAD, and the reason is the script rather than
   the clipboard: the step grammar has escapes for newline, carriage
   return and backslash in all three interpreters, but none for a quote
   — so a quoted byte could not be spelled in the expectation. (This
   comment cannot show the escapes literally either: OCaml reads a
   quote inside a comment as the start of a string.) *)
let note_bytes = "note=1"

(* Both halves compute this identically, the filedialog rule: guest and
   interpreter are the same process, so they agree on a path with no
   runner involvement, and the pid keeps parallel legs from colliding.
   [Filename.get_temp_dir_name] honours TMPDIR, which is OCaml's own
   answer and what makes the two halves agree. *)
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
      (* THE GESTURE LAYER'S DECLARATION, and an app writes nothing else
         for it: the Paste command lowers to the platform's own, acts on
         whatever is focused, and works out its own enablement. kaya has
         no selection API, which is exactly why copy of a selection has
         to be a command rather than something an app assembles out of
         the data layer. *)
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
        (* EMPTY IS THE UNIVERSAL NO, and the guest does not try to tell
           its four causes apart — denied, unfocused, absent, or nothing
           this read accepted. The platforms deliberately decline to
           say. *)
        | None -> write status (Str "empty")
        | Some (Text text) -> write status (Str (Printf.sprintf "text %s" text))
        | Some (Html html) -> write status (Str (Printf.sprintf "html %s" html))
        | Some (Custom (id, body)) ->
            write status (Str (Printf.sprintf "custom %s %s" id body))
        | Some (Image bytes) ->
            (* STRAIGHT BACK OUT, because the assertion that matters is a
               foreign DECODER's: the byte count differs per host for one
               picture, and the decoded size does not. *)
            copy ~image:bytes ();
            write status (Str "image")
        | Some (Files []) -> write status (Str "files none")
        | Some (Files (first :: _)) ->
            let worker () =
              (* OFF THE APP THREAD, which is what [open_picked]
                 documents: it blocks, and a pasted file is no different
                 from a picked one — it IS a picked one, the same
                 capability arriving through a second door. *)
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
        (* ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of them from
           any other: whether list bullets survive html-to-text is this
           app's decision, so it spells out both. The order they go on
           the wire is kaya's, not this call's — descending richness,
           which is preference order on every host that has one. *)
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
              (* DECLARES WHAT IT TAKES, so a paste lands in the hook and
                 this app decides what to do with it. *)
              let w = entry ~a11y_id:"rich" () in
              set_accepts w [ accept_text ];
              on_paste app w (fun clip ->
                  (* THE SAME SHAPE THE READ ANSWERS WITH, and free where
                     the read is not: a gesture is its own authorisation,
                     so no platform charges a prompt for this one. *)
                  match clip with
                  | Text text ->
                      write status (Str (Printf.sprintf "pasted %s" text))
                  | _ -> write status (Str "pasted other"));
              rich := Some w;
              w)
            (* entry#0 *);
            (fun () ->
              (* DECLARES NOTHING, so the platform's own insertion happens
                 and the field's ordinary change path reports it — which
                 is what a plain text editor gets for free. *)
              let w = entry ~a11y_id:"plain" () in
              plain := Some w;
              w)
            (* entry#1 *);
            (* THE SAME TWO DOORS ONE TIER DOWN, on a STAMPED copy. The
               accept list is declared on the TEMPLATE, and that
               declaration is what turns the node hook on: every backend
               hands the gesture to the platform when the focused
               widget's accept list is empty, so before a template node
               could carry one this handler registered, dispatched and
               could never fire (docs/tpl-props-plan.md §1). The copy's
               OWN KEY arrives in front of the payload, and printing it
               is what tells an instance paste from a live one.

               The row's value is empty because nothing displays it: the
               stamped entry is uncontrolled like its live siblings, and
               staying empty through the paste is the assertion. *)
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
