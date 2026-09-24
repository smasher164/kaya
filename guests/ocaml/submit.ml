(* The submit scene, OCaml port — guests/rust/submit.rs,
   tools/scenes/submit.steps: Return in an entry, a search field and a
   [~submits] textarea publishes the field's text (docs/submit-plan.md);
   a plain textarea's Return is its newline. The app writes each submit
   into one label. *)

open Kaya_app

type thread = { title : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let threads = collection_of thread_record in
      let sent = signal Scalar.Str "sent: -" in

      let sent_text text = write sent (Printf.sprintf "sent: %s" text) in

      let root =
        column
          [
            label ~bind:sent ~a11y_id:"sent";
            entry ~placeholder:"Name" ~a11y_id:"name" ~on_submit:sent_text;
            search ~placeholder:"Search" ~a11y_id:"find" ~on_submit:sent_text;
            textarea ~a11y_id:"plain" ~on_submit:sent_text;
            textarea ~submits:true ~a11y_id:"compose" ~on_submit:sent_text;
            each (record_handle threads) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:thread_title;
                      entry ~a11y_id:"reply"
                        ~on_submit:(fun keys text ->
                          write sent
                            (Printf.sprintf "sent: %s: %s"
                               (key_text (List.hd keys)) text));
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      List.iter
        (fun (key, title) -> insert_record threads (Key.str key) { title })
        [ ("r1", "First"); ("r2", "Second") ]);

  exit (run app)
