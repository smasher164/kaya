(* The scroll scene, OCaml port — guests/rust/scroll.rs,
   tools/scenes/scroll.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"scroll" ();
     let s = signal Scalar.Str ("at top") in
     let on_bottom () = write s ("bottom clicked") in
     let on_last () = write s "last card clicked" in
     let row i () =
       let caption = signal Scalar.Str ((Printf.sprintf "row %d" i)) in
       label ~bind:caption ()
     in
     let card i () =
       let caption = signal Scalar.Str (Printf.sprintf "card %d" i) in
       label ~bind:caption ()
     in
     let root =
       column
         [
           label ~bind:s (* label#0 *);
           scroll ~grow:1.0 ~a11y_id:"rows"
             [
               column
                 (List.init 29 (fun i -> row (i + 1))
                 @ [ button ~text:"bottom" ~on_click:on_bottom (* button#0 *) ]);
             ];
           (* A strip wider than the window, scrolled sideways
              (docs/hscroll-plan.md), addressed as scroll@strip. *)
           scroll ~axis:Horizontal ~a11y_id:"strip"
             [
               Kaya_app.row
                 (List.init 19 (fun i -> card (i + 1))
                 @ [ button ~text:"last card" ~a11y_id:"last" ~on_click:on_last ]);
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
