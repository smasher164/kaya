(* The secure field scene, OCaml port — guests/rust/secure.rs,
   tools/scenes/secure.steps (docs/secure-entry-plan.md §5): a password
   field whose text the app receives whole and answers only as a length
   and a match, a clear button, and a stamped field per account whose
   edits name the row. *)

open Kaya_app

type account = { name : string } [@@deriving kaya_gen]

let password = "Zq7vKeXw9pLm"

let chars text =
  String.fold_left
    (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1)
    0 text

let status text =
  match chars text with
  | 0 -> "empty"
  | n when text = password -> Printf.sprintf "%d characters, match" n
  | n -> Printf.sprintf "%d characters, no match" n

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let accounts = collection_of account_record in
      let status_text = signal Scalar.Str "empty" in
      let sent_text = signal Scalar.Str "sent: -" in
      let pin_text = signal Scalar.Str "pin: -" in

      let field =
        secure_field ~placeholder:"Password" ~a11y_id:"password"
          ~a11y_label:"Password"
          ~on_change:(fun text -> write status_text (status text))
          ~on_submit:(fun text ->
            write sent_text (Printf.sprintf "sent: %s" (status text)))
          ()
      in
      let root =
        column
          [
            w field;
            label ~bind:status_text ~a11y_id:"status";
            label ~bind:sent_text ~a11y_id:"sent";
            button ~text:"Clear" ~a11y_id:"clear"
              ~on_click:(fun () -> clear field);
            label ~bind:pin_text ~a11y_id:"pin_status";
            each (record_handle accounts) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:account_name;
                      secure_field ~a11y_id:"pin"
                        ~on_change:(fun keys text ->
                          write pin_text
                            (Printf.sprintf "pin %s: %d"
                               (key_text (List.hd keys)) (chars text)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      List.iter
        (fun key -> insert_record accounts (Key.str key) { name = key })
        [ "a"; "b" ]);

  exit (run app)
