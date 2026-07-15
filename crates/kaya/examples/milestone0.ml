(* The milestone-2 scene from OCaml through the direct ring tier: OCaml
   reads the occurrence ring with its own loads, and answers with packed
   transaction records through kaya_submit. The scene declares a When
   (the extras banner) and a nested For (groups holding items); clicks on
   stamped remove buttons come back as a template node id plus key path,
   and the app answers by removing that entry. The C boundary is crossed
   only to start the core, to wait on an empty ring, and to submit.

   The data path is two-layer, the way ocaml-uring binds the real
   io_uring. A Bigarray wraps the ring's memory, so record parsing
   compiles to inline loads — no FFI, and byte-wise through the char
   kind, so nothing boxes (int32/int64 Bigarray elements would allocate
   per read). The head/tail cursors need ordering that OCaml does not
   expose for foreign memory (Atomic covers OCaml-heap cells only), so
   two noalloc C stubs (milestone0_ml_stubs.c) carry the acquire load
   and release store as bare C calls. The transaction side needs no
   atomics at all: pack records into a Buffer, one submit per batch.

   The blocking calls are bound with ~release_runtime_lock so the OCaml
   runtime keeps running while the C side blocks.

   Build the library first (cargo build), then:
       ocamlfind ocamlopt -package ctypes,ctypes-foreign,threads.posix \
           -linkpkg milestone0_ml_stubs.c milestone0.ml -o milestone0-ocaml *)

open Ctypes
open Foreign

let library_path () =
  match Sys.getenv_opt "KAYA_LIB" with
  | Some lib -> lib
  | None ->
      let candidates =
        [ "target/debug/libkaya.dylib"; "target/debug/libkaya.so" ]
      in
      (try List.find Sys.file_exists candidates
       with Not_found ->
         failwith "libkaya not found; build with cargo or set KAYA_LIB")

let lib = Dl.dlopen ~filename:(library_path ()) ~flags:[ Dl.RTLD_NOW ]

(* KayaRingInfo, as declared in kaya.h. *)
type ring_info
let ring_info : ring_info structure typ = structure "KayaRingInfo"
let ri_data = field ring_info "data" (ptr uint8_t)
let ri_capacity = field ring_info "capacity" uint32_t
let ri_head = field ring_info "head" (ptr uint32_t)
let ri_tail = field ring_info "tail" (ptr uint32_t)
let () = seal ring_info

let kaya_run =
  foreign ~from:lib ~release_runtime_lock:true "kaya_run"
    (void @-> returning int32_t)

let kaya_occurrence_ring =
  foreign ~from:lib "kaya_occurrence_ring" (ptr ring_info @-> returning void)

let kaya_wait_occurrences =
  foreign ~from:lib ~release_runtime_lock:true "kaya_wait_occurrences"
    (void @-> returning bool)

let kaya_submit =
  foreign ~from:lib "kaya_submit" (string @-> size_t @-> returning void)

(* The ordered cursor accesses; see milestone0_ml_stubs.c. *)
external load_acquire_u32 : nativeint -> int = "kaya_ml_load_acquire_u32"
  [@@noalloc]
external store_release_u32 : nativeint -> int -> unit
  = "kaya_ml_store_release_u32"
  [@@noalloc]

let button_clicked = 1 (* KAYA_OCCURRENCE_BUTTON_CLICKED *)

(* KAYA_TX_* record kinds and value/source tags from kaya.h. *)
let tx_create_signal = 1
let tx_write_signal = 2
let tx_create_widget = 3
let tx_set_property = 4
let tx_add_child = 5
let tx_mount = 6
let tx_create_collection = 7
let tx_collection_insert = 8
let tx_collection_update = 9
let tx_collection_remove = 10
let tx_create_for = 11
let tx_create_when = 12
let tx_template_end = 13
let kind_column = 1l
let kind_button = 2l
let kind_label = 3l
let prop_text = 1l
let source_const = 0l
let source_signal = 1l
let source_element = 2l
let value_bool = 1l
let value_str = 4l

(* Guest-allocated ids, counted from 1 per space. *)
let sig_status = 1L
let sig_extras = 2L
let w_column = 1L
let w_step = 2L
let w_status = 3L
let w_when = 4L
let w_groups = 5L
let c_groups = 1L
let c_items = 2L
let n_banner = 1L
let n_group_col = 2L
let n_group_lbl = 3L
let n_items_for = 4L
let n_item_row = 5L
let n_item_text = 6L
let n_remove = 7L

(* --- Transaction packing (KAYA_TX_* layouts from kaya.h) --------------

   Each record is {u32 size, u16 kind, u16 flags}, body, padded to 8;
   the body is packed separately so the size is known up front. Values
   are self-padded to 8, since they concatenate inside bodies. *)

let pad8 b =
  while Buffer.length b mod 8 <> 0 do
    Buffer.add_char b '\000'
  done

let record tx kind body =
  let size = 8 + Buffer.length body in
  let padded = (size + 7) land lnot 7 in
  Buffer.add_int32_le tx (Int32.of_int padded);
  Buffer.add_int16_le tx kind;
  Buffer.add_int16_le tx 0;
  Buffer.add_buffer tx body;
  Buffer.add_string tx (String.make (padded - size) '\000')

let body pack =
  let b = Buffer.create 64 in
  pack b;
  b

let str_value b text =
  Buffer.add_int32_le b value_str;
  Buffer.add_int32_le b (Int32.of_int (String.length text));
  Buffer.add_string b text;
  pad8 b

let bool_value b v =
  Buffer.add_int32_le b value_bool;
  Buffer.add_int32_le b 1l;
  Buffer.add_char b (if v then '\001' else '\000');
  pad8 b

(* A key path: {u32 count, u32 reserved, count values}. *)
let path b keys =
  Buffer.add_int32_le b (Int32.of_int (List.length keys));
  Buffer.add_int32_le b 0l;
  List.iter (str_value b) keys

let submit tx =
  let bytes = Buffer.contents tx in
  kaya_submit bytes (Unsigned.Size_t.of_int (String.length bytes))

let widget tx id kind =
  record tx tx_create_widget
    (body (fun b ->
         Buffer.add_int64_le b id;
         Buffer.add_int32_le b kind;
         Buffer.add_int32_le b 0l))

let text_const tx id text =
  record tx tx_set_property
    (body (fun b ->
         Buffer.add_int64_le b id;
         Buffer.add_int32_le b prop_text;
         Buffer.add_int32_le b source_const;
         str_value b text))

let text_element tx id level =
  record tx tx_set_property
    (body (fun b ->
         Buffer.add_int64_le b id;
         Buffer.add_int32_le b prop_text;
         Buffer.add_int32_le b source_element;
         Buffer.add_int32_le b level;
         Buffer.add_int32_le b 0l))

let two_u64 tx kind a b_ =
  record tx kind
    (body (fun b ->
         Buffer.add_int64_le b a;
         Buffer.add_int64_le b b_))

let collection tx id =
  record tx tx_create_collection (body (fun b -> Buffer.add_int64_le b id))

let template_end tx = record tx tx_template_end (body (fun _ -> ()))

let insert tx coll at key value =
  record tx tx_collection_insert
    (body (fun b ->
         Buffer.add_int64_le b coll;
         path b at;
         str_value b key;
         str_value b value))

let update tx coll at key value =
  record tx tx_collection_update
    (body (fun b ->
         Buffer.add_int64_le b coll;
         path b at;
         str_value b key;
         str_value b value))

let remove tx coll at key =
  record tx tx_collection_remove
    (body (fun b ->
         Buffer.add_int64_le b coll;
         path b at;
         str_value b key))

let write_str tx sig_ text =
  record tx tx_write_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_;
         str_value b text))

let write_bool tx sig_ v =
  record tx tx_write_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_;
         bool_value b v))

let scene_tx () =
  let tx = Buffer.create 1024 in
  record tx tx_create_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_status;
         str_value b "step 0"));
  record tx tx_create_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_extras;
         bool_value b false));
  widget tx w_column kind_column;
  widget tx w_step kind_button;
  text_const tx w_step "step";
  widget tx w_status kind_label;
  record tx tx_set_property
    (body (fun b ->
         Buffer.add_int64_le b w_status;
         Buffer.add_int32_le b prop_text;
         Buffer.add_int32_le b source_signal;
         Buffer.add_int64_le b sig_status));
  (* When(extras): a banner label. The scope brackets the blueprint. *)
  two_u64 tx tx_create_when w_when sig_extras;
  widget tx n_banner kind_label;
  text_const tx n_banner "extras on";
  template_end tx;
  (* For over groups, nesting a For over items. *)
  collection tx c_groups;
  two_u64 tx tx_create_for w_groups c_groups;
  widget tx n_group_col kind_column;
  widget tx n_group_lbl kind_label;
  text_element tx n_group_lbl 0l;
  two_u64 tx tx_add_child n_group_col n_group_lbl;
  collection tx c_items;
  two_u64 tx tx_create_for n_items_for c_items;
  widget tx n_item_row kind_column;
  widget tx n_item_text kind_label;
  text_element tx n_item_text 0l;
  widget tx n_remove kind_button;
  text_const tx n_remove "remove";
  two_u64 tx tx_add_child n_item_row n_item_text;
  two_u64 tx tx_add_child n_item_row n_remove;
  template_end tx;
  two_u64 tx tx_add_child n_group_col n_items_for;
  template_end tx;
  two_u64 tx tx_add_child w_column w_step;
  two_u64 tx tx_add_child w_column w_status;
  two_u64 tx tx_add_child w_column w_when;
  two_u64 tx tx_add_child w_column w_groups;
  two_u64 tx tx_mount 0L w_column;
  (* window 0: the default *)
  submit tx

(* Record layout as declared in kaya.h: header { u32 size; u16 kind;
   u16 flags }, payload inline, little-endian, 8-byte aligned. Reads are
   assembled from bytes; kaya v1 targets are all little-endian. *)
let byte data i = Char.code (Bigarray.Array1.get data i)
let u16 data i = byte data i lor (byte data (i + 1) lsl 8)
let u32 data i = u16 data i lor (u16 data (i + 2) lsl 16)

(* One click record: header, u64 id, u32 path_len, u32 pad, values. The
   ids kaya hands back are guest-allocated and small; the low u32 is the
   whole story. *)
let parse_click data at =
  let id = u32 data (at + 8) in
  let path_len = u32 data (at + 16) in
  let keys = ref [] in
  let p = ref (at + 24) in
  for _ = 1 to path_len do
    let vlen = u32 data (!p + 4) in
    keys := String.init vlen (fun i -> Bigarray.Array1.get data (!p + 8 + i)) :: !keys;
    p := !p + 8 + ((vlen + 7) land lnot 7)
  done;
  (id, List.rev !keys)

let app () =
  let info = make ring_info in
  kaya_occurrence_ring (addr info);
  let capacity = Unsigned.UInt32.to_int (getf info ri_capacity) in
  let mask = capacity - 1 in
  let data =
    bigarray_of_ptr array1 capacity Bigarray.char
      (coerce (ptr uint8_t) (ptr char) (getf info ri_data))
  in
  let head_addr = raw_address_of_ptr (to_voidp (getf info ri_head)) in
  let tail_addr = raw_address_of_ptr (to_voidp (getf info ri_tail)) in

  scene_tx ();

  let steps = ref 0 in
  let running = ref true in
  let h = ref (load_acquire_u32 head_addr) in
  while !running do
    let t = load_acquire_u32 tail_addr in (* acquire: records below are visible *)
    if !h = t then begin
      if not (kaya_wait_occurrences ()) then running := false (* shutdown *)
    end
    else begin
      let at = !h land mask in
      let size = u32 data at in
      let kind = u16 data (at + 4) in
      if kind = button_clicked then begin
        match parse_click data at with
        | id, [] when Int64.of_int id = w_step ->
            incr steps;
            let tx = Buffer.create 256 in
            (match !steps with
            | 1 ->
                insert tx c_groups [] "g1" "Work";
                insert tx c_items [ "g1" ] "a" "send report";
                insert tx c_items [ "g1" ] "b" "buy milk"
            | 2 ->
                insert tx c_groups [] "g2" "Home";
                insert tx c_items [ "g2" ] "a" "water plants";
                update tx c_groups [] "g1" "Office"
            | _ -> ());
            write_bool tx sig_extras (!steps = 1);
            write_str tx sig_status (Printf.sprintf "step %d" !steps);
            submit tx
        | id, [ group; item ] when Int64.of_int id = n_remove ->
            let tx = Buffer.create 128 in
            remove tx c_items [ group ] item;
            write_str tx sig_status (Printf.sprintf "removed %s/%s" group item);
            submit tx
        | _ -> ()
      end;
      (* The cursors are u32 and wrap; OCaml ints are wider, so wrap by
         hand before handing the space back with a release store. *)
      h := (!h + size) land 0xFFFFFFFF;
      store_release_u32 head_addr !h
    end
  done

let () =
  (* Joined, not abandoned: after kaya_run returns, the core has
     signalled Shutdown, so the app loop ends and the join completes. *)
  let app_thread = Thread.create app () in
  let code = kaya_run () in (* takes over the main thread until the app exits *)
  Thread.join app_thread;
  exit (Int32.to_int code)
