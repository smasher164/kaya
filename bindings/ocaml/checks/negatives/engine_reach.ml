(* The correction slice's O1 negative: the app is ABSTRACT, so the engine
   — 54 handle tables and the collection model — is out of a guest's
   reach; the checks go through For_checks. Run by ../negatives.py. *)
open Kaya_app

let () =
  let app = create () in
  ignore (Hashtbl.length app.widget_handlers)
