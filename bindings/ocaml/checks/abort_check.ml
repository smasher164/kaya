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

  print_endline "ocaml abort check: OK"
