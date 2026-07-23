(* The textarea conformance scene, OCaml port. See
   guests/rust/textarea.rs and tools/scenes/textarea.steps. *)

open Kaya_wire
open Kaya_app

let count text =
  if text = "" then "0 lines"
  else Printf.sprintf "%d lines" (List.length (String.split_on_char '\n' text))

let () =
  let app = Kaya_app.create () in

  let lines, editor =
    build app (fun () ->
       let lines = signal (Str "0 lines") in
       window ~title:"textarea" ();

       let column = widget kind_column in
       let editor = widget kind_textarea in
       let lines_label = widget kind_label in
       bind_text lines_label lines;
       let clear_btn = widget kind_button in
       set_text clear_btn "clear";

       add_child column editor;
       add_child column lines_label;
       add_child column clear_btn;
       mount column;

       on_change app editor (fun text -> write lines (Str (count text)));
       on_click app clear_btn (fun () ->
           clear editor;
           focus editor);
       (lines, editor))
  in
  ignore lines;
  ignore editor;

  exit (run app)
