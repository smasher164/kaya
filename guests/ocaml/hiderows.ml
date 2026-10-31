(* The hidden-rows scene, OCaml port — guests/rust/hiderows.rs,
   tools/scenes/hiderows.steps (docs/hidden-plan.md). *)

open Kaya_app

type hiderows_note = { title : string; unmatched : bool } [@@deriving kaya_gen]

type hiderows_file = { name : string; size : string; unmatched : bool } [@@deriving kaya_gen]

let notes = [ "alpha"; "beta"; "gamma" ]

let file_name i = Printf.sprintf "file %03d" i

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     window ~title:"hiderows" ();
     let note_rows = collection_of hiderows_note_record in
     let file_rows = collection_of hiderows_file_record in
     let two = signal Scalar.Bool false in
     let find_notes query =
       List.iter
         (fun title ->
           update_field note_rows (Key.str title) hiderows_note_unmatched
             (not (contains title query)))
         notes
     in
     let find_files query =
       for i = 0 to 299 do
         update_field file_rows (Key.str (file_name i)) hiderows_file_unmatched
           (not (contains (file_name i) query))
       done
     in
     let note_list =
       each (record_handle note_rows)
         (fun () ->
           Tpl.(
             let line =
               row
                 [ label ~bind_field:hiderows_note_title; entry ~a11y_id:"note" ]
                 ()
             in
             bind_hidden_field line hiderows_note_unmatched;
             line))
         ()
     in
     set_a11y_id note_list "notes";
     let table =
       each (record_handle file_rows)
         (fun () ->
           Tpl.(
             let line =
               row
                 [ label ~bind_field:hiderows_file_name; label ~bind_field:hiderows_file_size ]
                 ()
             in
             bind_hidden_field line hiderows_file_unmatched;
             line))
         ()
     in
     set_a11y_id table "files";
     set_grow table 1.0;
     columns table [ "Name"; "Size" ] sort_none;
     let second () =
       let l = label ~text:"two" () in
       bind_hidden l two;
       l
     in
     let root =
       column
         [
           search ~placeholder:"Find notes" ~a11y_id:"find_notes" ~on_change:find_notes;
           w note_list;
           grid ~columns:2 ~a11y_id:"tiles" [ label ~text:"one"; second; label ~text:"three" ];
           checkbox ~a11y_id:"hide_two" ~text:"Hide two" ~on_toggle:(fun on -> write two on);
           search ~placeholder:"Find files" ~a11y_id:"find_files" ~on_change:find_files;
           w table;
         ]
         ()
     in
     mount root;
     List.iter
       (fun title -> insert_record note_rows (Key.str title) { title; unmatched = false })
       notes;
     for i = 0 to 299 do
       insert_record file_rows (Key.str (file_name i))
         { name = file_name i; size = Printf.sprintf "%d KB" i; unmatched = false }
     done);

  exit (run app)
