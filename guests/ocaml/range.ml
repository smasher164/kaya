(* The range scene, OCaml port — guests/rust/range.rs,
   tools/scenes/range.steps, docs/range-plan.md. *)

open Kaya_app

type clip = { name : string; trim_in : float; trim_out : float } [@@deriving kaya_gen]

(* The harness's own slider spelling (crates/kaya/src/harness.rs). *)
let spelled v =
  let s = Printf.sprintf "%.6f" v in
  let last = ref (String.length s) in
  while !last > 0 && s.[!last - 1] = '0' do
    decr last
  done;
  if !last > 0 && s.[!last - 1] = '.' then decr last;
  String.sub s 0 !last

let () =
  let app = Kaya_app.create () in
  let commits = ref 0 in

  build app (fun () ->
      let live_text = signal Scalar.Str "live: 2 8" in
      let commit_text = signal Scalar.Str "commits: 0" in
      let volume_text = signal Scalar.Str "volume: 0.25" in
      let clip_text = signal Scalar.Str "clip: none" in
      let low_sig = signal Scalar.F64 2.0 in
      let high_sig = signal Scalar.F64 8.0 in
      let clips = collection_of clip_record in

      let root =
        column
          [
            label ~bind:live_text;                            (* label#0 *)
            label ~bind:commit_text;                          (* label#1 *)
            label ~bind:volume_text;                          (* label#2 *)
            label ~bind:clip_text;                            (* label#3 *)
            range ~a11y_id:"trim" ~a11y_label:"Trim"          (* range#0 *)
              ~min:0.0 ~max:10.0 ~low_bind:low_sig ~high_bind:high_sig
              ~step:0.5 ~tick_spacing:1.0 ~min_gap:1.0
              ~low_label:"In" ~high_label:"Out"
              ~on_change:(fun low high ->
                write live_text
                  (Printf.sprintf "live: %s %s" (spelled low) (spelled high)))
              ~on_commit:(fun low high ->
                incr commits;
                write commit_text
                  (Printf.sprintf "commits: %d at %s %s" !commits
                     (spelled low) (spelled high)));
            slider ~a11y_label:"Playhead"                     (* slider#0 *)
              ~min:0.0 ~max:10.0 ~value:5.0;
            slider ~a11y_id:"volume" ~a11y_label:"Volume"     (* slider#1 *)
              ~min:0.0 ~max:1.0 ~value:0.25 ~step:0.25 ~axis:Vertical
              ~on_change:(fun v -> write volume_text ("volume: " ^ spelled v));
            button ~text:"reset"                              (* button#0 *)
              ~on_click:(fun () ->
                (* Must NOT come back as a move or a commit. *)
                write low_sig 1.0);
            button ~text:"late"                               (* button#1 *)
              ~on_click:(fun () ->
                (* Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3). *)
                write low_sig 6.0);
            each (record_handle clips) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:clip_name;
                      range ~a11y_id:"clip" ~min:0.0 ~max:10.0
                        ~low_field:clip_trim_in ~high_field:clip_trim_out
                        ~step:0.5 ~min_gap:1.0
                        ~on_commit:(fun keys low high ->
                          let key = key_text (List.hd keys) in
                          write clip_text
                            (Printf.sprintf "clip %s: %s %s" key (spelled low)
                               (spelled high)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record clips (Key.str "a") { name = "a"; trim_in = 1.0; trim_out = 4.0 };
      insert_record clips (Key.str "b") { name = "b"; trim_in = 3.0; trim_out = 7.0 });

  exit (run app)
