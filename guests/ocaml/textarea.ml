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

       (* THE EDITOR REALIZES HERE because the clear button's handler
          needs its handle; [w editor] slots the existing widget into the
          child list, where the column merely attaches it (the todos
          scene's idiom).

          This scene used to be built entirely at the widget-kind floor —
          [widget kind_column], [add_child], [set_text] — while every
          constructor it needed sat in the binding unused. Nothing caught
          it: check-sugar-surface's floor rules read only the two
          carve-out scenes, so a guest outside that table could teach the
          floor indefinitely (docs/deferred.md). Invariant 5 says the
          example scenes use each language's sugar tier and only the C
          guests keep the explicit floor. *)
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
