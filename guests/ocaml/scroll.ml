(* The scroll conformance scene, OCaml port — the viewport grows so
   the enclosing track constrains it (an unconstrained viewport hugs
   its content and nothing overflows); the bottom button, reachable
   only by scrolling, proves the scrolled-to content is live. See
   guests/rust/scroll.rs and tools/scenes/scroll.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app
    (let* () = window_title "scroll" in
     let* s = signal (Str "at top") in
     status := Some s;
     let on_bottom tx = write s (Str "bottom clicked") tx in
     let row i =
       let* caption = signal (Str (Printf.sprintf "row %d" i)) in
       label ~bind:caption ()
     in
     let* root =
       column
         [
           label ~bind:s () (* label#0 *);
           scroll ~grow:1.0
             (column
                (List.init 29 (fun i -> row (i + 1))
                @ [ button ~text:"bottom" ~on_click:on_bottom () (* button#0 *) ]));
         ]
     in
     mount root);

  ignore !status;

  exit (run app)
