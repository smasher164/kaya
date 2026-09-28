(* The scroll-to scene, OCaml port — guests/rust/scrollto.rs,
   tools/scenes/scrollto.steps: the app scrolls a list of messages to a
   row by key (docs/scroll-to-plan.md), opening at the newest one before
   the first layout, jumping to one on a click, staying put on a key no
   row holds, and following its own send. *)

open Kaya_app

type message = { text : string } [@@deriving kaya_gen]
type frame = { name : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let messages = collection_of message_record in
      let frames = collection_of frame_record in
      let count = signal Scalar.Str "60 messages" in
      (* The For's own container is what a scroll_to_row addresses
         (docs/scroll-to-plan.md S1): [each] returns it. *)
      let list = ref None in
      let strip = ref None in
      let sent = ref 60 in
      let framed = ref 30 in

      let send () =
        incr sent;
        let key = Printf.sprintf "m%d" !sent in
        insert_record messages (Key.str key)
          { text = Printf.sprintf "message %d" !sent };
        write count (Printf.sprintf "%d messages" !sent);
        scroll_to_row (Option.get !list) (Key.str key)
      in

      let add_frame () =
        incr framed;
        insert_record frames
          (Key.str (Printf.sprintf "f%d" !framed))
          { name = Printf.sprintf "frame %d" !framed }
      in

      let root =
        column
          [
            label ~bind:count ~a11y_id:"count";
            row
              [
                button ~text:"jump" ~a11y_id:"jump" ~on_click:(fun () ->
                    scroll_to_row (Option.get !list) (Key.str "m10"));
                button ~text:"nowhere" ~a11y_id:"nowhere"
                  ~on_click:(fun () ->
                    scroll_to_row (Option.get !list) (Key.str "m999"));
                button ~text:"send" ~a11y_id:"send" ~on_click:send;
                button ~text:"frame" ~a11y_id:"frame" ~on_click:(fun () ->
                    scroll_to_row (Option.get !strip) (Key.str "f10"));
                button ~text:"add frame" ~a11y_id:"add_frame"
                  ~on_click:add_frame;
              ];
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
            (* A filmstrip that runs sideways (docs/hscroll-plan.md): the
               same scroll_to_row and follows_end, along its own axis. *)
            scroll ~axis:Horizontal ~follows_end:true ~a11y_id:"strip"
              [
                (fun () ->
                  let w =
                    each (record_handle frames)
                      (fun () -> Tpl.(label ~bind_field:frame_name ()))
                      ()
                  in
                  set_axis w Horizontal;
                  set_a11y_id w "frames";
                  strip := Some w;
                  w);
              ];
          ]
          ()
      in
      mount root;

      for i = 1 to 30 do
        insert_record frames
          (Key.str (Printf.sprintf "f%d" i))
          { name = Printf.sprintf "frame %d" i }
      done;
      for i = 1 to 60 do
        insert_record messages
          (Key.str (Printf.sprintf "m%d" i))
          { text = Printf.sprintf "message %d" i }
      done;
      scroll_to_row (Option.get !list) (Key.str "m60"));

  exit (run app)
