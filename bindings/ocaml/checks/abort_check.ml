(* The uniform-abort guard: a handler abort rolls the model mirror
   back, ships nothing, and the app continues — the same observable
   semantics as every other binding (the negative test each language
   carries). Runs headless: the library loads (KAYA_LIB) but the core
   loop is never entered; records queue and the process exits. *)

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

(* The honest floor a record deriver generates, spelled by hand so the
   check needs no ppx: one string field and one blob (bytes) field.
   The blob's MODEL value is the guest's own bytes as a binary Str;
   the wire side re-registers them at encode time (handles are
   single-submit) — see Kaya_app.encode_field. *)
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

  (* Abort mid-transaction after mutating: the boundary must restore
     the mirror and re-raise (rollback + propagate is the tx
     boundary's contract; surviving is the dispatch loop's). *)
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
     continues — the next transaction works and sees the restored
     model. *)
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

  (* The blob field round trip: the model keeps the guest's own bytes
     — record_items reads back exactly what was written — while
     insert and update_field each register a fresh copy with the core
     at encode time (headless-safe: registration only copies into the
     pending table, drained by the next submit). *)
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

  (* The record-time mirror-read guard: a template body records once
     and the core replays it, so a model read inside a For or When
     body being declared is baked-in dead data — it must raise. The
     same read in a build tx, or after the scope closes, stays legal
     (the entry_keys reads above pin the build-tx side). *)
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

  print_endline "ocaml abort check: OK"
