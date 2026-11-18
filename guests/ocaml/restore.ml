(* The restoration scene, OCaml port — guests/rust/restore.rs,
   tools/scenes/restore.steps (docs/restoration-plan.md SR15): the draft
   lives in the session store and comes back through the ordinary build;
   the list's scroll and the text's caret come back on their own. *)

open Kaya_app

type message = { text : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in
  let session = session () in

  build app (fun () ->
      window ~title:"restore" ();
      let messages = collection_of message_record in
      let launch = signal Scalar.Str ("launch " ^ restored ()) in
      let list = ref None in
      let doc = ref None in
      let root =
        column
          [
            label ~bind:launch;
            (fun () ->
              let field =
                entry ~on_change:(fun text -> session.set_string "draft" text) ()
              in
              set_text field (session.get_string "draft" "");
              field);
            row
              [
                button ~text:"jump" ~a11y_id:"jump" ~on_click:(fun () ->
                    scroll_to_row (Option.get !list) (Key.str "m30"));
                button ~text:"select" ~a11y_id:"select" ~on_click:(fun () ->
                    select_range (Option.get !doc) (4, 9));
              ];
            (fun () ->
              let w = textarea ~a11y_id:"doc" () in
              set_text w "the quick brown fox";
              doc := Some w;
              w);
            scroll ~grow:1.0 ~a11y_id:"list"
              [
                (fun () ->
                  let w =
                    each (record_handle messages)
                      (fun () -> Tpl.(label ~bind_field:message_text ()))
                      ()
                  in
                  set_a11y_id w "messages";
                  list := Some w;
                  w);
              ];
          ]
          ()
      in
      mount root;
      for i = 1 to 60 do
        insert_record messages
          (Key.str (Printf.sprintf "m%d" i))
          { text = Printf.sprintf "message %d" i }
      done);
  exit (run app)
