(* The search scene, OCaml port — guests/rust/search.rs,
   tools/scenes/search.steps. The app owns the predicate
   (docs/search-plan.md S9) and each row hides in place
   (docs/hidden-plan.md). *)

open Kaya_app

type item = { name : string; unmatched : bool } [@@deriving kaya_gen]

let names = [ "apple"; "banana"; "cherry"; "mango" ]

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"search" ();
     let items = collection_of item_record in
     let count = signal Scalar.Str ((Printf.sprintf "%d items" (List.length names))) in

     let on_query text =
       let query = String.lowercase_ascii text in
       let wanted = List.filter (fun name -> contains name query) names in
       List.iter
         (fun name ->
           update_field items (Key.str name) item_unmatched
             (not (contains name query)))
         names;
       write count
         (if query = "" then Printf.sprintf "%d items" (List.length names)
          else
            Printf.sprintf "%d of %d match" (List.length wanted)
              (List.length names))
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
                 (fun () ->
                   Tpl.(
                     let l = label ~bind_field:item_name () in
                     bind_hidden_field l item_unmatched;
                     l))
                 ()
             in
             set_a11y_id w "list";
             w);
         ]
         ()
     in
     mount root;
     List.iter
       (fun name -> insert_record items (Key.str name) { name; unmatched = false })
       names);

  exit (run app)
