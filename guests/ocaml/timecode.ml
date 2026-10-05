open Kaya_app

type line = { qty : float } [@@deriving kaya_gen]

let () =
  let app = create () in
  let normal = { numerator = 25L; denominator = 1L; drop = false } in
  let drop = { numerator = 30000L; denominator = 1001L; drop = true } in
  let commits = ref 0 in
  let phase = ref 0 in
  assert (Fmt.parse_timecode normal "٠١:٠٢:٠٣:١٢" = Some 93087L);
  assert (Fmt.parse_timecode drop "00:01:00;00" = None);
  assert (Fmt.parse_timecode normal "00:00:00:00\000ignored" = None);
  build app (fun () ->
      window ~title:"Timecode" ~width:440.0 ~height:500.0 ();
      let status = signal Scalar.Str "commits: 0" in
      let row_status = signal Scalar.Str "row: none" in
      let playhead = signal Scalar.Str (Fmt.timecode normal 93087L) in
      let rows = collection_of line_record in
      let committed frames =
        incr commits;
        write status (Printf.sprintf "commits: %d" !commits);
        write playhead (Fmt.timecode normal (Int64.of_float frames))
      in
      let switching_value = signal Scalar.F64 (-2.0) in
      let switching = number_field ~a11y_id:"switching" ~bind:switching_value () in
      let switch_format () =
        (match !phase mod 4 with
        | 0 -> set_format switching (Timecode drop); write switching_value 1800.0
        | 1 -> write switching_value (-2.0); set_format switching Number
        | 2 -> write switching_value 1800.0; set_format switching (Timecode drop)
        | _ -> set_format switching Number; write switching_value (-2.0));
        incr phase
      in
      let root = column [
        label ~text:"25 fps";
        label ~a11y_id:"playhead" ~bind:playhead;
        number_field ~value:93087.0 ~format:(Timecode normal)
          ~a11y_id:"position" ~a11y_label:"Position" ~on_commit:committed;
        label ~a11y_id:"commits" ~bind:status;
        label ~text:"29.97 drop-frame";
        number_field ~value:1799.0 ~format:(Timecode drop)
          ~a11y_id:"drop" ~a11y_label:"Drop frame" ~on_commit:committed;
        entry ~a11y_id:"note";
        each (record_handle rows) (fun () ->
          Tpl.(row [number_field ~a11y_id:"rowtime" ~bind_field:line_qty
            ~format:(Timecode normal) ~on_commit:(fun keys frames ->
              write row_status (Printf.sprintf "row %s: %.0f" (key_text (List.hd keys)) frames))] ()));
        label ~a11y_id:"row" ~bind:row_status;
        (fun () -> switching);
        button ~a11y_id:"switchformat" ~text:"Switch format" ~on_click:switch_format;
      ] () in
      mount root;
      insert_record rows (Key.str "a") { qty = 25.0 });
  exit (run app)
