(* The pickers scene, OCaml port — guests/rust/pickers.rs,
   tools/scenes/pickers.steps, docs/datetime-plan.md. *)

open Kaya_app

type task = { name : string; due : date } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let date_text = signal_str ("date: none") in
      let time_text = signal_str ("time: none") in
      let row_text = signal_str ("row: none") in
      let date_sig = signal_date { year = 2026; month = 9; day = 4 } in
      let time_sig = signal_time { hour = 14; minute = 30 } in
      let tasks = collection_of task_record in

      let root =
        column
          [
            label ~bind:date_text;                            (* label#0 *)
            label ~bind:time_text;                            (* label#1 *)
            label ~bind:row_text;                             (* label#2 *)
            date_picker ~a11y_id:"when" ~a11y_label:"Due"     (* date_picker#0 *)
              ~bind:date_sig
              ~min:{ year = 2026; month = 1; day = 1 }
              ~max:{ year = 2026; month = 12; day = 31 }
              ~on_change:(fun picked ->
                write date_text (("date: " ^ string_of_date picked)));
            time_picker ~a11y_id:"at" ~a11y_label:"At"        (* time_picker#0 *)
              ~bind:time_sig ~step:15
              ~on_change:(fun picked ->
                write time_text (("time: " ^ string_of_time picked)));
            button ~text:"reset"                              (* button#0 *)
              ~on_click:(fun () ->
                write date_sig { year = 2026; month = 3; day = 1 };
                write time_sig { hour = 9; minute = 0 });
            each (record_handle tasks) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:task_name;
                      date_picker ~a11y_id:"due" ~bind_field:task_due
                        ~on_change:(fun keys picked ->
                          let key = key_text (List.hd keys) in
                          write row_text
                            (Printf.sprintf "row %s: %s" key
                               (string_of_date picked)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record tasks (str_key "a")
        { name = "a"; due = { year = 2026; month = 10; day = 1 } };
      insert_record tasks (str_key "b")
        { name = "b"; due = { year = 2026; month = 11; day = 20 } });

  exit (run app)
