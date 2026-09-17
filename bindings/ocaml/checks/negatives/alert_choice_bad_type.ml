(* The correction slice's X1 negative: an alert answers a closed
   Alert_choice.t, so the magic integer a guest used to compare against
   is refused at compile time. Run by ../negatives.py. *)
open Kaya_app

let () =
  let app = create () in
  build app (fun () ->
      ignore
        (show_alert ~cancel:"Keep" ~on_result:(fun choice -> ignore (choice = 1)) ()))
