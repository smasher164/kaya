(* Milestone 0 from OCaml through the direct ring tier: OCaml reads the
   occurrence ring with its own loads, crossing the C boundary only to
   start the core, to wait on an empty ring, and to send commands.

   The data path is two-layer, the way ocaml-uring binds the real
   io_uring. A Bigarray wraps the ring's memory, so record parsing
   compiles to inline loads — no FFI, and byte-wise through the char
   kind, so nothing boxes (int32/int64 Bigarray elements would allocate
   per read). The head/tail cursors need ordering that OCaml does not
   expose for foreign memory (Atomic covers OCaml-heap cells only), so
   two noalloc C stubs (milestone0_ml_stubs.c) carry the acquire load
   and release store as bare C calls.

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

let kaya_set_text =
  foreign ~from:lib "kaya_set_text"
    (uint64_t @-> string @-> size_t @-> returning void)

(* The ordered cursor accesses; see milestone0_ml_stubs.c. *)
external load_acquire_u32 : nativeint -> int = "kaya_ml_load_acquire_u32"
  [@@noalloc]
external store_release_u32 : nativeint -> int -> unit
  = "kaya_ml_store_release_u32"
  [@@noalloc]

let button_clicked = 1 (* KAYA_OCCURRENCE_BUTTON_CLICKED *)
let label = Unsigned.UInt64.of_int 2 (* KAYA_WIDGET_LABEL *)

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
        let text = Printf.sprintf "Clicked %d %s" !count noun in
        kaya_set_text label text (Unsigned.Size_t.of_int (String.length text))
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
