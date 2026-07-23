(* The reorder scene from OCaml: order as collection data, end to end.
   Three stamped rows and two buttons that never touch a widget — each
   handler repositions an entry by key (collection_move on the wire,
   move_child at the toolkit), and the selftest's expect_order reads
   the toolkit's actual child order back. The root is a row so the
   For's container is the scene's only column-kind widget: languages
   disagree on whether containers are created before or after their
   children, and column#0 must name the same widget everywhere.

   Build like milestone2.ml, then run with KAYA_SELFTEST=reorder. *)

open Kaya_wire
open Kaya_app

type item = { title : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let items = collection_of item_record in
     let on_rotate () =
       (* First entry to the end. The model owns the order, so the
          handler asks it which key is first — it never counts
          widgets. *)
       let entries = record_items items in
       let first, _ = List.hd entries in
       move_to_end (record_handle items) first
     in
     let on_lift () =
       (* Last entry to the front: move_to_front is sugar for
          move_before the current first key — the same wire op, keys
          never indices. *)
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
