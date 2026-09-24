(* The formatter door and the catalog, OCaml port — guests/rust/format.rs,
   tools/scenes/format.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  catalog "format";
  let d = { year = 2026; month = 9; day = 7 } in
  let t = { hour = 8; minute = 30 } in

  build app (fun () ->
     (* Fourteen labels and a row: taller than the default window. *)
     window ~title:"format" ~width:540.0 ~height:560.0 ();
     let root =
       column
         [
           label ~text:(Fmt.date ~length:`Short d) (* label#0 *);
           label ~text:(Fmt.date ~length:`Medium d) (* label#1 *);
           label ~text:(Fmt.date ~length:`Long d) (* label#2 *);
           label ~text:(Fmt.time ~length:`Short t) (* label#3 *);
           label ~text:(Fmt.date_time ~length:`Medium d t) (* label#4 *);
           label ~text:(Fmt.number 1234567.891) (* label#5 *);
           label ~text:(Fmt.percent 0.256) (* label#6 *);
           label ~text:(Fmt.currency 1234567.89 "USD") (* label#7 *);
           label ~text:(tr "items" [ "count", `Int 1 ]) (* label#8 *);
           label ~text:(tr "items" [ "count", `Int 3 ]) (* label#9 *);
           label ~text:(tr "greeting" [ "name", `Text "Ada" ]) (* label#10 *);
           row
             [
               label ~text:"first" (* label#11 *);
               spacer ~grow:1.0;
               label ~text:"last" (* label#12 *);
             ]
           (* row#0 *);
           label ~text:(Fmt.locale ()).tag (* label#13 *);
         ]
         ()
     in
     mount root);

  exit (run app)
