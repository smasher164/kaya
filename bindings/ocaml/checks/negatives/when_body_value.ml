(* The X3 negative (ruled 2026-09-17): a body-taking live-zone
   constructor ANSWERS WHAT ITS BODY ANSWERED, so [when_] hands back the
   When's container beside the body's result — binding it to a bare
   [widget] must not compile. Run by ../negatives.py. *)
open Kaya_app

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      let flag = signal Scalar.Bool true in
      let (w : widget) = when_ flag (fun () -> Tpl.(label ~text:"on" ())) () in
      ignore w)
