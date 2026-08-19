(* kaya runtime for OCaml guests: loading, the direct-ring occurrence loop,
   and submit. *)

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

let kaya_wake = foreign ~from:lib "kaya_wake" (void @-> returning void)

(* Return the app thread from wait_occurrences. Safe from any thread;
   guests do not name it. *)
let wake () = kaya_wake ()

(* Block until there MAY be something to do: a record arrived, or another
   thread called wake. *)
let wait_occurrences () = kaya_wait_occurrences ()

let kaya_submit =
  foreign ~from:lib "kaya_submit" (string @-> size_t @-> returning void)

let kaya_blob_register =
  foreign ~from:lib "kaya_blob_register"
    (string @-> size_t @-> returning uint64_t)

(* The asset surface (docs/assets-plan.md). [string] carries the name's
   bytes with the length beside it: no NUL terminator is involved. *)
let kaya_asset_open =
  foreign ~from:lib "kaya_asset_open" (string @-> size_t @-> returning uint64_t)

let kaya_asset_bytes =
  foreign ~from:lib "kaya_asset_bytes"
    (uint64_t @-> ptr size_t @-> returning (ptr char))

let kaya_asset_blob =
  foreign ~from:lib "kaya_asset_blob" (uint64_t @-> returning uint64_t)

let kaya_asset_release =
  foreign ~from:lib "kaya_asset_release" (uint64_t @-> returning void)

let kaya_asset_why_not =
  foreign ~from:lib "kaya_asset_why_not"
    (string @-> size_t @-> ptr char @-> size_t @-> returning size_t)

let kaya_occurrence_blob =
  foreign ~from:lib "kaya_occurrence_blob"
    (uint64_t @-> ptr size_t @-> returning (ptr char))

let kaya_occurrence_blob_release =
  foreign ~from:lib "kaya_occurrence_blob_release" (uint64_t @-> returning void)

(* Redeem an occurrence blob for its bytes, and release it. Installed
   into the generated wire module, which opens no library of its own.

   COPY THEN RELEASE, in that order: the pointer borrows core memory
   that the release frees. *)
let occurrence_blob handle =
  let len = allocate size_t (Unsigned.Size_t.of_int 0) in
  let data = kaya_occurrence_blob (Unsigned.UInt64.of_int64 handle) len in
  let n = Unsigned.Size_t.to_int !@len in
  let out =
    if is_null data || n = 0 then ""
    else String.init n (fun i -> !@(data +@ i))
  in
  kaya_occurrence_blob_release (Unsigned.UInt64.of_int64 handle);
  out

let () = Kaya_wire.occurrence_blob := occurrence_blob

let kaya_open_picked =
  foreign ~from:lib ~release_runtime_lock:true "kaya_open_picked"
    (uint64_t @-> uint32_t @-> ptr int64_t @-> ptr uint32_t @-> returning int32_t)

(* Redeem a picked handle for a real Unix.file_descr, plus whether it
   seeks. BLOCKS, possibly for a long time, so call it from a thread you
   chose and post the result back (DESIGN.md, File dialogs).

   THE DESCRIPTOR BECOMES OCAML'S: [Unix.close] closes it exactly once
   and the core keeps no claim. *)
let open_picked handle mode =
  let raw = Ctypes.allocate Ctypes.int64_t 0L in
  let seekable = Ctypes.allocate Ctypes.uint32_t Unsigned.UInt32.zero in
  let rc =
    kaya_open_picked
      (Unsigned.UInt64.of_int64 handle)
      (Unsigned.UInt32.of_int mode)
      raw seekable
  in
  if rc <> 0l then
    failwith
      (Printf.sprintf "kaya: opening the picked file failed (code %ld)" rc);
  let fd : Unix.file_descr =
    Obj.magic (Int64.to_int (Ctypes.( !@ ) raw))
  in
  (fd, Unsigned.UInt32.to_int (Ctypes.( !@ ) seekable) <> 0)

(* The ordered cursor accesses; see kaya_ml_stubs.c. *)
external load_acquire_u32 : nativeint -> int = "kaya_ml_load_acquire_u32"
  [@@noalloc]
external store_release_u32 : nativeint -> int -> unit
  = "kaya_ml_store_release_u32"
  [@@noalloc]

(* ~from:lib like every other binding, never the default handle
   (docs/traps.md, the OCaml ctypes entry). *)
let kaya_spec_hash = foreign ~from:lib "kaya_spec_hash" (void @-> returning int64_t)

(* The host capability word; Kaya_app.capabilities is the surface.
   cap_aux_windows is the core's KAYA_CAP_AUX_WINDOWS written again —
   ctypes has no header to read it from — and
   tools/check-sugar-surface.sh fails if it disagrees with
   crates/kaya/src/scene.rs. *)
let kaya_capabilities =
  foreign ~from:lib "kaya_capabilities" (void @-> returning int64_t)

let cap_aux_windows = 1L
let capability_bits () = kaya_capabilities ()

(* The stale-artifact guard: the loaded library must speak the spec
   revision this binding was generated from. *)
let check_spec () =
  let got = kaya_spec_hash () in
  if got <> Kaya_wire.spec_hash then
    failwith
      (Printf.sprintf
         "kaya: library speaks spec %Lx, this binding was generated from %Lx — \
          rebuild the library or regenerate bindings"
         got Kaya_wire.spec_hash)

let run () =
  check_spec ();
  Int32.to_int (kaya_run ())

(* Submit one transaction: the concatenation of packed records (tx_*
   results from Kaya_wire), applied atomically. *)
let submit records =
  let tx = String.concat "" records in
  kaya_submit tx (Unsigned.Size_t.of_int (String.length tx))

(* Register bulk payload bytes with the core, returning the handle (a
   u64 carried as the int64 the Blob wire value takes). The handle is
   CONSUMED by the next submit from this guest, referenced or not. *)
let register_blob data =
  let s = Bytes.to_string data in
  Unsigned.UInt64.to_int64
    (kaya_blob_register s (Unsigned.Size_t.of_int (String.length s)))

(* An open asset. A RECORD rather than a bare int64: [Gc.finalise]
   refuses an immediate, it needs a heap block to attach to. *)
type asset = { handle : int64; mutable live : bool }

let release_handle handle = kaya_asset_release (Unsigned.UInt64.of_int64 handle)

(* The core's sentence for why a name would miss, fetched whole. The
   sentence's one author is [asset_why_not] in
   crates/kaya/src/assets.rs; this only carries it.

   SIZED, THEN READ: the C entry returns the sentence's TRUE length, so
   the first call measures and the second fills. *)
let asset_miss_sentence name =
  let n = Unsigned.Size_t.of_int (String.length name) in
  let len =
    Unsigned.Size_t.to_int
      (kaya_asset_why_not name n
         (Ctypes.from_voidp Ctypes.char Ctypes.null)
         (Unsigned.Size_t.of_int 0))
  in
  if len = 0 then ""
  else begin
    let buf = CArray.make char len in
    ignore
      (kaya_asset_why_not name n (CArray.start buf) (Unsigned.Size_t.of_int len));
    String.init len (fun i -> CArray.get buf i)
  end

(* Open an asset by name; the sentence is the core's, verbatim. *)
let open_asset name =
  let handle =
    Unsigned.UInt64.to_int64
      (kaya_asset_open name (Unsigned.Size_t.of_int (String.length name)))
  in
  if handle = 0L then failwith (asset_miss_sentence name)
  else begin
    let a = { handle; live = true } in
    (* THE FINALISER TAKES ITS SUBJECT AS AN ARGUMENT and closes over
       nothing: a finaliser that captured [a] from this scope would keep
       [a] reachable forever and never run. *)
    Gc.finalise (fun a -> if a.live then release_handle a.handle) a;
    a
  end

(* This asset's bytes, copied out of core memory: the pointer borrows
   the core's buffer only until release. *)
let asset_bytes a =
  if not a.live then
    failwith
      "kaya: this asset is closed — an asset's bytes live in the core until \
       asset_close, and a use after that has nothing to read; open it again \
       with asset";
  let len = allocate size_t (Unsigned.Size_t.of_int 0) in
  let data = kaya_asset_bytes (Unsigned.UInt64.of_int64 a.handle) len in
  let n = Unsigned.Size_t.to_int !@len in
  if is_null data || n = 0 then Bytes.empty
  else Bytes.init n (fun i -> !@(data +@ i))

(* Register this asset's bytes into the pending table and answer with the
   handle the record carries. *)
let asset_blob a =
  if not a.live then
    failwith
      "kaya: this asset is closed — an asset's bytes live in the core until \
       asset_close, and a use after that has nothing to read; open it again \
       with asset";
  Unsigned.UInt64.to_int64 (kaya_asset_blob (Unsigned.UInt64.of_int64 a.handle))

(* Let the core drop these bytes. Idempotent. *)
let asset_close a =
  if a.live then begin
    a.live <- false;
    release_handle a.handle
  end

(* Read the next occurrence if one is ready, WITHOUT blocking; None means
   the ring is empty right now. *)
let poll_occurrence =
  let state = ref None in
  fun () ->
    let data, mask, head_addr, tail_addr, h =
      match !state with
      | Some s -> s
      | None ->
          let info = make ring_info in
          kaya_occurrence_ring (addr info);
          let capacity = Unsigned.UInt32.to_int (getf info ri_capacity) in
          let data =
            bigarray_of_ptr array1 capacity Bigarray.char
              (coerce (ptr uint8_t) (ptr char) (getf info ri_data))
          in
          let head_addr = raw_address_of_ptr (to_voidp (getf info ri_head)) in
          let tail_addr = raw_address_of_ptr (to_voidp (getf info ri_tail)) in
          let s =
            (data, capacity - 1, head_addr, tail_addr,
             ref (load_acquire_u32 head_addr))
          in
          state := Some s;
          s
    in
    let byte i = Char.code (Bigarray.Array1.get data i) in
    let rec scan () =
      let t = load_acquire_u32 tail_addr in (* acquire: records visible *)
      if !h = t then None
      else begin
        let at = !h land mask in
        let size = Kaya_wire.u32_at byte at in
        let kind = Kaya_wire.u16_at byte (at + 4) in
        (* AN UNDO STEP CANNOT RIDE THE SHARED TUPLE, so it travels as
           its own bytes and Kaya_app cuts it up: [parse_occurrence]'s
           generic tail would read `window` as a widget id and the signal
           count as a key-path length, and produce junk SILENTLY. These
           two kinds never reach it. The body is copied out of the ring
           HERE because the space is handed back three lines below. *)
        let undo =
          if kind = Kaya_wire.occ_kind_undone || kind = Kaya_wire.occ_kind_redone
          then Some (String.init (size - 8) (fun i -> Char.chr (byte (at + 8 + i))))
          else None
        in
        let parsed =
          match undo with
          | Some _ ->
              Some (kind, Int64.of_int (Kaya_wire.u32_at byte (at + 8)), [], None, None)
          | None -> Kaya_wire.parse_occurrence (fun i -> byte (at + i))
        in
        (* The cursors are u32 and wrap; OCaml ints are wider, so wrap by
           hand before handing the space back with a release store. *)
        h := (!h + size) land 0xFFFFFFFF;
        store_release_u32 head_addr !h;
        match parsed with
        | Some (kind, id, keys, payload, clip) ->
            Some (kind, id, keys, payload, clip, undo)
        | None -> scan ()
      end
    in
    scan ()
