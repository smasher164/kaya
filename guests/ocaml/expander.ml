(* The expander scene, OCaml port — guests/rust/expander.rs,
   tools/scenes/expander.steps, docs/expander-plan.md §5. *)

open Kaya_app

type sec = { name : string; expanded : bool } [@@deriving kaya_gen]

let word on = if on then "open" else "closed"

let () =
  let app = Kaya_app.create () in
  let heard = ref 0 in
  let opens = Hashtbl.create 4 in
  Hashtbl.replace opens "s01" true;

  build app (fun () ->
      window ~title:"expander" ~width:520.0 ~height:860.0 ();
      let state = signal Scalar.Str "details: closed" in
      let heard_text = signal Scalar.Str "heard: 0" in
      let typed = signal Scalar.Str "name: -" in
      let rows_text = signal Scalar.Str "rows: -" in
      let inside = signal Scalar.Str "Inside the body" in
      let sections = collection_of sec_record in
      let details = ref None in
      let show on () =
        Option.iter (fun w -> set_expanded w on) !details;
        write state ("details: " ^ word on)
      in

      let root =
        column
          [
            (fun () ->
              let w =
                expander ~text:"Details" ~summary:"One field" ~symbol:Info ~a11y_id:"details"
                  ~on_toggle:(fun on ->
                    incr heard;
                    write state ("details: " ^ word on);
                    write heard_text (Printf.sprintf "heard: %d" !heard))
                  [
                    entry ~a11y_id:"name" ~placeholder:"Name"
                      ~on_change:(fun text -> write typed ("name: " ^ text));
                    label ~a11y_id:"inside" ~bind:inside;
                  ]
                  ()
              in
              details := Some w;
              w);
            label ~a11y_id:"state" ~bind:state;
            label ~a11y_id:"heard" ~bind:heard_text;
            label ~a11y_id:"typed" ~bind:typed;
            row
              [
                button ~text:"Show" ~a11y_id:"show" ~on_click:(show true);
                button ~text:"Hide" ~a11y_id:"hide" ~on_click:(show false);
              ];
            column ~a11y_id:"form"
              [
                labeled ~label:"Sort" [ select ~a11y_id:"sort" [ "Due"; "Name" ] ];
                expander ~text:"Advanced" ~a11y_id:"advanced"
                  [
                    labeled ~label:"Hide badge" [ checkbox ~a11y_id:"badge" ~text:"" ];
                    labeled ~label:"Keep completed" [ checkbox ~a11y_id:"keep" ~text:"" ];
                  ];
              ];
            label ~a11y_id:"rows" ~bind:rows_text;
            button ~text:"Rebuild" ~a11y_id:"rebuild"
              ~on_click:(fun () ->
                let on = Option.value ~default:false (Hashtbl.find_opt opens "s00") in
                remove (record_handle sections) (Key.str "s00");
                insert_record sections (Key.str "s00") { name = "Section 0"; expanded = on };
                write rows_text "rebuilt s00");
            column
              [
                each (record_handle sections) (fun () ->
                    Tpl.(
                      expander ~text_field:sec_name ~expanded_field:sec_expanded ~a11y_id:"sec"
                        ~on_toggle:(fun keys on ->
                          let key = key_text (List.hd keys) in
                          Hashtbl.replace opens key on;
                          sec_patch ~expanded:on sections (List.hd keys);
                          write rows_text (Printf.sprintf "sec %s: %s" key (word on)))
                        [ label ~bind_field:sec_name ]
                        ()));
              ];
          ]
          ()
      in
      mount root;

      for i = 0 to 2 do
        insert_record sections
          (Key.str (Printf.sprintf "s%02d" i))
          { name = Printf.sprintf "Section %d" i; expanded = i = 1 }
      done);

  exit (run app)
