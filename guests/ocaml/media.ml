(* The media suite, OCaml port — guests/rust/media.rs, tools/scenes/media_*.steps,
   docs/media-plan.md §7a, §7b. *)

open Kaya_app

type item = { item_name : string; source : Media_source.t; mime : string; codecs : string }

let local name mime codecs =
  { item_name = name; source = Media_source.asset ("media/" ^ name); mime; codecs }

let served base name mime codecs =
  { item_name = name; source = Media_source.url (base ^ "/" ^ name); mime; codecs }

let h264 = "avc1.64000b, mp4a.40.2"
let hevc = "hvc1.1.6.L60.90, mp4a.40.2"
let av1 = "av01.0.00M.08, mp4a.40.2"

let formats () =
  [
    local "h264_aac.mp4" "video/mp4" h264;
    local "hevc_aac.mp4" "video/mp4" hevc;
    local "hevc_aac.mov" "video/quicktime" hevc;
    local "vp9_opus.webm" "video/webm" "vp09.00.10.08, opus";
    local "vp9_aac.mp4" "video/mp4" "vp09.00.10.08, mp4a.40.2";
    local "av1_aac.mp4" "video/mp4" av1;
    local "av1_opus.webm" "video/webm" "av01.0.00M.08, opus";
    local "tone.mp3" "audio/mpeg" "";
    local "tone.m4a" "audio/mp4" "mp4a.40.2";
    local "tone.ogg" "audio/ogg" "opus";
    local "tone_opus.webm" "audio/webm" "opus";
    local "tone.flac" "audio/flac" "";
    local "tone.wav" "audio/wav" "";
  ]

let media_url () =
  match Sys.getenv_opt "KAYA_MEDIA_URL" with
  | Some base -> base
  | None ->
      failwith
        "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane \
         starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"

(* The local server's items, and the three failures: a 404, a local file
   that is not there, and a port nothing listens on. *)
let delivery () =
  let base =
    match Sys.getenv_opt "KAYA_MEDIA_URL" with
    | Some base -> base
    | None ->
        failwith
          "kaya: the media_delivery scene reads KAYA_MEDIA_URL, the local server the lane \
           starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
  in
  let refused =
    match String.rindex_opt base ':' with
    | Some i -> String.sub base 0 i ^ ":9"
    | None -> base
  in
  [
    served base "h264_aac.mp4" "video/mp4" h264;
    served base "hls_fmp4.m3u8" "application/vnd.apple.mpegurl" "";
    served base "hls_mpegts.m3u8" "application/vnd.apple.mpegurl" "";
    served base "dash.mpd" "application/dash+xml" "";
    served base "nope.mp4" "video/mp4" h264;
    local "missing.mp4" "video/mp4" h264;
    {
      item_name = "refused.mp4";
      source = Media_source.url (refused ^ "/h264_aac.mp4");
      mime = "video/mp4";
      codecs = h264;
    };
  ]

let yes_no b = if b then "yes" else "no"

let formats_app app scene =
  let session = scene = "media_session" in
  let items = Array.of_list (if scene = "media_delivery" then delivery () else formats ()) in
  let at = ref 0 in
  let can = ref false in
  let furthest = ref 0 in
  let nexts = ref 0 in
  let summary, name, p =
    build app (fun () ->
        window ~title:"media" ();
        let summary = signal Scalar.Str "idle" in
        let name = signal Scalar.Str (if session then "next 0" else "none") in
        let p = player ~muted:true ~loop:session () in
        let next () =
          if !at < Array.length items then begin
            let item = items.(!at) in
            incr at;
            can := can_play item.mime item.codecs;
            furthest := 0;
            player_source p item.source;
            write name item.item_name;
            write summary "loading"
          end
        in
        let toggle () =
          if (player_reading app p).state = Player_state.Idle then
            player_source p (Media_source.asset "media/h264_aac.mp4");
          play p
        in
        let root =
          column
            [
              label ~bind:summary;                                (* label#0 *)
              label ~bind:name;                                   (* label#1 *)
              video ~a11y_id:"clip" ~a11y_label:"Clip" ~player:p; (* video#0 *)
              button ~text:(if session then "play" else "next")   (* button#0 *)
                ~on_click:(if session then toggle else next);
            ]
            ()
        in
        mount root;
        if session then
          declare_session ~player:p ~title:"kaya media" ~artist:"kaya"
            ~handles:[ Session_action.Kind.Next ] ();
        (summary, name, p))
  in
  on_player_state app p (fun state ->
      if session then begin
        if state = Player_state.Playing || state = Player_state.Paused then
          write summary (Player_state.name state)
      end
      else if state = Player_state.Ready then play p
      else if state = Player_state.Ended then begin
        let r = player_reading app p in
        let played =
          if !furthest >= 1000 then "played past 1s"
          else Printf.sprintf "played to %dms" !furthest
        in
        write summary
          (Printf.sprintf "ready %.1fs %dx%d, %s, ended, can_play %s"
             (float_of_int r.duration_ms /. 1000.0)
             r.width r.height played (yes_no !can))
      end);
  on_failed app p (fun why _ ->
      write summary
        (Printf.sprintf "failed %s, can_play %s" (Media_failure.name why) (yes_no !can)));
  on_position app p (fun ms -> furthest := max !furthest ms);
  on_session app (function
    | Session_action.Next ->
        incr nexts;
        write name (Printf.sprintf "next %d" !nexts)
    | _ -> ());
  exit (run app)

(* One track list as a line: [audio en, fr [2]], the selection counting
   from 1, [-] for none; [audio none] for an empty list. *)
let track_line what tags selected =
  if tags = [] then what ^ " none"
  else
    let pick = match selected with Some i -> string_of_int (i + 1) | None -> "-" in
    Printf.sprintf "%s %s [%s]" what (String.concat ", " tags) pick

(* media_tracks (docs/media-plan.md §3, §7a): each item's audio and caption
   listing, a second audio track selected, the last caption track
   selected, and the cue read at 0.5 s and 1.5 s with the player paused
   there. The sidecar items are the suite's floor file with captions.vtt:
   an asset, then fetched from the local server, then a 404 there. *)
let tracks_app app =
  let base = media_url () in
  let floor label = { (local "h264_aac.mp4" "video/mp4" h264) with item_name = label } in
  let items =
    Array.of_list
      [
        (local "h264_2audio.mp4" "video/mp4" h264, None);
        (local "vp9_2audio.webm" "video/webm" "vp09.00.10.08, opus", None);
        (served base "hls_fmp4.m3u8" "application/vnd.apple.mpegurl" "", None);
        (served base "hls_mpegts.m3u8" "application/vnd.apple.mpegurl" "", None);
        (local "h264_tx3g.mp4" "video/mp4" h264, None);
        (floor "h264_aac.mp4 + captions.vtt", Some (Media_source.asset "media/captions.vtt"));
        ( floor "h264_aac.mp4 + http captions.vtt",
          Some (Media_source.url (base ^ "/captions.vtt")) );
        (floor "h264_aac.mp4 + http nope.vtt", Some (Media_source.url (base ^ "/nope.vtt")));
      ]
  in
  let at = ref 0 in
  let can = ref false in
  let summary, audio, captions, cue, p =
    build app (fun () ->
        window ~title:"media tracks" ();
        let summary = signal Scalar.Str "idle" in
        let name = signal Scalar.Str "none" in
        let audio = signal Scalar.Str "audio none" in
        let captions = signal Scalar.Str "captions none" in
        let cue = signal Scalar.Str "" in
        let p = player ~muted:true () in
        let next () =
          if !at < Array.length items then begin
            let item, sidecar = items.(!at) in
            incr at;
            can := can_play item.mime item.codecs;
            (match sidecar with
            | Some src -> player_captions p src ~language:"en"
            | None -> clear_captions p);
            player_source p item.source;
            write name item.item_name;
            write summary "loading";
            write cue ""
          end
        in
        let pick_captions () =
          let listed = List.length (tracks app p).captions in
          if listed = 0 then write cue "captions none" else select_captions p (Some (listed - 1))
        in
        let at_ms ms () =
          pause p;
          seek p ms
        in
        let root =
          column
            [
              label ~bind:summary;                                          (* label#0 *)
              label ~bind:name;                                             (* label#1 *)
              label ~bind:audio;                                            (* label#2 *)
              label ~bind:captions;                                         (* label#3 *)
              label ~bind:cue;                                              (* label#4 *)
              video ~a11y_id:"clip" ~a11y_label:"Clip" ~player:p;           (* video#0 *)
              button ~text:"next" ~on_click:next;                           (* button#0 *)
              button ~text:"audio 2" ~on_click:(fun () -> select_audio p 1); (* button#1 *)
              button ~text:"captions" ~on_click:pick_captions;              (* button#2 *)
              button ~text:"at 0.5s" ~on_click:(at_ms 500);                 (* button#3 *)
              button ~text:"at 1.5s" ~on_click:(at_ms 1500);                (* button#4 *)
              button ~text:"captions off"                                   (* button#5 *)
                ~on_click:(fun () -> select_captions p None);
              button ~text:"play"                                           (* button#6 *)
                ~on_click:(fun () ->
                  seek p 0;
                  play p);
            ]
            ()
        in
        mount root;
        (summary, audio, captions, cue, p))
  in
  on_player_state app p (fun state ->
      if state = Player_state.Ready then
        write summary (Printf.sprintf "ready, can_play %s" (yes_no !can)));
  on_failed app p (fun why _ ->
      let line = Printf.sprintf "failed %s, can_play %s" (Media_failure.name why) (yes_no !can) in
      write summary line;
      write audio line);
  on_tracks app p (fun t ->
      write audio (track_line "audio" t.Tracks.audio t.audio_selected);
      write captions (track_line "captions" t.captions t.caption_selected));
  on_cue app p (fun text -> write cue text);
  exit (run app)

type clip = { name : string; player : player } [@@deriving kaya_gen]

let feed_rows = 10

(* media_feed (docs/media-plan.md §7b): a scroll of rows, each a video view
   showing its row's own player, paused on its first frame; the first and
   last rows' visibility in label#0 and label#1. *)
let feed_app app =
  build app (fun () ->
      window ~title:"media feed" ~width:420.0 ~height:480.0 ();
      let first = signal Scalar.Str "r0 out" in
      let last = signal Scalar.Str (Printf.sprintf "r%d out" (feed_rows - 1)) in
      let clips = collection_of clip_record in
      let shown keys fraction =
        let row = match keys with k :: _ -> int_of_string (key_text k) | [] -> -1 in
        let word = if fraction >= 0.999 then "whole" else if fraction > 0.0 then "in" else "out" in
        if row = 0 then write first ("r0 " ^ word);
        if row = feed_rows - 1 then write last (Printf.sprintf "r%d %s" row word)
      in
      let root =
        column
          [
            label ~bind:first; (* label#0 *)
            label ~bind:last;  (* label#1 *)
            scroll ~grow:1.0
              [
                column
                  [
                    each (record_handle clips) (fun () ->
                        Tpl.(
                          column
                            [
                              label ~bind_field:clip_name;
                              video ~bind_field:clip_player ~on_visibility:shown;
                            ]
                            ()));
                  ];
              ];
          ]
          ()
      in
      mount root;
      for i = 0 to feed_rows - 1 do
        let p = player ~muted:true ~source:(Media_source.asset "media/h264_aac.mp4") () in
        insert_record clips (Key.int (Int64.of_int i)) { name = Printf.sprintf "r%d" i; player = p }
      done);
  exit (run app)

let () =
  let scene = Option.value (Sys.getenv_opt "KAYA_SELFTEST") ~default:"" in
  let app = Kaya_app.create () in
  match scene with
  | "media_tracks" -> tracks_app app
  | "media_feed" -> feed_app app
  | _ -> formats_app app scene
