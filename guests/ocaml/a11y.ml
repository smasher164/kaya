(* The accessibility conformance scene from OCaml: the universal
   [~a11y_id]/[~a11y_label] props, read back out of the PLATFORM'S OWN
   accessibility tree rather than kaya's model.

   EVERY WIDGET KIND APPEARS AND EXACTLY ONE CONTAINER OF EACH KIND:
   container targets are ordinal, so they stay stable only while the
   scene keeps one of each. See guests/rust/a11y.rs for the full note;
   the byte-frozen contract is tools/scenes/a11y.steps. *)

open Kaya_app

(* A 2x2 RGB PNG, 75 bytes. Embedded as source per the include_str!
   doctrine: scenes carry their inputs, no runtime file I/O. *)
let test_png =
  Bytes.of_string
    "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\
     \082\000\000\000\002\000\000\000\002\008\002\000\000\000\253\
     \212\154\115\000\000\000\018\073\068\065\084\120\156\099\248\
     \207\192\192\000\194\012\255\129\000\000\031\238\005\251\011\
     \217\104\139\000\000\000\000\073\069\078\068\174\066\096\130"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let root =
       column ~a11y_id:"form" ~a11y_label:"Form"
         [
           (* Caption-bearing controls: identified, but deliberately
              NOT labelled — the platform must speak the caption. *)
           button ~a11y_id:"save" ~a11y_hint:"save the draft" ~text:"Save";
           checkbox ~a11y_id:"details" ~a11y_hint:"show more detail"
             ~text:"Details";
           button ~a11y_id:"reset" ~text:"Reset";
           label ~a11y_id:"status" ~text:"Ready";
           (* Caption-less controls: an app MUST name these. *)
           entry ~a11y_id:"name" ~a11y_label:"Full name";
           textarea ~a11y_id:"notes" ~a11y_label:"Notes";
           slider ~a11y_id:"volume" ~a11y_label:"Volume" ~min:0.0 ~max:1.0
             ~value:0.5;
           progress ~a11y_id:"loading" ~a11y_label:"Loading" ~value:0.25;
           image ~a11y_id:"logo" ~a11y_label:"Logo" ~source:test_png;
           (* The two CHOICE kinds: their options carry captions, the
              choice itself does not. *)
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
         ]
         ()
     in
     mount root);

  exit (run app)
