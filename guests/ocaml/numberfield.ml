(* The number field scene, OCaml port — guests/rust/numberfield.rs,
   tools/scenes/numberfield.steps, docs/number-field-plan.md. *)

open Kaya_app

type line = { name : string; qty : float } [@@deriving kaya_gen]

(* The harness's own value spelling (crates/kaya/src/harness.rs). *)
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
      let commit_text = signal Scalar.Str ("commits: 0") in
      let row_text = signal Scalar.Str ("row: none") in
      let amount_value = signal Scalar.F64 (0.0) in
      let lines = collection_of line_record in

      let root =
        column
          [
            label ~a11y_id:"commits" ~bind:commit_text;
            label ~a11y_id:"row" ~bind:row_text;
            number_field ~a11y_id:"amount" ~a11y_label:"Amount"
              ~min:0.0 ~max:100.0 ~step:0.5 ~bind:amount_value
              ~on_commit:(fun _ ->
                incr commits;
                write commit_text
                  (Printf.sprintf "commits: %d" !commits));
            entry ~a11y_id:"note";
            button ~a11y_id:"forty" ~text:"forty"
              ~on_click:(fun () ->
                (* Must NOT come back as a commit. *)
                write amount_value (40.0));
            each (record_handle lines) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:line_name;
                      number_field ~a11y_id:"qty" ~bind_field:line_qty
                        ~min:0.0
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

      insert_record lines (Key.str "a") { name = "a"; qty = 1.0 };
      insert_record lines (Key.str "b") { name = "b"; qty = 2.0 });

  exit (run app)
