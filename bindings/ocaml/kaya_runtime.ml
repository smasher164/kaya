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

(* The app's own places (docs/tasks-s4-plan.md §4): the data directory
   and the typed preferences store. [string] carries bytes with the
   length beside them; no NUL terminator is involved. *)
let kaya_app_data_dir =
  foreign ~from:lib "kaya_app_data_dir"
    (ptr char @-> size_t @-> returning size_t)

let kaya_pref_get_string =
  foreign ~from:lib "kaya_pref_get_string"
    (string @-> size_t @-> ptr char @-> size_t @-> ptr size_t
    @-> returning int)

(* The formatter door and the catalog (docs/compliance-plan.md §3; the C
   API's fill shape: ask with cap 0, size, ask again). *)
let kaya_fmt_date =
  foreign ~from:lib "kaya_fmt_date"
    (int64_t @-> int64_t @-> ptr char @-> size_t @-> returning size_t)

let kaya_fmt_date_weekday =
  foreign ~from:lib "kaya_fmt_date_weekday"
    (int64_t @-> ptr char @-> size_t @-> returning size_t)

let kaya_fmt_time =
  foreign ~from:lib "kaya_fmt_time"
    (int64_t @-> int64_t @-> ptr char @-> size_t @-> returning size_t)

let kaya_fmt_date_time =
  foreign ~from:lib "kaya_fmt_date_time"
    (int64_t @-> int64_t @-> int64_t @-> ptr char @-> size_t
    @-> returning size_t)

type number_options
let number_options : number_options structure typ = structure "KayaNumberOptions"
let no_min = field number_options "min_fraction_digits" int32_t
let no_max = field number_options "max_fraction_digits" int32_t
let no_grouping = field number_options "grouping" bool
let () = seal number_options

let kaya_fmt_number =
  foreign ~from:lib "kaya_fmt_number"
    (double @-> ptr number_options @-> ptr char @-> size_t @-> returning size_t)

let kaya_fmt_percent =
  foreign ~from:lib "kaya_fmt_percent"
    (double @-> ptr number_options @-> ptr char @-> size_t @-> returning size_t)

let kaya_fmt_currency =
  foreign ~from:lib "kaya_fmt_currency"
    (double @-> string @-> ptr char @-> size_t @-> returning size_t)

let kaya_locale =
  foreign ~from:lib "kaya_locale" (ptr char @-> size_t @-> returning size_t)

let kaya_direction = foreign ~from:lib "kaya_direction" (void @-> returning uint32_t)
let kaya_text_scale = foreign ~from:lib "kaya_text_scale" (void @-> returning double)
let kaya_catalog = foreign ~from:lib "kaya_catalog" (string @-> returning void)

type tr_arg_c
let tr_arg_c : tr_arg_c structure typ = structure "KayaTrArg"
let ta_name = field tr_arg_c "name" (ptr char)
let ta_tag = field tr_arg_c "tag" uint32_t
let ta_i = field tr_arg_c "i" int64_t
let ta_f = field tr_arg_c "f" double
let ta_s = field tr_arg_c "s" (ptr char)
let () = seal tr_arg_c

let kaya_tr =
  foreign ~from:lib "kaya_tr"
    (string @-> ptr tr_arg_c @-> size_t @-> ptr char @-> size_t @-> returning size_t)

(* Ask with cap 0, size, ask again; [None] is the core's fault (it printed
   the sentence), never a legitimately empty answer. *)
let fill (ask : char ptr -> Unsigned.size_t -> Unsigned.size_t) =
  let len =
    Unsigned.Size_t.to_int
      (ask (Ctypes.from_voidp Ctypes.char Ctypes.null) (Unsigned.Size_t.of_int 0))
  in
  if len = 0 then None
  else begin
    let buf = CArray.make char len in
    let written =
      Unsigned.Size_t.to_int (ask (CArray.start buf) (Unsigned.Size_t.of_int len))
    in
    Some (String.init (min written len) (fun i -> CArray.get buf i))
  end

let fmt_date packed length = fill (kaya_fmt_date packed (Int64.of_int length))
let fmt_date_weekday packed = fill (kaya_fmt_date_weekday packed)
let fmt_time packed length = fill (kaya_fmt_time packed (Int64.of_int length))

let fmt_date_time date time length =
  fill (kaya_fmt_date_time date time (Int64.of_int length))

let with_number_options min max grouping ask =
  let o = make number_options in
  setf o no_min (Int32.of_int min);
  setf o no_max (Int32.of_int max);
  setf o no_grouping grouping;
  fill (ask (addr o))

let fmt_number value min max grouping =
  with_number_options min max grouping (kaya_fmt_number value)

let fmt_percent value min max grouping =
  with_number_options min max grouping (kaya_fmt_percent value)

let fmt_currency value code = fill (kaya_fmt_currency value code)
let locale_line () = fill kaya_locale
let direction_bit () = Unsigned.UInt32.to_int (kaya_direction ())
let text_scale () = kaya_text_scale ()
let catalog app = kaya_catalog app

type tr_arg =
  | Tr_int of int64
  | Tr_float of float
  | Tr_str of string
  | Tr_date of int64
  | Tr_time of int64

(* A C string the GC cannot move: a char array, kept alive past the call. *)
let c_string s =
  let n = String.length s in
  let a = CArray.make char (n + 1) in
  String.iteri (fun i c -> CArray.set a i c) s;
  CArray.set a n '\000';
  a

let tr key args =
  let n = List.length args in
  let records = CArray.make tr_arg_c (max n 1) in
  let keep = ref [] in
  List.iteri
    (fun idx (name, arg) ->
      let r = CArray.get records idx in
      let name_c = c_string name in
      keep := name_c :: !keep;
      setf r ta_name (CArray.start name_c);
      setf r ta_i 0L;
      setf r ta_f 0.0;
      setf r ta_s (Ctypes.from_voidp Ctypes.char Ctypes.null);
      (match arg with
       | Tr_int i -> setf r ta_tag (Unsigned.UInt32.of_int 0); setf r ta_i i
       | Tr_float f -> setf r ta_tag (Unsigned.UInt32.of_int 1); setf r ta_f f
       | Tr_str s ->
           let s_c = c_string s in
           keep := s_c :: !keep;
           setf r ta_tag (Unsigned.UInt32.of_int 2);
           setf r ta_s (CArray.start s_c)
       | Tr_date d -> setf r ta_tag (Unsigned.UInt32.of_int 3); setf r ta_i d
       | Tr_time t -> setf r ta_tag (Unsigned.UInt32.of_int 4); setf r ta_i t);
      CArray.set records idx r)
    args;
  let answer =
    fill (kaya_tr key (CArray.start records) (Unsigned.Size_t.of_int n))
  in
  ignore (Sys.opaque_identity !keep);
  answer

let kaya_pref_get_i64 =
  foreign ~from:lib "kaya_pref_get_i64"
    (string @-> size_t @-> ptr int64_t @-> returning int)

let kaya_pref_get_f64 =
  foreign ~from:lib "kaya_pref_get_f64"
    (string @-> size_t @-> ptr double @-> returning int)

let kaya_pref_get_bool =
  foreign ~from:lib "kaya_pref_get_bool"
    (string @-> size_t @-> ptr uint8_t @-> returning int)

let kaya_pref_set_string =
  foreign ~from:lib "kaya_pref_set_string"
    (string @-> size_t @-> string @-> size_t @-> returning void)

let kaya_pref_set_i64 =
  foreign ~from:lib "kaya_pref_set_i64"
    (string @-> size_t @-> int64_t @-> returning void)

let kaya_pref_set_f64 =
  foreign ~from:lib "kaya_pref_set_f64"
    (string @-> size_t @-> double @-> returning void)

let kaya_pref_set_bool =
  foreign ~from:lib "kaya_pref_set_bool"
    (string @-> size_t @-> uint8_t @-> returning void)

let kaya_pref_remove =
  foreign ~from:lib "kaya_pref_remove" (string @-> size_t @-> returning void)

(* The app's own writable directory, [None] before one exists. SIZED,
   THEN READ, [asset_miss_sentence]'s two-call shape. *)
let app_data_dir () =
  let len =
    Unsigned.Size_t.to_int
      (kaya_app_data_dir
         (Ctypes.from_voidp Ctypes.char Ctypes.null)
         (Unsigned.Size_t.of_int 0))
  in
  if len = 0 then None
  else begin
    let buf = CArray.make char len in
    let written =
      Unsigned.Size_t.to_int
        (kaya_app_data_dir (CArray.start buf) (Unsigned.Size_t.of_int len))
    in
    Some (String.init (min written len) (fun i -> CArray.get buf i))
  end

let pref_get_string key =
  let n = Unsigned.Size_t.of_int (String.length key) in
  let len = allocate size_t (Unsigned.Size_t.of_int 0) in
  if
    kaya_pref_get_string key n
      (Ctypes.from_voidp Ctypes.char Ctypes.null)
      (Unsigned.Size_t.of_int 0) len
    = 0
  then None
  else
    let want = Unsigned.Size_t.to_int !@len in
    if want = 0 then Some ""
    else begin
      let buf = CArray.make char want in
      if
        kaya_pref_get_string key n (CArray.start buf)
          (Unsigned.Size_t.of_int want) len
        = 0
      then None
      else
        let got = min (Unsigned.Size_t.to_int !@len) want in
        Some (String.init got (fun i -> CArray.get buf i))
    end

let pref_get_i64 key =
  let out = allocate int64_t 0L in
  if kaya_pref_get_i64 key (Unsigned.Size_t.of_int (String.length key)) out = 0
  then None
  else Some !@out

let pref_get_f64 key =
  let out = allocate double 0.0 in
  if kaya_pref_get_f64 key (Unsigned.Size_t.of_int (String.length key)) out = 0
  then None
  else Some !@out

let pref_get_bool key =
  let out = allocate uint8_t Unsigned.UInt8.zero in
  if kaya_pref_get_bool key (Unsigned.Size_t.of_int (String.length key)) out = 0
  then None
  else Some (Unsigned.UInt8.to_int !@out <> 0)

let pref_set_string key value =
  kaya_pref_set_string key
    (Unsigned.Size_t.of_int (String.length key))
    value
    (Unsigned.Size_t.of_int (String.length value))

let pref_set_i64 key value =
  kaya_pref_set_i64 key (Unsigned.Size_t.of_int (String.length key)) value

let pref_set_f64 key value =
  kaya_pref_set_f64 key (Unsigned.Size_t.of_int (String.length key)) value

let pref_set_bool key value =
  kaya_pref_set_bool key
    (Unsigned.Size_t.of_int (String.length key))
    (Unsigned.UInt8.of_int (if value then 1 else 0))

let pref_remove key =
  kaya_pref_remove key (Unsigned.Size_t.of_int (String.length key))

let kaya_occurrence_blob =
  foreign ~from:lib "kaya_occurrence_blob"
    (uint64_t @-> ptr size_t @-> returning (ptr char))

let kaya_occurrence_blob_release =
  foreign ~from:lib "kaya_occurrence_blob_release" (uint64_t @-> returning void)

(* Redeem an occurrence blob for its bytes, and release it. COPY THEN
   RELEASE, in that order: the pointer borrows core memory that the
   release frees. *)
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
  (* docs/traps.md: the Obj.magic file_descr cast. *)
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
   tools/check-sugar-surface.py fails if it disagrees with the core. *)
let kaya_capabilities =
  foreign ~from:lib "kaya_capabilities" (void @-> returning int64_t)

let cap_aux_windows = 1L
let cap_notifications = 2L
let cap_badge = 4L
let cap_emoji_picker = 8L
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

(* The core's sentence for why a name would miss, fetched whole; its one
   author is [asset_why_not] in crates/kaya/src/assets.rs. SIZED, THEN
   READ: the C entry returns the sentence's TRUE length, so the first
   call measures and the second fills. *)
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
              Some (kind, Int64.of_int (Kaya_wire.u32_at byte (at + 8)), [], None, None, None, [])
          | None -> Kaya_wire.parse_occurrence (fun i -> byte (at + i))
        in
        (* The cursors are u32 and wrap; OCaml ints are wider, so wrap by
           hand before handing the space back with a release store. *)
        h := (!h + size) land 0xFFFFFFFF;
        store_release_u32 head_addr !h;
        match parsed with
        | Some (kind, id, keys, payload, clip, drop, tail) ->
            Some (kind, id, keys, payload, clip, drop, tail, undo)
        | None -> scan ()
      end
    in
    scan ()
