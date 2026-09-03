(* The a11y scene, OCaml port — guests/rust/a11y.rs, tools/scenes/a11y.steps. *)

open Kaya_app

let mark_name = "images/a11y-logo.png"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* Safe: the blob table keeps its own reference. *)
     let mark = asset mark_name in
     let spoken = signal (Str "Before") in
     let root =
       column ~a11y_id:"form" ~a11y_label:"Form"
         [
           (* Deliberately not labelled: the platform must speak the
              caption. *)
           button ~a11y_id:"save" ~a11y_hint:"save the draft" ~text:"Save";
           checkbox ~a11y_id:"details" ~a11y_hint:"show more detail"
             ~text:"Details";
           button ~a11y_id:"reset" ~text:"Reset";
           label ~a11y_id:"status" ~text:"Ready";
           entry ~a11y_id:"name" ~a11y_label:"Full name";
           textarea ~a11y_id:"notes" ~a11y_label:"Notes";
           slider ~a11y_id:"volume" ~a11y_label:"Volume" ~min:0.0 ~max:1.0
             ~value:0.5;
           progress ~a11y_id:"loading" ~a11y_label:"Loading" ~value:0.25;
           image ~a11y_id:"logo" ~a11y_label:"Logo" ~source_asset:mark;
           select ~a11y_id:"color" ~a11y_label:"Color" [ "Red"; "Green" ];
           radio ~a11y_id:"size" ~a11y_label:"Size" [ "Small"; "Large" ];
           grid ~columns:2 ~a11y_id:"cells" ~a11y_label:"Cells"
             [ label ~text:"Name"; label ~text:"Ada" ];
           scroll ~a11y_id:"feed" ~a11y_label:"Feed" [ label ~text:"Item" ];
           row ~a11y_id:"actions" ~a11y_label:"Actions"
             [
               button ~a11y_id:"cancel" ~text:"Cancel";
               button ~a11y_id:"ok" ~text:"OK";
             ];
           label ~a11y_id:"spoken" ~a11y_label_bind:spoken ~text:"Spoken";
           button ~a11y_id:"rename" ~text:"Rename"
             ~on_click:(fun () -> write spoken (Str "After"));
         ]
         ()
     in
     asset_close mark;
     mount root);

  exit (run app)
