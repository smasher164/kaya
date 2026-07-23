(* The align conformance scene, OCaml port — see guests/rust/align.rs
   and tools/scenes/align.steps for the full rationale. The root
   column centers children of three different natural widths; the row
   aligns baselines across a label, a checkbox, and a tall no-baseline
   image whose bottom sits ON the baseline (the CSS replaced-element
   rule) — the construction that separates the modes on every
   platform's control metrics.

   [~align] at construction is the declarative spelling; [set_align]
   is the dynamic path this scene has no reason to use. *)

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

     let root =
       column ~align:Center
         [
           label ~bind:probe (* label#0 *);
           button ~text:"mid";
           row ~align:Baseline
             [
               label ~bind:base (* label#1 *);
               button ~text:"tick";
               image ~source:tall_png;
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
