(* The table scene from OCaml: column headers and click-to-sort on the
   For vocabulary (docs/tables-plan.md). A header click is a REQUEST —
   this guest reorders its collection BY KEY (the reorder scene's
   idiom) and re-declares the header with the new indicator; the
   platform sorts nothing. The byte-frozen contract is
   tools/scenes/table.steps. *)

open Kaya_wire
open Kaya_app

type table_item = { name : string; size : string } [@@deriving kaya_gen]

(* The guest's sort policy — the platform never has one: clicking the
   sorted column flips it, clicking another starts ascending. *)
let sorted_col = ref (-1)
let sorted_desc = ref false

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let items = collection_of table_item_record in
     (* The For first, because its handle registers the sort handler
        and re-declares the header; [w] slots it into the root after
        (the binding's own handlers-need-the-handle-first idiom). *)
     let table, _ =
       for_each (record_handle items)
         (fun () ->
           Tpl.(
             row
               [
                 label ~bind_field:table_item_name;
                 label ~bind_field:table_item_size;
               ]
               ()))
         ()
     in
     (* Grown on purpose: this scene asserts the fill-and-scroll
        viewport, the grown half of the empty-row ruling — ungrown
        would hug its rows (tables-plan decision 8). *)
     set_grow table 1.0;
     columns table [ "Name"; "Size" ] sort_none;
     on_sort app table (fun column ->
         let desc = !sorted_col = column && not !sorted_desc in
         sorted_col := column;
         sorted_desc := desc;
         let entries = record_items items in
         let key_of (_, item) = if column = 0 then item.name else item.size in
         let ordered =
           List.sort
             (fun a b ->
               let c = compare (key_of a) (key_of b) in
               if desc then -c else c)
             entries
         in
         (* Keys, never indices: moving each key to the end in the
            target order leaves the collection sorted. *)
         List.iter
           (fun (key, _) -> move_to_end (record_handle items) key)
           ordered;
         columns table [ "Name"; "Size" ]
           (if desc then sort_desc column else sort_asc column));
     (* The root is a row so the For's container is the scene's only
        column-kind widget (the reorder scene's rule). *)
     let root = row [ w table ] () in
     mount root;
     insert_record items (Str "b") { name = "banana"; size = "30" };
     insert_record items (Str "a") { name = "apple"; size = "10" };
     insert_record items (Str "c") { name = "cherry"; size = "20" });

  exit (run app)
