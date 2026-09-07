(* The search scene, OCaml port — guests/rust/search.rs,
   tools/scenes/search.steps. The app owns the filter
   (docs/search-plan.md S9): the visible set is a diff of removes and
   inserts by key. *)

open Kaya_wire
open Kaya_app

type item = { name : string } [@@deriving kaya_gen]

let names = [ "apple"; "banana"; "cherry"; "mango" ]

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0

let () =
  let app = Kaya_app.create () in
  let visible = ref names in

  build app (fun () ->
     let items = collection_of item_record in
     let count = signal (Str (Printf.sprintf "%d items" (List.length names))) in

     let on_query text =
       let query = String.lowercase_ascii text in
       let wanted = List.filter (fun name -> contains name query) names in
       (* A DIFF, never clear-and-refill: only the rows whose membership
          changed move (docs/search-plan.md S9). *)
       List.iter
         (fun name ->
           if not (List.mem name wanted) then
             remove (record_handle items) (Str name))
         !visible;
       List.iter
         (fun name ->
           if not (List.mem name !visible) then
             insert_record items (Str name) { name })
         wanted;
       (* Insertion order is arrival order, so a row coming back lands
          last; walking the wanted keys to the end in order puts the list
          back in [names] order. *)
       List.iter
         (fun name -> move_to_end (record_handle items) (Str name))
         wanted;
       write count
         (Str
            (if query = "" then Printf.sprintf "%d items" (List.length names)
             else
               Printf.sprintf "%d of %d match" (List.length wanted)
                 (List.length names)));
       visible := wanted
     in

     let root =
       column
         [
           search ~placeholder:"Search" ~a11y_id:"find"
             ~a11y_label:"Find items" ~on_change:on_query;
           label ~bind:count ~a11y_id:"count";
           (* The For IS the list: expect_order reads its label children. *)
           (fun () ->
             let w =
               each (record_handle items)
                 (fun () -> Tpl.(label ~bind_field:item_name ()))
                 ()
             in
             set_a11y_id w "list";
             w);
         ]
         ()
     in
     mount root;
     List.iter (fun name -> insert_record items (Str name) { name }) names);

  exit (run app)
