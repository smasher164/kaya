(* The align scene, OCaml port — guests/rust/align.rs,
   tools/scenes/align.steps. *)

open Kaya_wire
open Kaya_app

(* A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two lines
   in every lane's window (docs/layout-knobs-plan.md §2). *)
let wide_png =
  Bytes.of_string
    "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\
   \068\082\000\000\000\100\000\000\000\020\008\002\000\000\
   \000\244\162\015\194\000\000\000\056\073\068\065\084\120\
   \218\237\208\001\013\000\000\008\003\160\007\177\164\109\
   \141\099\133\007\096\035\001\153\061\074\081\032\075\150\
   \044\089\178\100\041\144\037\075\150\044\089\178\020\200\
   \146\037\075\150\044\089\010\122\015\034\121\229\167\065\
   \055\075\087\000\000\000\000\073\069\078\068\174\066\096\
   \130"

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
     let plain = signal (Str "plain probe") in

     let root =
       column ~a11y_id:"root" ~align:Stretch
         [
           (* column#1: the center trio *)
           column ~a11y_id:"centered" ~align:Center
             [
               label ~bind:probe (* label#0 *);
               button ~text:"mid";
               (* the baseline trio *)
               row ~a11y_id:"baseline" ~align:Baseline
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
               (* column#2 *)
               column ~grow:1.0 ~a11y_id:"fitcol" ~align:Stretch
                 [ label ~bind:fit (* label#3 *); button ~text:"wide" ];
             ];
           (* row@plain: NO align, so the core's centre default is what
              the scene reads *)
           row ~a11y_id:"plain"
             [
               label ~a11y_id:"plainlabel" ~bind:plain (* label#4 *);
               image ~source:tall_png;
             ];
           (* column@knobs: NO align; fill opts one child out of its
              default and one in *)
           column ~a11y_id:"knobs"
             [
               textarea ~fill:false ~a11y_id:"optout";
               button ~fill:true ~a11y_id:"fills" ~text:"fills";
               (* row@wrapped: six exact-width images flow onto two lines *)
               row ~a11y_id:"wrapped" ~wrap:true
                 [
                   image ~source:wide_png;
                   image ~source:wide_png;
                   image ~source:wide_png;
                   image ~source:wide_png;
                   image ~source:wide_png;
                   image ~source:wide_png;
                 ];
             ];
         ]
         ()
     in
     mount root);

  exit (run app)
