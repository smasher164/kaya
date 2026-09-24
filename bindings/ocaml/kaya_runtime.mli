(* kaya runtime for OCaml guests: loading, the direct-ring occurrence
   loop, and submit. The raw ctypes foreign declarations (the ring, the
   kaya_* C entry points) stay private — Kaya_app.ml is the only
   consumer, through the handful of names below that a guest reaches
   only via Kaya_app's own wrappers, plus [open_picked], the one name a
   guest calls directly (redeeming a picked/dropped file's handle off
   the app thread). *)

(* This process's own writable directory, [None] before the platform has
   handed one over. *)
val app_data_dir : unit -> string option

(* The formatter door and the catalog, raw (docs/compliance-plan.md §3):
   packed dates (YYYYMMDD) and times (HHMM), the length as the C API's
   0/1/2, digit counts -1 for the platform's default; [None] is the core's
   fault, already printed. Kaya_app.Fmt and Kaya_app.tr are the surface. *)
val fmt_date : int64 -> int -> string option
val fmt_date_weekday : int64 -> string option
val fmt_time : int64 -> int -> string option
val fmt_date_time : int64 -> int64 -> int -> string option
val fmt_number : float -> int -> int -> bool -> string option
val fmt_percent : float -> int -> int -> bool -> string option
val fmt_currency : float -> string -> string option
val locale_line : unit -> string option
val direction_bit : unit -> int
val text_scale : unit -> float
val catalog : string -> unit

type tr_arg =
  | Tr_int of int64
  | Tr_float of float
  | Tr_str of string
  | Tr_date of int64
  | Tr_time of int64

val tr : string -> (string * tr_arg) list -> string option

val pref_get_string : string -> string option
val pref_get_i64 : string -> int64 option
val pref_get_f64 : string -> float option
val pref_get_bool : string -> bool option
val pref_set_string : string -> string -> unit
val pref_set_i64 : string -> int64 -> unit
val pref_set_f64 : string -> float -> unit
val pref_set_bool : string -> bool -> unit
val pref_remove : string -> unit

(* Redeem a picked handle for a real Unix.file_descr, plus whether it
   seeks. BLOCKS, possibly for a long time, so call it from a thread you
   chose and post the result back (DESIGN.md, File dialogs). THE
   DESCRIPTOR BECOMES OCAML'S: [Unix.close] closes it exactly once and
   the core keeps no claim. *)
val open_picked : int64 -> int -> Unix.file_descr * bool

(* The host capability word; Kaya_app.capabilities is the surface. *)
val cap_aux_windows : int64
val cap_notifications : int64
val capability_bits : unit -> int64

(* Enter the core's run loop, after asserting the loaded library speaks
   this binding's own spec revision. Returns the process's exit code. *)
val run : unit -> int

(* Submit one transaction: the concatenation of packed records (tx_*
   results from Kaya_wire), applied atomically. *)
val submit : string list -> unit

(* Register bulk payload bytes with the core, returning the handle. The
   handle is CONSUMED by the next submit from this guest, referenced or
   not. *)
val register_blob : bytes -> int64

(* AN OPEN ASSET — a RECORD rather than a bare int64, so a [Gc.finalise]
   has a heap block to attach to. Opaque: a guest reads it only through
   [asset_bytes]/[asset_blob]/[asset_close]. *)
type asset

(* The core's sentence for why a name would miss, fetched whole; its one
   author is [asset_why_not] in crates/kaya/src/assets.rs. *)
val asset_miss_sentence : string -> string

(* Open an asset by name; the sentence is the core's, verbatim. *)
val open_asset : string -> asset

(* This asset's bytes, copied out of core memory. *)
val asset_bytes : asset -> bytes

(* Register this asset's bytes into the pending table and answer with
   the handle the record carries. *)
val asset_blob : asset -> int64

(* Let the core drop these bytes. Idempotent. *)
val asset_close : asset -> unit

(* Read the next occurrence if one is ready, WITHOUT blocking; [None]
   means the ring is empty right now. The tuple is (kind, id, keys,
   payload, clip, drop, tail, undo) — [Kaya_app.dispatch_loop]'s own
   shape, folded here because an undo/redo step cannot ride
   [Kaya_wire.parse_occurrence]'s generic tail. *)
val poll_occurrence :
  unit ->
  (int * int64 * Kaya_wire.value list * Kaya_wire.value option
   * (int * Kaya_wire.value list) option * Kaya_wire.drop_values option
   * Kaya_wire.value list * string option)
  option

(* Block until there MAY be something to do: a record arrived, or
   another thread called [wake]. *)
val wait_occurrences : unit -> bool

(* Return the app thread from [wait_occurrences]. Safe from any thread. *)
val wake : unit -> unit
