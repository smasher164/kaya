(* The textarea scene, OCaml port — guests/rust/textarea.rs,
   tools/scenes/textarea.steps. *)

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

       (* The editor realizes here because the clear button's handler needs
          its handle. *)
       let editor =
         textarea ~on_change:(fun text -> write lines (Str (count text))) ()
       in
       let root =
         column
           [
             w editor;
             label ~bind:lines;
             button ~text:"clear"
               ~on_click:(fun () ->
                 clear editor;
                 focus editor);
           ]
           ()
       in
       mount root;
       (lines, editor))
  in
  ignore lines;
  ignore editor;

  exit (run app)
