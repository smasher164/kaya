(* The colour picker scene, OCaml port — guests/rust/colorpicker.rs,
   tools/scenes/colorpicker.steps, docs/color-picker-plan.md. *)

open Kaya_app

type swatch = { name : string; fill : color } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let title_text = signal Scalar.Str "color: none" in
      let glaze_text = signal Scalar.Str "alpha: none" in
      let row_text = signal Scalar.Str "row: none" in
      let title_sig = signal Scalar.Color (Color.of_hex 0x336699FF) in
      let swatches = collection_of swatch_record in

      let root =
        column
          [
            label ~bind:title_text;                           (* label#0 *)
            label ~bind:glaze_text;                           (* label#1 *)
            label ~bind:row_text;                             (* label#2 *)
            color_picker ~a11y_id:"title" ~a11y_label:"Title colour" (* color_picker#0 *)
              ~bind:title_sig
              ~on_color:(fun picked ->
                write title_text ("color: " ^ Color.to_string picked));
            color_picker ~a11y_label:"Glaze"                  (* color_picker#1 *)
              ~value:(Color.of_hex 0x26A269FF) ~alpha:true
              ~on_color:(fun picked ->
                write glaze_text ("alpha: " ^ Color.to_string picked));
            button ~text:"reset"                              (* button#0 *)
              ~on_click:(fun () ->
                (* Must NOT come back as a Title occurrence. *)
                write title_sig (Color.of_hex 0x3584E4FF));
            each (record_handle swatches) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:swatch_name;
                      color_picker ~a11y_id:"fill" ~bind_field:swatch_fill
                        ~on_color:(fun keys picked ->
                          let key = key_text (List.hd keys) in
                          write row_text
                            (Printf.sprintf "row %s: %s" key
                               (Color.to_string picked)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record swatches (Key.str "a") { name = "a"; fill = Color.of_hex 0xE66100FF };
      insert_record swatches (Key.str "b") { name = "b"; fill = Color.of_hex 0xF6D32DFF });

  exit (run app)
