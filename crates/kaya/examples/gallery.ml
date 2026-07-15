(* The gallery scene from OCaml, on the let* surface: a row container
   laying a checkbox and the status label side by side. The box owns
   its checked bit and reports each flip through on_toggle; the app
   answers by writing the status signal — the same uncontrolled
   contract as the entry, with a bool.

   Build like milestone2.ml, then run with KAYA_SELFTEST=gallery. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in

  let status, urgent =
    build app
      (let* status = signal (Str "urgent: false") in

       let* column = widget kind_column in
       let* row = widget kind_row in
       let* urgent = widget kind_checkbox in
       let* () = set_text urgent "urgent" in
       let* status_label = widget kind_label in
       let* () = bind_text status_label status in

       let* () = add_child row urgent in
       let* () = add_child row status_label in
       let* () = add_child column row in
       let+ () = mount column in
       (status, urgent))
  in

  on_toggle app urgent (fun checked ->
      write status (Str (Printf.sprintf "urgent: %b" checked)));

  exit (run app)
