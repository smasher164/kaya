(* The code surface scene, OCaml port: guests/rust/codesurface.rs,
   tools/scenes/codesurface.steps (docs/code-surface-plan.md). A textarea
   that numbers its lines, the platform's monospaced face, a family picked
   from the platform's list, a family the platform lacks, a label at twice
   the size. *)

open Kaya_app

(* Forty lines; the third wraps at every lane's width. *)
let document =
  String.concat "\n"
    ([
       "// codesurface";
       "fn main() {";
       "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row "
       ^ "and the gutter has a continuation to leave unnumbered, the way every editor does\";";
     ]
    @ List.init 36 (fun k -> Printf.sprintf "    let value_%02d = %d * 2;" (k + 4) (k + 4))
    @ [ "}" ])

let () =
  let app = Kaya_app.create () in
  let picked = ref None in
  let listed = ref None in

  on_font_families app (fun families ->
      let rec ordered = function a :: (b :: _ as rest) -> compare a b < 0 && ordered rest | _ -> true in
      let word =
        if families = [] then "families: none"
        else if ordered families then "families: listed, unique, in order"
        else "families: out of order"
      in
      Option.iter (fun s -> write s word) !listed;
      match (families, !picked) with first :: _, Some p -> set_family p first | _ -> ());

  build app (fun () ->
      window ~title:"codesurface" ();
      let families = signal Scalar.Str "families: -" in
      listed := Some families;
      let code = textarea ~a11y_id:"code" ~line_numbers:true ~monospaced:true () in
      set_text code document;
      let plain = textarea ~a11y_id:"plain" () in
      set_text plain "plain text\nin the app's face";
      let mono_entry = entry ~monospaced:true ~a11y_id:"mono_entry" () in
      set_text mono_entry "let y = 2;";
      let pick = label ~text:"picked" ~a11y_id:"picked" () in
      picked := Some pick;
      let at = String.length document in
      mount
        (column
           [
             w code;
             w plain;
             label ~text:"let x = 1;" ~monospaced:true ~a11y_id:"mono";
             w mono_entry;
             label ~text:"missing" ~family:"Kaya No Such Family" ~monospaced:true ~a11y_id:"missing";
             label ~text:"Big" ~text_scale:2.0 ~a11y_id:"big";
             label ~text:"Plain" ~a11y_id:"plain_label";
             label ~bind:families ~a11y_id:"families";
             w pick;
             row
               [
                 button ~text:"end" ~a11y_id:"end"
                   ~on_click:(fun () ->
                     focus code;
                     select_range code (at, at);
                     reveal_range code (at, at));
                 button ~text:"fonts" ~a11y_id:"fonts" ~on_click:list_font_families;
               ];
           ]
           ()));

  exit (run app)
