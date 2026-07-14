(* Milestone 1 from OCaml through the direct ring tier: OCaml reads the
   occurrence ring with its own loads, and answers with packed
   transaction records through kaya_submit. The scene arrives as one
   transaction; the label's text is a signal binding this guest writes on
   every click. The C boundary is crossed only to start the core, to wait
   on an empty ring, and to submit.

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
let kind_column = 1l
let kind_button = 2l
let kind_label = 3l
let prop_text = 1l
let source_const = 0l
let source_signal = 1l
let value_str = 4l

(* Guest-allocated ids, counted from 1 per space. *)
let sig_text = 1L
let w_column = 1L
let w_button = 2L
let w_label = 3L

(* --- Transaction packing (KAYA_TX_* layouts from kaya.h) --------------

   Each record is {u32 size, u16 kind, u16 flags}, body, padded to 8;
   the body is packed separately so the size is known up front. *)

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
  Buffer.add_string b text

let submit tx =
  let bytes = Buffer.contents tx in
  kaya_submit bytes (Unsigned.Size_t.of_int (String.length bytes))

let scene_tx () =
  let tx = Buffer.create 256 in
  record tx tx_create_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_text;
         str_value b "Clicked 0 times"));
  record tx tx_create_widget
    (body (fun b ->
         Buffer.add_int64_le b w_column;
         Buffer.add_int32_le b kind_column;
         Buffer.add_int32_le b 0l));
  record tx tx_create_widget
    (body (fun b ->
         Buffer.add_int64_le b w_button;
         Buffer.add_int32_le b kind_button;
         Buffer.add_int32_le b 0l));
  record tx tx_set_property
    (body (fun b ->
         Buffer.add_int64_le b w_button;
         Buffer.add_int32_le b prop_text;
         Buffer.add_int32_le b source_const;
         str_value b "Click me"));
  record tx tx_create_widget
    (body (fun b ->
         Buffer.add_int64_le b w_label;
         Buffer.add_int32_le b kind_label;
         Buffer.add_int32_le b 0l));
  record tx tx_set_property
    (body (fun b ->
         Buffer.add_int64_le b w_label;
         Buffer.add_int32_le b prop_text;
         Buffer.add_int32_le b source_signal;
         Buffer.add_int64_le b sig_text));
  record tx tx_add_child
    (body (fun b ->
         Buffer.add_int64_le b w_column;
         Buffer.add_int64_le b w_button));
  record tx tx_add_child
    (body (fun b ->
         Buffer.add_int64_le b w_column;
         Buffer.add_int64_le b w_label));
  record tx tx_mount
    (body (fun b ->
         Buffer.add_int64_le b 0L; (* window 0: the default *)
         Buffer.add_int64_le b w_column));
  submit tx

let write_tx text =
  let tx = Buffer.create 64 in
  record tx tx_write_signal
    (body (fun b ->
         Buffer.add_int64_le b sig_text;
         str_value b text));
  submit tx

(* Record layout as declared in kaya.h: header { u32 size; u16 kind;
   u16 flags }, payload inline, little-endian, 8-byte aligned. Reads are
   assembled from bytes; kaya v1 targets are all little-endian. *)
let byte data i = Char.code (Bigarray.Array1.get data i)
let u16 data i = byte data i lor (byte data (i + 1) lsl 8)
let u32 data i = u16 data i lor (u16 data (i + 2) lsl 16)

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

  let count = ref 0 in
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
        incr count;
        let noun = if !count = 1 then "time" else "times" in
        write_tx (Printf.sprintf "Clicked %d %s" !count noun)
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
