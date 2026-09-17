(* F3 negative: a collection key is the typed key (Key.Str/Key.Int),
   never the wire's own value — a raw Kaya_wire.value is refused at
   the typed surface. Run by ../negatives.py. *)
open Kaya_app

let () =
  let app = create () in
  build app (fun () ->
      let notes = collection () in
      insert notes (Kaya_wire.Str "a") "one")
