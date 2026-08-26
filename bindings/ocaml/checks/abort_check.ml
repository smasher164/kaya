(* The uniform-abort guard: a handler abort rolls the model mirror back,
   ships nothing, and the app continues. Runs headless — the library
   loads (KAYA_LIB) but the core loop is never entered. *)

open Kaya_wire
open Kaya_app

exception Handler_bug

let fail fmt = Printf.ksprintf (fun msg -> prerr_endline msg; exit 1) fmt

let show_key = function
  | Str s -> s
  | Bool b -> string_of_bool b
  | I64 n -> Int64.to_string n
  | F64 x -> string_of_float x
  | Blob h -> Printf.sprintf "blob:%Ld" h

let entry_keys app todos =
  build app (fun () -> List.map fst (items todos))

let expect app todos want what =
  let got = entry_keys app todos in
  if got <> List.map (fun k -> Str k) want then
    fail "%s: [%s]" what (String.concat "; " (List.map show_key got))

(* What a record deriver generates, spelled by hand so this check needs
   no ppx. The blob's MODEL value is the guest's own bytes as a binary
   Str; Kaya_app.encode_field re-registers them at encode time. *)
type check_todo = { ct_title : string; ct_pic : bytes }

let check_todo_rt =
  {
    rt_schema = [ Kaya_wire.value_str; Kaya_wire.value_blob ];
    rt_to_values =
      (fun t -> [ Str t.ct_title; Str (Bytes.to_string t.ct_pic) ]);
    rt_of_values =
      (function
        | [ Str s; Str p ] -> { ct_title = s; ct_pic = Bytes.of_string p }
        | _ -> invalid_arg "check_todo");
  }

let check_todo_ct_pic : (check_todo, bytes) Kaya_app.field = blob_field 1

let () =
  (* ONE ID SPACE: a template node draws from the WIDGET counter, so an
     app hands out one number sequence and the core's two "already
     exists" walls can never fire on an id this binding minted
     (DESIGN.md, Binding conventions). Its own app, run first, so the
     sequence starts at 1. THE CONTIGUOUS RUN IS THE ASSERTION, not
     inequality — a private node counter restarted at 1 sits under the
     live ids an app has already spent and passes a [<>] while being
     exactly the defect. *)
  let id_app = create () in
  let ids =
    build id_app (fun () ->
        let (Widget live) = label ~text:"live" () in
        let rows = collection () in
        let node = ref 0L in
        (* The For's own container is a live widget; the node is inside. *)
        let site_w, () =
          for_each rows
            (fun () ->
              let (Node n) = Tpl.label ~text:"row" () in
              node := n)
            ()
        in
        let (Widget site) = site_w in
        let (Widget after) = label ~text:"live" () in
        [ live; site; !node; after ])
  in
  if ids <> [ 1L; 2L; 3L; 4L ] then
    fail "widget/node ids [%s] — want [1; 2; 3; 4] from one counter"
      (String.concat "; " (List.map Int64.to_string ids));

  let app = create () in
  let todos =
    build app
      (fun () ->
       let todos = collection () in
       insert todos (Str "a") (Str "one");
       insert todos (Str "b") (Str "two");
       todos)
  in

  (* Abort mid-transaction after mutating: the boundary must restore the
     mirror and re-raise. *)
  (match
     build app (fun () ->
         insert todos (Str "c") (Str "three");
         remove todos (Str "a");
         raise Handler_bug)
   with
  | () -> fail "build swallowed the exception — the tx boundary must propagate"
  | exception Handler_bug -> ());
  expect app todos [ "a"; "b" ] "abort did not restore the mirror";

  (* The dispatch discipline: a raising handler is logged and the loop
     continues. *)
  dispatch app (fun () ->
      insert todos (Str "d") (Str "four");
      raise Handler_bug);
  expect app todos [ "a"; "b" ] "dispatch abort leaked into the mirror";
  build app (fun () -> insert todos (Str "c") (Str "three"));
  expect app todos [ "a"; "b"; "c" ] "post-abort commit broken";

  (* An aborted transaction abandons its derived registrations with
     its records: the pending list promotes only on submit. *)
  let rc_cid = ref 0L in
  dispatch app (fun () ->
      let rc = collection_of check_todo_rt in
      let _count =
        derive rc (fun entries -> I64 (Int64.of_int (List.length entries)))
      in
      rc_cid := (record_handle rc).cid;
      raise Handler_bug);
  (match Hashtbl.find_opt app.derived !rc_cid with
  | None | Some [] -> ()
  | Some fns -> fail "aborted tx leaked %d derived registrations" (List.length fns));

  (* The blob field round trip: the model keeps the guest's own bytes. *)
  let pics = build app (fun () -> collection_of check_todo_rt) in
  let png = Bytes.of_string "not really a png" in
  build app (fun () -> insert_record pics (Str "p") { ct_title = "pic"; ct_pic = png });
  (match build app (fun () -> record_items pics) with
  | [ (Str "p", { ct_title = "pic"; ct_pic }) ] when ct_pic = png -> ()
  | _ -> fail "blob field did not round-trip through the model");
  let png2 = Bytes.of_string "different bytes" in
  build app (fun () -> update_field pics (Str "p") check_todo_ct_pic png2);
  (match build app (fun () -> record_items pics) with
  | [ (_, { ct_pic; _ }) ] when ct_pic = png2 -> ()
  | _ -> fail "blob update_field did not update the model's copy");

  (* The record-time mirror-read guard: a model read inside a For or When
     body BEING DECLARED is baked-in dead data and must raise. *)
  (match
     build app (fun () ->
         let _ = for_each todos (fun () -> items todos) () in
         ())
   with
  | () -> fail "For-body mirror read did not raise"
  | exception Failure _ -> ());
  expect app todos [ "a"; "b"; "c" ] "For-body read abort leaked into the mirror";

  let visible = build app (fun () -> signal (Bool false)) in
  (match
     build app (fun () ->
         let _ = when_ visible (fun () -> count todos) () in
         ())
   with
  | () -> fail "When-body mirror read did not raise"
  | exception Failure _ -> ());

  (* Legal: the read after the template scope closes, in the very
     transaction that declared it. *)
  let n =
    build app
      (fun () ->
       let _ = for_each todos (fun _ -> ()) () in
       count todos)
  in
  if n <> 3 then fail "post-scope read broken: %d" n;

  (* The menu construction surface must REACH the record stream: a
     constructor that emits nothing passes every surface gate. The
     ambient transaction's queue is in reach inside build and accumulates
     REVERSED, newest first; each frame is u32 length then u16 kind at
     offset 4, little-endian. *)
  let rec_kind r = Char.code r.[4] lor (Char.code r.[5] lsl 8) in
  let rec_u64 r at =
    let v = ref 0L in
    for i = 7 downto 0 do
      v := Int64.logor (Int64.shift_left !v 8) (Int64.of_int (Char.code r.[at + i]))
    done;
    !v
  in
  let rec_u32 r at =
    let v = ref 0 in
    for i = 3 downto 0 do
      v := (!v lsl 8) lor Char.code r.[at + i]
    done;
    !v
  in
  let contains_sub s sub =
    let n = String.length s and m = String.length sub in
    let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
    m = 0 || go 0
  in
  let queued_since tx before =
    let after = List.length tx.records in
    List.filteri (fun i _ -> i < after - before) tx.records
  in
  let count_kind rs k = List.length (List.filter (fun r -> rec_kind r = k) rs) in
  let file =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        let file =
          menu ~label:"File" [ item ~label:"Save" ~shortcut:"PRIMARY+S" ] ()
        in
        let sort =
          radio_group ~value:1 ~label:"Sort"
            [ option ~label:"Name"; option ~label:"Date" ]
            ()
        in
        window ~menus:[ (fun () -> file); (fun () -> sort) ] ();
        let noun = label ~text:"noun" () in
        context_menu noun [ item ~label:"Rename" ];
        let queued = queued_since tx before in
        (* File, Save, Sort, Name, Date, Rename. *)
        if count_kind queued Kaya_wire.tx_kind_menu_item_create <> 6 then
          fail "menu constructors queued the wrong create count";
        if count_kind queued Kaya_wire.tx_kind_menubar_append <> 2 then
          fail "bar anchors queued the wrong menubar-append count";
        if count_kind queued Kaya_wire.tx_kind_menu_item_append <> 3 then
          fail "children queued the wrong item-append count";
        if count_kind queued Kaya_wire.tx_kind_context_attach <> 1 then
          fail "context anchor queued the wrong attach count";
        if
          not
            (List.exists
               (fun r ->
                 rec_kind r = Kaya_wire.tx_kind_set_menu_prop
                 && contains_sub r "primary+s")
               queued)
        then fail "shortcut did not reach the records canonicalized";
        file)
  in

  (* The binding's one shortcut parser rejects aliases at record time. *)
  (match
     build app (fun () -> menu_append file [ item ~label:"Bad" ~shortcut:"ctrl+s" ])
   with
  | () -> fail "an alias shortcut must die in the binding's one parser"
  | exception Invalid_argument _ -> ());

  (* Append-at-any-time: the retained handle reopens in a later
     transaction — one create plus one append under the RETAINED
     parent, and never a new bar anchor. *)
  build app (fun () ->
      let tx = the_tx () in
      let before = List.length tx.records in
      menu_append file [ item ~label:"Publish" ];
      let queued = queued_since tx before in
      if count_kind queued Kaya_wire.tx_kind_menu_item_create <> 1 then
        fail "reopen queued the wrong create count";
      (match
         List.find_opt
           (fun r -> rec_kind r = Kaya_wire.tx_kind_menu_item_append)
           queued
       with
      | None -> fail "reopen queued no append"
      | Some r ->
          let (MenuItem file_id) = file in
          if rec_u64 r 8 <> file_id then
            fail "reopen did not seat under the retained parent");
      if count_kind queued Kaya_wire.tx_kind_menubar_append <> 0 then
        fail "reopen re-anchored the bar");

  (* An aborted append drops its menu records with everything else. *)
  (match
     build app (fun () ->
         menu_append file [ item ~label:"Doomed" ];
         raise Handler_bug)
   with
  | () -> fail "menu abort: build must propagate"
  | exception Handler_bug -> ());
  build app (fun () -> menu_append file [ item ~label:"Recovered" ]);

  (* The styling surface (docs/styling-plan.md) carries a payload the
     BINDING computes: [~light] and [~dark] become a bitmask, bit 0
     light, bit 1 dark. So read the FRAME the app queued, never the
     arguments a swap would be made in: {u32 seed, u32 mask, u32 light,
     u32 dark} from offset 8, one record per call. *)
  let brand_record what rs =
    match
      List.filter (fun r -> rec_kind r = Kaya_wire.tx_kind_set_brand_accent) rs
    with
    | [ r ] -> r
    | l -> fail "%s queued %d brand records, not one" what (List.length l)
  in
  let brand_call what call =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        call ();
        brand_record what (queued_since tx before))
  in
  let seed_only = brand_call "brand_accent" (fun () -> brand_accent 0x3584E4) in
  if rec_u32 seed_only 8 <> 0x3584E4 then
    fail "the brand seed did not reach the record: %06x" (rec_u32 seed_only 8);
  if rec_u32 seed_only 12 <> 0 then
    fail "a seed-only brand claimed overrides: mask %d" (rec_u32 seed_only 12);
  (* One override at a time: both at once sets every bit and a swap
     survives it. *)
  let light_only =
    brand_call "brand_accent ~light" (fun () -> brand_accent ~light:0x8B0000 0x3584E4)
  in
  if rec_u32 light_only 12 <> 1 then
    fail "~light must set bit 0 alone: mask %d" (rec_u32 light_only 12);
  if rec_u32 light_only 16 <> 0x8B0000 || rec_u32 light_only 20 <> 0 then
    fail "~light landed in the wrong slot: light %06x dark %06x"
      (rec_u32 light_only 16) (rec_u32 light_only 20);
  let dark_only =
    brand_call "brand_accent ~dark" (fun () -> brand_accent ~dark:0xFFFF00 0x3584E4)
  in
  if rec_u32 dark_only 12 <> 2 then
    fail "~dark must set bit 1 alone: mask %d" (rec_u32 dark_only 12);
  if rec_u32 dark_only 20 <> 0xFFFF00 || rec_u32 dark_only 16 <> 0 then
    fail "~dark landed in the wrong slot: light %06x dark %06x"
      (rec_u32 dark_only 16) (rec_u32 dark_only 20);

  (* A dropped [~role] is silent: the widget still appears, merely
     unemphasized, and the scene's a11y read still passes. *)
  let role_values rs =
    List.filter_map
      (fun r ->
        if
          rec_kind r = Kaya_wire.tx_kind_set_property
          && rec_u32 r 16 = Kaya_wire.prop_role
        then Some (rec_u32 r 24, rec_u64 r 32)
        else None)
      rs
  in
  let role_of what call want =
    let got =
      build app (fun () ->
          let tx = the_tx () in
          let before = List.length tx.records in
          ignore (call ());
          role_values (queued_since tx before))
    in
    match got with
    | [ (tag, v) ] when tag = Kaya_wire.value_i64 && v = Int64.of_int want -> ()
    | [ (tag, v) ] ->
        fail "%s queued prop_role as (tag %d, value %Ld), wanted %d" what tag v want
    | l -> fail "%s queued %d role props, not one" what (List.length l)
  in
  role_of "label ~role:Heading" (fun () -> label ~role:Heading ()) Kaya_wire.role_heading;
  role_of "button ~role:Destructive"
    (fun () -> button ~role:Destructive ())
    Kaya_wire.role_destructive;

  (* [~inset] is OPTIONAL on a window and the ABSENCE is a clause of its
     own: the core's default is 16, so a binding-side default would
     full-bleed every window nobody asked about. *)
  let insets rs =
    List.filter_map
      (fun r ->
        if
          rec_kind r = Kaya_wire.tx_kind_set_window_prop
          && rec_u32 r 16 = Kaya_wire.wprop_inset
        then Some (rec_u32 r 24, Int64.float_of_bits (rec_u64 r 32))
        else None)
      rs
  in
  let window_insets call =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        call ();
        insets (queued_since tx before))
  in
  (match window_insets (fun () -> window ~inset:0.0 ()) with
  | [ (tag, v) ] when tag = Kaya_wire.value_f64 && v = 0.0 -> ()
  | [ (tag, v) ] -> fail "window ~inset:0.0 queued (tag %d, %g)" tag v
  | l -> fail "window ~inset:0.0 queued %d inset props, not one" (List.length l));
  (match window_insets (fun () -> window ~inset:12.5 ()) with
  | [ (_, v) ] when v = 12.5 -> ()
  | [ (_, v) ] ->
      fail "window ~inset:12.5 queued %g — the reader is on the padding, not the value" v
  | l -> fail "window ~inset:12.5 queued %d inset props, not one" (List.length l));
  (match window_insets (fun () -> window ()) with
  | [] -> ()
  | (_, v) :: _ ->
      fail "a plain window queued inset %g — an unstated inset must stay unstated, so the core's 16 stands"
        v);

  (* THE CONTAINER INSET is the same prop one level down and shares the
     bare name [inset] with the window's, so read the prop NUMBER, never
     the call. Absence is a clause here too (the core's container default
     is 8), and the record must carry the CONTAINER'S OWN id: a reader on
     the wrong widget agrees with a sugar that padded its child. *)
  let container_insets rs =
    List.filter_map
      (fun r ->
        if
          rec_kind r = Kaya_wire.tx_kind_set_property
          && rec_u32 r 16 = Kaya_wire.prop_inset
        then Some (rec_u64 r 8, rec_u32 r 24, Int64.float_of_bits (rec_u64 r 32))
        else None)
      rs
  in
  let inset_call call =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        let (Widget id) = call () in
        (id, container_insets (queued_since tx before)))
  in
  (match inset_call (fun () -> row ~inset:8.0 [ label ~text:"in" ] ()) with
  | id, [ (on, tag, v) ] when on = id && tag = Kaya_wire.value_f64 && v = 8.0 -> ()
  | id, [ (on, tag, v) ] ->
      fail "row ~inset:8.0 queued (widget %Ld, tag %d, %g), wanted (%Ld, %d, 8)" on tag v
        id Kaya_wire.value_f64
  | _, l -> fail "row ~inset:8.0 queued %d inset props, not one" (List.length l));
  (* The absence: a defaulted [?inset] shows up here as an
     unasked-for 0. *)
  (match inset_call (fun () -> row ~spacing:4.0 [ label ~text:"in" ] ()) with
  | _, [] -> ()
  | _, (_, _, v) :: _ ->
      fail "a plain row queued inset %g — an unstated inset must stay unstated, so the core's 8 stands"
        v);
  (match inset_call (fun () -> grid ~columns:2 ~inset:4.5 [ label ~text:"in" ] ()) with
  | _, [ (_, _, v) ] when v = 4.5 -> ()
  | _, [ (_, _, v) ] ->
      fail "grid ~inset:4.5 queued %g — the reader is on the padding, not the value" v
  | _, l -> fail "grid ~inset:4.5 queued %d inset props, not one" (List.length l));
  (* The dynamic path reaches the same record as the labeled one. *)
  (match
     inset_call (fun () ->
         let c = column [ label ~text:"in" ] () in
         set_inset c 2.0;
         c)
   with
  | id, [ (on, _, v) ] when on = id && v = 2.0 -> ()
  | id, [ (on, _, v) ] ->
      fail "set_inset queued (widget %Ld, %g), wanted (%Ld, 2)" on v id
  | _, l -> fail "set_inset queued %d inset props, not one" (List.length l));

  (* THE NESTED TABLE (docs/tables-plan.md, dynamic tables). Read off
     the RECORDS the binding queued, never the arguments handed in: the
     one thing a keyed re-declaration can get wrong and still look right
     is the ORDER of its values, and keys-before-titles is invisible
     from the call. *)
  let header_records rs =
    List.filter (fun r -> rec_kind r = Kaya_wire.tx_kind_set_column_headers) rs
  in
  (* {u64 widget, u32 sorted, u32 direction, u32 count, u32 path_len}
     then encode_values' own {u32 len, u32 pad} at 32 and the values
     from 40 — path_len keys first, then count titles. *)
  let header_fields r =
    let byte i = Char.code r.[i] in
    let count = rec_u32 r 24 and path_len = rec_u32 r 28 in
    let at = ref 40 in
    let values =
      List.init (path_len + count) (fun _ ->
          let v, next = Kaya_wire.parse_value byte !at in
          at := next;
          v)
    in
    (rec_u64 r 8, rec_u32 r 16, rec_u32 r 20, count, path_len, values)
  in
  let one_header what rs =
    match header_records rs with
    | [ r ] -> header_fields r
    | l -> fail "%s queued %d header records, not one" what (List.length l)
  in
  let show_values vs = String.concat "; " (List.map show_key vs) in
  let accounts = build app (fun () -> collection ()) in
  let sorted_at = ref [] in
  let node, template_bar =
    build app
      (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        let _, node =
          for_each accounts
            (fun () ->
              (* Declared INSIDE the template scope — the nested
                 collection's own-scope wall. *)
              let positions = Tpl.collection () in
              let node, () =
                Tpl.for_each positions
                  (fun () ->
                    ignore
                      Tpl.(row [ label ~text:"sym"; label ~text:"qty" ] ()))
                  ()
              in
              (* After the nested For closed, inside the still-open
                 parent scope: where the template-zone header op finds
                 its For. *)
              Tpl.columns
                ~on_sort:(fun keys column ->
                  sorted_at := (keys, column) :: !sorted_at)
                node [ "Symbol"; "Qty" ] sort_none;
              ignore Tpl.(column [ w node ] ());
              node)
            ()
        in
        (node, one_header "Tpl.columns" (queued_since tx before)))
  in
  let (Node node_id) = node in
  (match template_bar with
  | id, sorted, _, 2, 0, [ Str "Symbol"; Str "Qty" ] when id = node_id ->
      if sorted <> 0xFFFFFFFF then
        fail "Tpl.columns sent sort_none as %d, not the no-indicator sentinel"
          sorted
  | id, _, _, count, path_len, values ->
      fail
        "Tpl.columns queued (widget %Ld, count %d, path_len %d, [%s]), wanted \
         the template node %Ld with 2 titles and no keys"
        id count path_len (show_values values) node_id);

  (* One copy's arrows: the keys the handler received, handed straight
     back. *)
  let keyed_bar =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        columns_at node [ Str "acct-a" ] [ "Symbol"; "Qty" ] (sort_desc 1);
        one_header "columns_at" (queued_since tx before))
  in
  (match keyed_bar with
  | id, 1, 1, 2, 1, [ Str "acct-a"; Str "Symbol"; Str "Qty" ] when id = node_id
    ->
      ()
  | id, sorted, direction, count, path_len, values ->
      fail
        "columns_at queued (widget %Ld, sorted %d, direction %d, count %d, \
         path_len %d, [%s]), wanted the template node %Ld, descending on 1, \
         and the copy's key BEFORE both titles"
        id sorted direction count path_len (show_values values) node_id);

  (* The registration is in [node_sorts] under the NODE's id — the one
     table the keyed sort_requested arm looks in. The live [sort_handlers]
     needs no clause here: its value type is [int -> unit], so filing a
     copy handler there does not compile (watched 2026-08-24). *)
  (match Hashtbl.find_opt app.node_sorts node_id with
  | None ->
      fail "Tpl.columns ~on_sort registered nothing under the template node"
  | Some handler -> handler [ Str "acct-a" ] 1);
  (match !sorted_at with
  | [ ([ Str "acct-a" ], 1) ] -> ()
  | l ->
      fail
        "the copy's sort handler saw [%s], wanted one request carrying its \
         own key then the column"
        (String.concat ", "
           (List.map
              (fun (keys, column) ->
                Printf.sprintf "([%s], %d)" (show_values keys) column)
              l)));

  (* The LIVE half of the same labelled argument, which no OCaml scene
     asserts either: a bare [columns ~on_sort] files under the FOR's own
     widget id, the table the UNKEYED sort_requested arm reads. *)
  let live_sorted = ref [] in
  let live_table =
    build app (fun () ->
        let table, () =
          for_each accounts
            (fun () -> ignore Tpl.(row [ label ~text:"sym"; label ~text:"qty" ] ()))
            ()
        in
        columns
          ~on_sort:(fun column -> live_sorted := column :: !live_sorted)
          table [ "Symbol"; "Qty" ] sort_none;
        table)
  in
  let (Widget live_id) = live_table in
  (match Hashtbl.find_opt app.sort_handlers live_id with
  | None -> fail "columns ~on_sort registered nothing at the live For"
  | Some handler -> handler 1);
  (match !live_sorted with
  | [ 1 ] -> ()
  | l ->
      fail "the live sort handler saw [%s], wanted one request on column 1"
        (String.concat ", " (List.map string_of_int l)));

  (* THE ROW'S OWN FIELDS. A nested table is FOR rows that carry named
     fields, and until 2026-08-25 nothing narrowed a record collection to
     one stamped copy — a guest had to rebuild the record by hand from
     [record_handle] (docs/deferred.md, the nested-record-collection
     gap). Both halves lie in ways that COMPILE: a collection born with
     the scalar schema, and a narrowing that addresses the parent. So
     both are read off the queued records, and the model read is the
     half the wire cannot show. *)
  let positions_rt =
    {
      rt_schema = [ Kaya_wire.value_str; Kaya_wire.value_str ];
      rt_to_values = (fun (sym, qty) -> [ Str sym; Str qty ]);
      rt_of_values =
        (function [ Str s; Str q ] -> (s, q) | _ -> invalid_arg "position");
    }
  in
  let nested_recs, nested_positions =
    build app
      (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        let _, positions =
          for_each accounts
            (fun () ->
              (* THE TEMPLATE ZONE'S OWN CONSTRUCTOR, beside
                 [Tpl.collection] and record-schema'd. *)
              let positions = Tpl.collection_of positions_rt in
              let node, () =
                Tpl.for_each (record_handle positions)
                  (fun () ->
                    ignore
                      Tpl.(
                        row
                          [
                            label ~bind_field:(str_field 0);
                            label ~bind_field:(str_field 1);
                          ]
                          ()))
                  ()
              in
              ignore Tpl.(column [ w node ] ());
              positions)
            ()
        in
        (queued_since tx before, positions))
  in
  (match
     List.filter
       (fun r -> rec_kind r = Kaya_wire.tx_kind_create_collection)
       nested_recs
   with
  | [ r ] when rec_u32 r 16 = 1 && rec_u32 r 24 = 2 -> ()
  | [ r ] ->
      fail
        "the nested collection's schema is %d variant(s) of %d field(s), \
         wanted 1 of 2 — a record collection born with the scalar schema \
         typechecks and leaves every row one string wide"
        (rec_u32 r 16) (rec_u32 r 24)
  | l ->
      fail "the nested template queued %d create_collection records, wanted 1"
        (List.length l));
  (* Born INSIDE the parent's scope: [queued_since] hands the run back
     NEWEST FIRST, so the create_for is last and the template_ends come
     before the collection's birth in this order. *)
  let ordered = List.rev nested_recs in
  let position_of k =
    let rec go i = function
      | [] -> -1
      | r :: rest -> if rec_kind r = k then i else go (i + 1) rest
    in
    go 0 ordered
  in
  let opened = position_of Kaya_wire.tx_kind_create_for in
  let born = position_of Kaya_wire.tx_kind_create_collection in
  let ended =
    let rec last i best = function
      | [] -> best
      | r :: rest ->
          last (i + 1)
            (if rec_kind r = Kaya_wire.tx_kind_template_end then i else best)
            rest
    in
    last 0 (-1) ordered
  in
  if opened < 0 || born < opened || born > ended then
    fail
      "the nested collection is record %d, outside the parent's template \
       scope (%d..%d). A collection declared in the LIVE zone is one table \
       for every copy, not one per copy"
      born opened ended;

  (* [record_at] keeps the element type, so this is the record insert. *)
  let copy_recs =
    build app (fun () ->
        let tx = the_tx () in
        let before = List.length tx.records in
        insert_record
          (record_at nested_positions (Str "brokerage"))
          (Str "aapl") ("AAPL", "10");
        queued_since tx before)
  in
  (match
     List.filter
       (fun r -> rec_kind r = Kaya_wire.tx_kind_collection_insert)
       copy_recs
   with
  | [ r ] when rec_u32 r 16 = 1 ->
      if not (contains_sub r "AAPL" && contains_sub r "10") then
        fail "the record insert did not carry both of the record's fields"
  | [ r ] ->
      fail
        "the record insert carries path_len %d, wanted 1 — a narrowing that \
         drops the key writes the PARENT's table with no error anywhere"
        (rec_u32 r 16)
  | l ->
      fail "the typed record_at queued %d collection_insert records, wanted 1"
        (List.length l));
  (match
     build app (fun () ->
         ( record_items (record_at nested_positions (Str "brokerage")),
           record_items nested_positions ))
   with
  | [ (Str "aapl", ("AAPL", "10")) ], [] -> ()
  | copy, own ->
      fail
        "the copy's model holds %d entr(y/ies) and the collection's own table \
         %d, wanted one record in the copy and nothing in the parent"
        (List.length copy) (List.length own));

  print_endline "ocaml abort check: OK"
