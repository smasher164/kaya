(* The reveal toggle scene, OCaml port — guests/rust/reveal.rs,
   tools/scenes/reveal.steps (docs/reveal-plan.md §5): a password field
   with its own show/hide toggle, the app's own Show and Hide buttons, and
   a stamped field each row reveals by its own field. *)

open Kaya_app

type account = { name : string; shown : bool } [@@deriving kaya_gen]

let password = "Rv4tNbHy2mQc"

let chars text =
  String.fold_left
    (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1)
    0 text

let status text =
  match chars text with
  | 0 -> "empty"
  | n when text = password -> Printf.sprintf "%d characters, match" n
  | n -> Printf.sprintf "%d characters, no match" n

let shown on = if on then "shown" else "hidden"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let accounts = collection_of account_record in
      let status_text = signal Scalar.Str "empty" in
      let sent_text = signal Scalar.Str "sent: -" in
      let heard_text = signal Scalar.Str "heard: -" in
      let pin_text = signal Scalar.Str "pin: -" in

      let field =
        secure_field ~placeholder:"Password" ~content_type:Content_type.Password
          ~revealable:true ~a11y_id:"password" ~a11y_label:"Password"
          ~on_change:(fun text -> write status_text (status text))
          ~on_submit:(fun text ->
            write sent_text (Printf.sprintf "sent: %s" (status text)))
          ~on_toggle:(fun on ->
            write heard_text (Printf.sprintf "heard: %s" (shown on)))
          ()
      in
      let root =
        column
          [
            w field;
            label ~bind:status_text ~a11y_id:"status";
            label ~bind:sent_text ~a11y_id:"sent";
            label ~bind:heard_text ~a11y_id:"heard";
            button ~text:"Show" ~a11y_id:"show"
              ~on_click:(fun () -> set_revealed field true);
            button ~text:"Hide" ~a11y_id:"hide"
              ~on_click:(fun () -> set_revealed field false);
            button ~text:"Clear" ~a11y_id:"clear"
              ~on_click:(fun () -> clear field);
            label ~bind:pin_text ~a11y_id:"pin_status";
            each (record_handle accounts) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:account_name;
                      secure_field ~a11y_id:"pin" ~revealable:true
                        ~revealed_field:account_shown
                        ~on_change:(fun keys text ->
                          write pin_text
                            (Printf.sprintf "pin %s: %d"
                               (key_text (List.hd keys)) (chars text)))
                        ~on_toggle:(fun keys on ->
                          write pin_text
                            (Printf.sprintf "pin %s: %s"
                               (key_text (List.hd keys)) (shown on)));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record accounts (Key.str "b") { name = "b"; shown = true });

  exit (run app)
