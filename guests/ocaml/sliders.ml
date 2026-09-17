(* The sliders scene, OCaml port — guests/rust/sliders.rs,
   tools/scenes/sliders.steps, docs/slider-plan.md. *)

open Kaya_app

type track = { name : string; level : float } [@@deriving kaya_gen]

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
      let level_text = signal_str ("value: 50") in
      let commit_text = signal_str ("commits: 0") in
      let volume_text = signal_str ("volume: 0.5") in
      let row_text = signal_str ("row: none") in
      let pos = signal_f64 (50.0) in
      let tracks = collection_of track_record in

      let root =
        column
          [
            label ~bind:level_text;                           (* label#0 *)
            label ~bind:commit_text;                          (* label#1 *)
            label ~bind:volume_text;                          (* label#2 *)
            label ~bind:row_text;                             (* label#3 *)
            slider ~a11y_id:"master" ~a11y_label:"Level"      (* slider#0 *)
              ~min:0.0 ~max:100.0 ~bind:pos ~step:5.0 ~tick_spacing:25.0
              ~on_change:(fun v ->
                write level_text (("value: " ^ spelled v)))
              ~on_commit:(fun _ ->
                incr commits;
                write commit_text
                  (Printf.sprintf "commits: %d" !commits));
            slider ~a11y_label:"Volume"                       (* slider#1 *)
              ~min:0.0 ~max:1.0 ~value:0.5 ~tick_spacing:0.25
              ~on_change:(fun v ->
                write volume_text (("volume: " ^ spelled v)));
            button ~text:"reset"                              (* button#0 *)
              ~on_click:(fun () ->
                (* Must NOT come back as a value or a commit occurrence. *)
                write pos (25.0));
            each (record_handle tracks) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:track_name;
                      slider ~a11y_id:"level" ~bind_field:track_level
                        ~min:0.0 ~max:100.0 ~step:10.0
                        ~on_commit:(fun keys v ->
                          let key = key_text (List.hd keys) in
                          write row_text
                            (Printf.sprintf "row %s: %s" key (spelled v)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record tracks (str_key "a") { name = "a"; level = 70.0 };
      insert_record tracks (str_key "b") { name = "b"; level = 20.0 });

  exit (run app)
