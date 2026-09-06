(* The adaptive scene, OCaml port — guests/rust/adaptive.rs,
   tools/scenes/adaptive.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     (* Above the breakpoint, so the resize half crosses it both ways. *)
     window ~title:"adaptive" ~width:900.0 ~height:600.0 ();

     let alpha = signal (Str "alpha") in
     let longer = signal (Str "a longer label") in
     let steady = signal (Str "steady") in
     let one = signal (Str "one") in
     let two = signal (Str "a wider two") in

     (* row#0: the flip subject, realized ahead because the handler needs
        its handle. *)
     let dash =
       row ~a11y_id:"dash"
         [ label ~bind:alpha (* label#0 *); label ~bind:longer (* label#1 *) ]
         ()
     in
     let vertical = ref false in
     let flip () =
       vertical := not !vertical;
       set_axis dash (if !vertical then Vertical else Horizontal)
     in

     let root =
       column
         [
           w dash;
           (* column#1: the control group, whose axis never moves. *)
           column ~a11y_id:"steady" [ label ~bind:steady (* label#2 *) ];
           button ~text:"flip" ~on_click:flip (* button#0 *);
           (* row#1: the breakpoint subject, which no handler touches. *)
           row ~a11y_id:"narrow" ~stack_when:Compact
             [ label ~bind:one (* label#3 *); label ~bind:two (* label#4 *) ];
           (* grid@sheet: three columns regular, one compact (D6.2). *)
           grid ~columns:3 ~a11y_id:"sheet" ~columns_when:(Compact, 1)
             (List.map
                (fun text ->
                  let cell = signal (Str text) in
                  fun () -> label ~bind:cell () (* label#5..#10 *))
                [ "c1"; "c2"; "c3"; "c4"; "c5"; "c6" ]);
           (* grid@fit: no count, a 240-point floor, the WIDTH decides
              (docs/layout-knobs-plan.md §3). Buttons, so the label
              ordinals above stay put. *)
           grid ~columns:3 ~columns_auto:240.0 ~a11y_id:"fit"
             [
               (fun () -> button ~text:"f1" () (* button#1 *));
               (fun () -> button ~text:"f2" ());
               (fun () -> button ~text:"f3" ());
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
