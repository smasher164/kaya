(* The reorder scene, OCaml port — guests/rust/reorder.rs,
   tools/scenes/reorder.steps. *)

open Kaya_wire
open Kaya_app

type item = { title : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let items = collection_of item_record in
     let on_rotate () =
       let entries = record_items items in
       let first, _ = List.hd entries in
       move_to_end (record_handle items) first
     in
     let on_lift () =
       (* Keys, never indices. *)
       let entries = record_items items in
       let last, _ = List.nth entries (List.length entries - 1) in
       move_to_front (record_handle items) last
     in

     let root =
       row
         [
           button ~text:"rotate" ~on_click:on_rotate;
           button ~text:"lift" ~on_click:on_lift;
           each (record_handle items)
             (fun () -> Tpl.(label ~bind_field:item_title ()));
         ]
         ()
     in
     mount root;
     insert_record items (Str "a") { title = "a" };
     insert_record items (Str "b") { title = "b" };
     insert_record items (Str "c") { title = "c" });

  exit (run app)
