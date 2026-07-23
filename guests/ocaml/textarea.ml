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
    build app
      (let* lines = signal (Str "0 lines") in
       let* () = window_title "textarea" in

       let* column = widget kind_column in
       let* editor = widget kind_textarea in
       let* lines_label = widget kind_label in
       let* () = bind_text lines_label lines in
       let* clear_btn = widget kind_button in
       let* () = set_text clear_btn "clear" in

       let* () = add_child column editor in
       let* () = add_child column lines_label in
       let* () = add_child column clear_btn in
       let* () = mount column in

       let* () =
         io (fun () ->
             on_change app editor (fun text -> write lines (Str (count text)));
             on_click app clear_btn
               (let* () = clear editor in
                focus editor))
       in
       return (lines, editor))
  in
  ignore lines;
  ignore editor;

  exit (run app)
