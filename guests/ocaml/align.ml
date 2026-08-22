(* The align conformance scene, OCaml port — see guests/rust/align.rs
   and tools/scenes/align.steps for the full rationale. The stretched
   root spans its two container children across the window; the center
   column's children have three different natural widths; the row
   aligns baselines across a label, a button, and a tall no-baseline
   image whose bottom sits ON the baseline (the CSS replaced-element
   rule), which is what separates the modes on every platform's
   metrics; and row#1 hosts the grown, stretched nested column the
   ruling pins (docs/deferred.md, the nested-container GAP). *)

open Kaya_wire
open Kaya_app

(* A 2x64 PNG: the tall no-baseline child. *)
let tall_png =
  Bytes.of_string
    "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\
   \068\082\000\000\000\002\000\000\000\064\008\002\000\000\
   \000\191\068\049\020\000\000\000\018\073\068\065\084\120\
   \156\099\008\008\138\002\034\134\081\106\104\082\000\067\
   \050\126\001\049\001\065\124\000\000\000\000\073\069\078\
   \068\174\066\096\130"

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let probe = signal (Str "align probe") in
     let base = signal (Str "base") in
     let anchor = signal (Str "anchor") in
     let fit = signal (Str "fit") in

     let root =
       column ~a11y_id:"root" ~align:Stretch
         [
           (* column#1: the center trio *)
           column ~a11y_id:"centered" ~align:Center
             [
               label ~bind:probe (* label#0 *);
               button ~text:"mid";
               (* row#0: the baseline trio *)
               row ~align:Baseline
                 [
                   label ~bind:base (* label#1 *);
                   button ~text:"tick";
                   image ~source:tall_png;
                 ];
             ];
           (* row#1: the stretch pair's host *)
           row
             [
               label ~bind:anchor (* label#2 *);
               (* column#2: grown into the row's leftover, stretched
                  across its own breadth *)
               column ~grow:1.0 ~a11y_id:"fitcol" ~align:Stretch
                 [ label ~bind:fit (* label#3 *); button ~text:"wide" ];
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
