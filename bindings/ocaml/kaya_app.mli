(* kaya's idiomatic surface for OCaml, over kaya_runtime.ml and the
   generated kaya_wire.ml. THE TEMPLATE ZONE IS THE Tpl SUBMODULE. THE
   TRANSACTION IS AMBIENT, so a builder called outside [build] is a loud
   RUNTIME error ([the_tx]). THE TRAILING-UNIT CONVENTION: a creator ends
   in [()]; omit it and the partial application is the [unit -> widget]
   child form, realized left to right ([List.iter]'s specified order —
   never OCaml's unspecified list-literal order).

   Exports only what a guest or a check (bindings/ocaml/checks/*.ml)
   actually calls, plus the ppx's (ppx/kaya_ppx.ml) own generated-code
   needs and the types those signatures require; the raw internal engine
   (the model, the dispatch loop, the wire-keyed Hashtbl plumbing) stays
   reachable only because [app]/[tx] are checks' own test surface, never
   because a guest is meant to touch them. *)

(* A phantom-typed signal handle — the [field] idiom (below) extended to
   signals: [enc] is the one place a signal's value crosses onto the
   wire, so [signal_str]/[signal_bool]/[signal_i64]/[signal_f64] and
   [write] can never mismatch a signal's declared type against what it
   is written. *)
type 'a signal

type widget = Widget of int64
type node = Node of int64

(* A canvas's coordinate system AND its natural size in
   device-independent points (docs/canvas-plan.md §3.2). The op stream is
   written in these units on every platform, so a scene can freeze it. *)
type viewbox = float * float

(* The drawing scope's recorder: the calls read as immediate-mode
   drawing but are recorded, and ONE record is submitted when the scope
   closes (docs/canvas-plan.md §2.1). *)
type draw

(* WHAT THIS HOST CAN DO. [notifications] is a RUNTIME bit: this process
   can post a local notification the desktop will show
   (docs/tasks-s3-plan.md N3). *)
type capabilities = { aux_windows : bool; notifications : bool }

(* This host's capabilities. Constant for the life of the process, so
   asking once and remembering is fine. *)
val capabilities : unit -> capabilities

(* The app's own directory (docs/tasks-s4-plan.md P1): created on first
   ask, raises where the platform has handed no directory over. *)
val app_data_dir : unit -> string

(* The app's preferences store (docs/tasks-s4-plan.md P2/P3): a small
   typed key-value record under the app's id, a PULL not a signal. *)
type prefs = {
  get_string : string -> string -> string;
  get_i64 : string -> int64 -> int64;
  get_f64 : string -> float -> float;
  get_bool : string -> bool -> bool;
  set_string : string -> string -> unit;
  set_i64 : string -> int64 -> unit;
  set_f64 : string -> float -> unit;
  set_bool : string -> bool -> unit;
  remove : string -> unit;
}

val prefs : unit -> prefs

(* A live menu item: its OWN id space, so cross-use with a widget or a
   node handle is a type error. *)
type menu_item = MenuItem of int64

(* A context catalog built UNANCHORED for a template node: menu items
   are live and shared across stamped copies, so the catalog is built
   live and [Tpl.context_menu] attaches it. *)
type context_catalog

(* A collection instance handle: the collection plus the key path
   selecting one stamped copy's table. *)
type collection

(* A collection entry's key: a string or a minted int64, the only two
   shapes [insert]/[insert_fresh] ever produce. The guest-facing type for
   every key a guest spells or reads back — never the wire's own sum.
   [Key.Str "b"], [Key.Int 3L], [Key.text k]. *)
module Key : sig
  type t = Str of string | Int of int64

  val str : string -> t
  val int : int64 -> t
  val text : t -> string
end

type key = Key.t

val key_text : key -> string

(* An alert's three outcomes: the action the user pressed, by its slot,
   or the cancel every platform-native dismissal answers. A TYPE, not an
   int and a sentinel. [of_wire] refuses a number this build does not
   know, naming it. *)
module Alert_choice : sig
  type t = Action0 | Action1 | Cancel

  val of_wire : int -> t
end

(* A notification's two outcomes (docs/tasks-s3-plan.md N1). Dismissal is
   not one of them: two platforms never report it. *)
module Notification_outcome : sig
  type t = Activated | Refused

  val of_wire : int -> t
  val name : t -> string
end

(* The app's OWN light/dark choice, applied process-wide from the
   default window (docs/tasks-s2b-plan.md R1-R3). *)
module Appearance : sig
  type t = System | Light | Dark
end

(* The height the phones open a sheet at (docs/sheet-plan.md §1.4); the
   desktops ignore it. *)
module Detent : sig
  type t = Medium | Large
end

(* How a picked file is re-opened: read, write (truncates; a save
   destination only adds the create) or both. *)
module File_mode : sig
  type t = Read | Write | Read_write
end

(* One file the picker answered with: a handle to redeem, a display
   name, and [local_path] — a RE-OPENABLE NAME, empty unless re-opening
   it actually works (DESIGN.md, File dialogs). *)
type picked_file = { handle : int64; name : string; local_path : string }

(* AN ASSET — a file this app's own BUILD put where the running program
   can find it. A MISS RAISES [Failure] carrying the core's sentence;
   release is explicit ([asset_close]) and automatic (a finaliser). *)
type asset

val asset : string -> asset
val asset_miss_sentence : string -> string
val asset_bytes : asset -> bytes
val asset_close : asset -> unit

(* One signal an undo restored, in the BINDING's terms: the wire's own
   value type never reaches a guest (DESIGN.md, Binding conventions), so
   the restored value is asked for by the type it was written as and
   answers [None] when it was written as another. *)
module Undo_signal : sig
  type t

  val id : t -> int64
  val as_str : t -> string option
  val as_bool : t -> bool option
  val as_i64 : t -> int64 option
  val as_f64 : t -> float option
end

(* One collection entry's restored state, as the core states it —
   internal to [Undo_delta.t.entries]; a guest reads deltas through
   [Undo_text], never this. *)
module Undo_entry : sig
  type t
end

(* One collection instance's restored key order — internal to
   [Undo_delta.t.orders]. *)
module Undo_order : sig
  type t
end

(* One text field's restored contents, and the FIELD'S OWN NAME beside
   it. [path] EMPTY means [id] is a live widget's id; a non-empty path
   means it is a TEMPLATE NODE's id and the path is the stamped copy's
   keys, outermost first. *)
module Undo_text : sig
  type t = { id : int64; path : key list; text : string }
end

(* WHAT THE CORE PUT BACK, and a STATEMENT of it rather than a replay of
   ops: every run says what a thing now IS, so applying it twice is the
   same as applying it once. *)
module Undo_delta : sig
  type t = {
    signals : Undo_signal.t list;
    texts : Undo_text.t list;
    entries : Undo_entry.t list;
    orders : Undo_order.t list;
  }
end

type undo_text = Undo_text.t
type undo_delta = Undo_delta.t

(* One representation, arriving. Bytes ride as [string]. [Image] may be
   a RE-ENCODE of what was copied, so compare what the image IS, never
   the bytes it arrived in. *)
type representation =
  | Text of string
  | Html of string
  | Image of string
  | Files of picked_file list
  | Custom of string * string

(* A drag operation: copy and move, nothing else. A MODULE because the
   menu-role type already owns the constructor [Copy]. *)
module Op : sig
  type t = Copy | Move
end

type op = Op.t

(* What a drop delivered: the representation a paste already delivers,
   the point in the destination's own coordinates, the operation the
   core settled on, and — for a reorder — the anchor row and the side it
   landed on. *)
type dropped = {
  point : float * float;
  operation : op option;
  anchor : key list;
  before : bool;
  clip : representation option;
}

(* --- Rich text ---------------------------------------------------
   EVERY OFFSET IS A UTF-8 BYTE OFFSET into the widget's text, and
   OCaml's [string] IS a byte sequence, so this binding converts
   nothing. A RANGE IS [(start, stop)], half-open. *)

(* One paragraph kind; drawn, never stored. *)
type block = Body | Heading1 | Heading2 | Heading3 | Quote | Code_block

(* One attribute over one span; [value] is "true" for the flags, a URL
   for [link], a kind for [block]. *)
module Run : sig
  type t = { range : int * int; name : string; value : string }

  (* A flag attribute, on: bold, italic, underline, strike, code. The
     wire carries these as the string "true" and no guest compares it. *)
  val is_flag : t -> bool
end

type run = Run.t

(* A [rich] textarea's text and runs, kept current by the binding from
   the edits it delivers. THE DOCUMENT COMES LAST, so a declaration
   reads as a pipeline: [Document.create doc |> Document.bold (0, 6) |> ...]. *)
module Document : sig
  type t = { text : string; runs : Run.t list }

  val create : string -> t
  val mark : int * int -> string -> string -> t -> t

  (* A FLAG attribute, on or off — the boolean spelling, coerced to the
     wire's own string at the boundary. *)
  val flag : int * int -> string -> bool -> t -> t
  val bold : int * int -> t -> t
  val italic : int * int -> t -> t
  val underline : int * int -> t -> t
  val strike : int * int -> t -> t
  val code : int * int -> t -> t
  val link : int * int -> string -> t -> t

  (* A paragraph's kind; the range covers whole paragraphs or is refused. *)
  val block : int * int -> block -> t -> t

  val attr_at : t -> int -> string -> string option
end

type document = Document.t

(* What provoked an edit the widget reports. *)
type edit_source = User | Ime_commit | Paste | Native_undo | Drop

val edit_source_name : edit_source -> string
val edit_source_of_wire : int -> edit_source

(* Replace [start..stop] with [inserted], whose runs carry offsets
   RELATIVE to the inserted text. [source] is what provoked an edit the
   widget delivered and [None] on one the app builds. *)
module Edit : sig
  type t = {
    range : int * int;
    inserted : string;
    runs : Run.t list;
    source : edit_source option;
  }

  val insert : int -> string -> t
  val delete : int * int -> t
  val replace : int * int -> string -> t

  (* One attribute over the INSERTED text's own offsets. *)
  val mark : int * int -> string -> string -> t -> t

  (* A flag attribute over the inserted text, on or off. *)
  val flag : int * int -> string -> bool -> t -> t
end

type edit = Edit.t

(* A toolbar act over a range; [value = None] is the attribute taken off. *)
module Format : sig
  type t = { range : int * int; name : string; value : string option }

  (* A flag attribute, on. *)
  val is_flag : t -> bool
end

type format_act = Format.t

(* THE APP AND ITS TRANSACTION, ABSTRACT. The engine — 54 handle
   tables, the id counters, the collection model — is not a guest's to
   reach, and it was transparent here only because the checks
   (bindings/ocaml/checks/*.ml) read four tables to prove a registration
   or an abort's rollback. [For_checks] is that door, and the list of
   what a test reaches is auditable because it is written down. *)
type app

type tx

(* The five engine reads bindings/ocaml/checks/*.ml makes, and nothing
   else. A guest calls none of them. *)
module For_checks : sig
  val derived : app -> (int64, (unit -> unit) list) Hashtbl.t
  val sort_handlers : app -> (int64, int -> unit) Hashtbl.t
  val node_sorts : app -> (int64, key list -> int -> unit) Hashtbl.t
  val pending_routes : app -> string list
  val records : tx -> string list
  val collection_id : collection -> int64

  (* The decode-side span refusal: no scene can produce a reversed span,
     so the check drives it here. *)
  val decoded_span : string -> int -> int -> int * int
end

(* The transaction ambient for the extent of [build] (handler dispatch
   runs through build, so handlers get it too) — a RUNTIME error to ask
   outside one. *)
val the_tx : unit -> tx

(* A new app: one per process. *)
val create : unit -> app

(* Run [program] as one transaction: everything it queues applies
   atomically when it returns, and an exception rolls the model mirror
   back and re-raises. *)
val build : app -> (unit -> 'a) -> 'a

(* Hand [program] to the app thread, to run as its own transaction; safe
   from any thread. *)
val post : app -> (unit -> unit) -> unit

(* Run [program] as a transaction on the CURRENT thread and log rather
   than propagate an exception — the dispatch discipline every delivered
   occurrence runs under. *)
val dispatch : app -> (unit -> unit) -> unit

(* Open an undo group over the writes that follow in this transaction,
   labelled for the history UI. *)
val undoable : ?window:int64 -> string -> unit

(* Enter the core's run loop; returns the process's exit code. *)
val run : app -> int

type date = { year : int; month : int; day : int }
type time = { hour : int; minute : int }

val string_of_date : date -> string
val string_of_time : time -> string
val pack_date : date -> int64
val pack_time : time -> int64
val date_of_packed : int64 -> date

(* The formatter door (docs/compliance-plan.md §1.4, the OCaml row): a
   value in, the platform's own string out, in the process locale; pure,
   any thread, no transaction. An unstated digit count is the platform's
   default. A fault at the floor raises by name. *)
module Fmt : sig
  type length = [ `Short | `Medium | `Long ]

  val date : ?length:length -> date -> string
  val date_weekday : date -> string
  val time : ?length:length -> time -> string
  val date_time : ?length:length -> date -> time -> string

  val number :
    ?min_fraction_digits:int -> ?max_fraction_digits:int -> ?grouping:bool -> float -> string

  val percent :
    ?min_fraction_digits:int -> ?max_fraction_digits:int -> ?grouping:bool -> float -> string

  (* [currency 12.5 "USD"]: the ISO 4217 code. *)
  val currency : float -> string -> string

  (* Who the user is: the BCP-47 tag, the hour cycle (12 or 24), the first
     weekday (1 Monday .. 7 Sunday), the calendar and the numbering system. *)
  type locale = {
    tag : string;
    hour_cycle : int;
    first_weekday : int;
    calendar : string;
    numbering : string;
  }

  val locale : unit -> locale

  type direction = [ `Ltr | `Rtl ]

  val direction : unit -> direction
  val text_scale : unit -> float
end

(* The catalog (docs/compliance-plan.md §2.4): [catalog "tasks"] loads
   l10n/tasks.<locale>.ftl under the asset root once at startup, and
   [tr "tasks-due" [ "count", `Int 3; "date", `Date d ]] is the message
   with its arguments filled, dates and numbers through the door. A missing
   key or argument is the core's panic naming it. *)
val catalog : string -> unit

type tr_arg =
  [ `Int of int | `Float of float | `Text of string | `Date of date | `Time of time ]

val tr : string -> (string * tr_arg) list -> string
val time_of_packed : int64 -> time

(* THE TYPE WITNESS, one for the binding: a GADT, OCaml's own answer to
   type-directed dispatch, and the thing a constructor passed as
   ['a -> 'a signal] never was — that shape accepted any such function.
   [signal Scalar.Str "x"], [derive Scalar.I64 todos count]. Qualified on
   purpose: these are this binding's words, never the wire's. *)
module Scalar : sig
  type _ t =
    | Str : string t
    | Bool : bool t
    | I64 : int64 t
    | F64 : float t
    | Date : date t
    | Time : time t
end

(* A signal of the witnessed type — the phantom carries the wire
   encoding, so a mismatched [write] is a compile error. *)
val signal : 'a Scalar.t -> 'a -> 'a signal
val write : 'a signal -> 'a -> unit

val set_text : widget -> string -> unit
val set_grow : widget -> float -> unit
val set_a11y_id : widget -> string -> unit
val bind_a11y_id : widget -> string signal -> unit
val bind_a11y_label : widget -> string signal -> unit
val bind_a11y_hint : widget -> string signal -> unit
val bind_help : widget -> string signal -> unit
val bind_placeholder : widget -> string signal -> unit
val set_inset : widget -> float -> unit

(* A container's cross-axis child placement. *)
type align = Start | Center | End | Stretch | Baseline

(* A container's ARRANGEMENT AXIS (docs/adaptive-layout-plan.md D1/D2). *)
type axis = Horizontal | Vertical

val set_axis : widget -> axis -> unit

(* A window's named SIZE CLASS: what [~stack_when] speaks in place of an
   author-invented width. *)
type size_class = Compact

(* SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
   never how it looks. *)
type role = Destructive | Prominent | Heading | Caption | Plain | Switch | Link

(* THE SEMANTIC ICON VOCABULARY (docs/styling-plan.md D6). *)
type symbol =
  | Add
  | Remove
  | Delete
  | Edit
  | Done
  | Close
  | Search
  | Settings
  | Refresh
  | Info
  | Warning
  | Back
  | Forward
  | More
  | Copy
  | Paste
  | Star
  | Lock
  | Person
  | Home

(* WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR. *)
type platform = Mac | Ios | Linux | Windows | Android

val clear : widget -> unit
val focus : widget -> unit
val highlight_ranges : widget -> (int * int) list -> unit
val select_range : widget -> int * int -> unit
val reveal_range : widget -> int * int -> unit

(* A stamped copy's document is a record FIELD (docs/rich-text-plan.md
   §19): the field's Blob bytes are ONE flat value list. *)
val document_blob : Document.t -> string
val document_of_blob : string -> Document.t

val fold_edit : Document.t -> int * int -> string -> Run.t list -> Document.t
val absorb_edit : app -> int64 -> int * int -> string -> Run.t list -> unit

(* A stamped copy's edit or format act reaches its ROW's Document field:
   the node is bound to (collection, field) by [Tpl.textarea
   ~document_field], and the occurrence's path names the row. *)
val fold_row_document :
  app -> int64 -> key list -> (Document.t -> Document.t) -> unit

(* The folded document of a [rich] textarea; empty until the first edit
   or write. Reads the ambient transaction, as [items] does. *)
val document : widget -> Document.t

(* Replace a [rich] textarea's whole document: echoes nothing and, like
   [set_text], spends the native undo history. *)
val set_document : widget -> Document.t -> unit

(* One edit into a [rich] textarea: echoes nothing, never resets undo. *)
val apply_edit : widget -> Edit.t -> unit

(* Format the widget's CURRENT SELECTION through its own act. [value] is
   "true" for a flag, the URL for [link]. *)
val format : widget -> string -> string -> unit

(* A flag attribute over the selection, on or off. *)
val format_flag : widget -> string -> bool -> unit

(* The named acts: [format] with its own name over the widget's
   selection. *)
val bold : widget -> unit
val italic : widget -> unit
val underline : widget -> unit
val strike : widget -> unit
val code : widget -> unit
val link : widget -> string -> unit

(* Take an attribute off the widget's current selection. *)
val unformat : widget -> string -> unit

(* One attribute over a BYTE RANGE of the document, the selection left
   where it is. A [block] covers the range's whole paragraphs, and
   [block] with "body" takes the kind off. *)
val format_range : widget -> int * int -> string -> string -> unit

(* A flag attribute over a byte range, on or off. *)
val format_range_flag : widget -> int * int -> string -> bool -> unit

(* [format_range]'s removal. *)
val unformat_range : widget -> int * int -> string -> unit

(* Make the selection's paragraphs [kind]; [Body] clears. *)
val set_block : widget -> block -> unit

(* What an [~own_undo] textarea's app can take back right now, and put
   back: a write re-reads Edit>Undo's and Edit>Redo's enablement. *)
val can_undo : widget -> bool -> unit
val can_redo : widget -> bool -> unit

(* --- Widget constructors: labeled optional arguments, the lablgtk
   idiom; a creator ends in [()], and omitting it leaves the
   [unit -> widget] child form (the curried-children convention). *)

val button :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?role:role -> ?text:string -> ?on_click:(unit -> unit) -> unit -> widget

val textarea :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?placeholder:string ->
  ?placeholder_bind:string signal ->
  ?on_change:(string -> unit) ->
  ?rich:bool ->
  ?own_undo:bool ->
  ?on_edit:(edit -> unit) ->
  ?on_format:(format_act -> unit) -> unit -> widget

val label :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?role:role ->
  ?rich:bool ->
  ?href:string ->
  ?href_bind:string signal ->
  ?text:string -> ?bind:string signal -> unit -> widget

val heading :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?text:string -> ?bind:string signal -> unit -> widget

val caption :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?text:string -> ?bind:string signal -> unit -> widget

val entry :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?placeholder:string ->
  ?placeholder_bind:string signal ->
  ?on_change:(string -> unit) -> unit -> widget

val search :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?placeholder:string ->
  ?placeholder_bind:string signal ->
  ?on_change:(string -> unit) -> unit -> widget

val progress :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?value:float -> ?indeterminate:bool -> unit -> widget

val slider :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?min:float ->
  ?max:float ->
  ?value:float ->
  ?step:float ->
  ?tick_spacing:float ->
  ?bind:float signal ->
  ?on_change:(float -> unit) ->
  ?on_commit:(float -> unit) -> unit -> widget

val select :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?selected:int ->
  ?on_select:(int -> unit) -> string list -> unit -> widget

val radio :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?selected:int ->
  ?on_select:(int -> unit) -> string list -> unit -> widget

val checkbox :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?text:string ->
  ?checked:bool -> ?on_toggle:(bool -> unit) -> unit -> widget

(* A date picker over civil dates — the compact field that opens the
   platform's calendar. UNCONTROLLED: the control owns its value and
   reports each COMMITTED pick to [~on_change]. *)
val date_picker :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?value:date ->
  ?bind:date signal ->
  ?min:date -> ?max:date -> ?on_change:(date -> unit) -> unit -> widget

(* A time picker over civil times: hours and minutes, no seconds.
   [~step] is the minute granularity and a pick snaps to it. *)
val time_picker :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?a11y_hint:string ->
  ?value:time ->
  ?bind:time signal ->
  ?step:int -> ?on_change:(time -> unit) -> unit -> widget

(* An image displaying encoded bytes: decode failure renders the
   placeholder, never a crash. [~source] and [~source_asset] are
   EXCLUSIVE. *)
val image :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?source:bytes -> ?source_asset:asset -> ?bind:bytes signal -> unit -> widget

(* --- THE CANVAS VOCABULARY (docs/canvas-plan.md §3.3, §3.4) --------- *)

(* A fill/stroke's brand-relative color, resolved from the accent seed. *)
type paint = Series | Series_fill | Grid | Axis | Ground

(* [fill]'s ~rule — even-odd or the default nonzero winding. *)
type fill_rule = Nonzero | Even_odd

val move_to : draw -> float -> float -> unit
val line_to : draw -> float -> float -> unit
val close : draw -> unit
val fill : draw -> paint:paint -> ?rule:fill_rule -> unit -> unit

val canvas :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  viewbox:viewbox ->
  ?draw:(draw -> unit) ->
  ?fixed:bool ->
  ?on_draw:(draw -> viewbox -> unit) ->
  ?on_tick:(draw -> viewbox -> float -> unit) -> unit -> widget

val grid :
  columns:int ->
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?spacing:float ->
  ?inset:float ->
  ?columns_when:size_class * int ->
  ?columns_auto:float -> (unit -> widget) list -> unit -> widget

val labeled :
  ?label:string ->
  ?label_bind:string signal ->
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?spacing:float -> ?inset:float -> (unit -> widget) list -> unit -> widget

val spacer : ?grow:float -> unit -> widget

val column :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?spacing:float ->
  ?align:align -> ?inset:float -> (unit -> widget) list -> unit -> widget

val scroll :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal -> (unit -> widget) list -> unit -> widget

(* [~stack_when] stacks this row's children vertically while the
   window's SIZE CLASS is the named one, reverting on leaving it. *)
val row :
  ?grow:float ->
  ?fill:bool ->
  ?a11y_id:string ->
  ?a11y_id_bind:string signal ->
  ?a11y_label:string ->
  ?a11y_label_bind:string signal ->
  ?help:string ->
  ?help_bind:string signal ->
  ?spacing:float ->
  ?align:align ->
  ?inset:float ->
  ?stack_when:size_class ->
  ?wrap:bool -> (unit -> widget) list -> unit -> widget

(* An existing widget as a child: wraps an already-realized handle in an
   inert thunk, so a widget created earlier slots into a child list. *)
val w : 'a -> unit -> 'a

(* --- Collections: a scalar (string) element per entry -------------- *)

val collection : unit -> collection

(* The instance of this collection inside the copy keyed by [key] of the
   next enclosing For; chain for deeper nesting. *)
val at : collection -> key -> collection

val insert : collection -> key -> string -> unit

(* Insert a value under a key the binding authors, and hand the key
   back. *)
val insert_fresh : collection -> string -> int64

val update : collection -> key -> string -> unit
val remove : collection -> key -> unit

(* Reposition an entry before another's / at the end / at the front /
   directly after another's. *)
val move_before : collection -> key -> key -> unit
val move_to_end : collection -> key -> unit
val move_to_front : collection -> key -> unit
val move_after : collection -> key -> key -> unit

(* The model: what this guest wrote, exactly, in insertion order. *)
val items : collection -> (key * string) list

(* count reads through items, so the mirror-read guard fires there. *)
val count : collection -> int

(* Records: a first-class descriptor is the schema — what
   [@@deriving kaya_gen] emits for a record type
   (bindings/ocaml/ppx/kaya_ppx.ml). *)
type 'a record_type = {
  rt_schema : int list;
  rt_to_values : 'a -> Kaya_wire.value list;
  rt_of_values : Kaya_wire.value list -> 'a;
}

(* A typed projection: one field of a record type, by wire position. *)
type ('a, 'v) field = { fd_index : int; fd_to_value : 'v -> Kaya_wire.value }

val str_field : int -> ('a, string) field

(* THE WHOLE ELEMENT OF A SCALAR COLLECTION, as a field token. *)
val element : ('a, string) field

val bool_field : int -> ('a, bool) field
val i64_field : int -> ('a, int64) field
val f64_field : int -> ('a, float) field

(* A Date field: a [date] in the app, an I64 in packed decimal on the
   wire. *)
val date_field : int -> ('a, date) field
val time_field : int -> ('a, time) field

(* A blob field's MODEL value carries the guest's own bytes. *)
val blob_field : int -> ('a, bytes) field

(* A [document] field: a Blob slot whose bytes are the document's own
   wire list, so a stamped copy's document binds through the template
   zone as a string field does. *)
val document_field : int -> ('a, document) field

type 'a record_collection

val record_handle : 'a record_collection -> collection
val record_at : 'a record_collection -> key -> 'a record_collection

(* Declare a collection of records; the descriptor is the schema. *)
val collection_of : 'a record_type -> 'a record_collection

val insert_record : 'a record_collection -> key -> 'a -> unit

(* [insert_fresh] for a record collection: the binding authors the key
   and hands it back. *)
val insert_record_fresh : 'a record_collection -> 'a -> int64

val update_record : 'a record_collection -> key -> 'a -> unit

(* One field's delta: the rest of the record never travels. *)
val update_field : 'a record_collection -> key -> ('b, 'c) field -> 'c -> unit

(* The typed model: what this guest wrote, in insertion order. *)
val record_items : 'a record_collection -> (key * 'a) list

(* One row by its key — the [get]/[find_opt] shape over a record
   collection. *)
val record_get : 'a record_collection -> key -> 'a option

(* A signal recomputed from this collection's entries after every
   mutation, written into the same transaction. [mk] is one of the typed
   signal constructors ([signal_str] and so on). *)
val derive :
  'a Scalar.t -> 'b record_collection -> ((key * 'b) list -> 'a) -> 'a signal

(* REQUEST this app's brand accent: one sRGB hex is the whole call and
   the core derives the rest. [~light] and [~dark] are the per-appearance
   form. SET ONCE, BEFORE THE FIRST MOUNT. *)
val brand_accent : ?light:int -> ?dark:int -> int -> unit

val brand_typeface :
  ?platforms:(platform * string) list ->
  ?font:bytes -> ?font_asset:asset -> string -> unit

(* DECLARE this app's identity from the asset root's own identity.toml.
   SET ONCE, BEFORE THE FIRST MOUNT. *)
val app_identity : unit -> unit

(* The window's ADVISORY sections hint: the width/height decide the
   actual presentation, this only nudges it. *)
module Sections_presentation : sig
  type t = Auto | Bar | Sidebar
end

(* Set a window's attributes in one construct — the attribute set is
   EXACTLY [create_window]'s. *)
val window :
  ?title:string ->
  ?width:float ->
  ?height:float ->
  ?inset:float ->
  ?veto_close:bool ->
  ?dirty:bool ->
  ?remember_frame:bool ->
  ?panes:int ->
  ?sections_presentation:Sections_presentation.t ->
  ?appearance:Appearance.t ->
  ?on_close_requested:(unit -> unit) ->
  ?on_closed:(unit -> unit) ->
  ?on_undone:(string -> undo_delta -> unit) ->
  ?on_redone:(string -> undo_delta -> unit) ->
  ?menus:(unit -> menu_item) list -> ?id:int64 -> unit -> unit

(* Create an auxiliary window (capability-gated); materializes hidden,
   [mount_in] presents. *)
val create_window :
  ?title:string ->
  ?width:float ->
  ?height:float ->
  ?inset:float ->
  ?veto_close:bool ->
  ?dirty:bool ->
  ?remember_frame:bool ->
  ?panes:int ->
  ?sections_presentation:Sections_presentation.t ->
  ?appearance:Appearance.t ->
  ?on_close_requested:(unit -> unit) ->
  ?on_closed:(unit -> unit) ->
  ?on_undone:(string -> undo_delta -> unit) ->
  ?on_redone:(string -> undo_delta -> unit) ->
  ?menus:(unit -> menu_item) list -> int64 -> unit

(* Close and forget an auxiliary window. *)
val destroy_window : int64 -> unit

(* Mount a root into a specific window; mounting presents. *)
val mount_in : int64 -> widget -> unit

(* Push a navigation entry onto the primary surface's stack. *)
val push_entry :
  ?window:int64 ->
  ?title:string ->
  ?intercept_back:bool ->
  ?on_popped:(unit -> unit) ->
  ?on_back_requested:(unit -> unit) -> int64 -> unit

(* Append a section to the window's section set; the set is
   append-only. *)
val add_section :
  ?window:int64 ->
  ?title:string ->
  ?symbol:symbol ->
  ?badge:float ->
  ?badge_bind:float signal -> ?on_selected:(unit -> unit) -> int64 -> unit

(* Select a section programmatically: configuration, never echoes
   [~on_selected]. *)
val select_section : ?window:int64 -> int64 -> unit

(* Pop the primary surface's top entry. *)
val pop_entry : ?window:int64 -> unit -> unit

(* Request a sheet over a window or a live sheet (docs/sheet-plan.md);
   [mount_in] presents it. *)
val present_sheet :
  ?parent:int64 ->
  ?title:string ->
  ?intercept_dismiss:bool ->
  ?detent:Detent.t ->
  ?on_dismissed:(unit -> unit) ->
  ?on_dismiss_requested:(unit -> unit) -> int64 -> unit

(* Dismiss a live sheet and forget its tree, child sheets with it. *)
val dismiss_sheet : int64 -> unit

(* A dialog is a QUESTION: [show_alert ~title ~cancel ()] shows the alert
   when handed its continuation, the callback the binding runs on the app
   thread in its own transaction, so [let*] chains questions with no
   runtime behind it (docs/async-dialogs-plan.md §3). Transparent on
   purpose: any callback-shaped operation of yours chains the same way.
   There is no [and*]: one dialog is live at a time. *)
type 'a ask = ('a -> unit) -> unit

val ( let* ) : 'a ask -> ('a -> unit) -> unit

val show_alert :
  ?window:int64 ->
  ?title:string ->
  ?message:string ->
  ?actions:string list -> cancel:string -> unit -> Alert_choice.t ask

val show_notification :
  ?title:string ->
  ?body:string -> ?at:int64 -> ?on_result:(Notification_outcome.t -> unit) -> int64 -> int64

(* Withdraw a pending or delivered notification. No answer follows; an
   unknown id is ignored. *)
val cancel_notification : int64 -> unit

(* Answer a notification occurrence: one-shot if a handler is
   registered, the process-level handler otherwise. *)
val notification_result : app -> int64 -> Notification_outcome.t -> unit

(* NOT one-shot: the process-level handler for a result whose id has no
   one-shot handler — a relaunched process never called
   [show_notification]. *)
val on_notification_activation :
  app -> f:(int64 -> Notification_outcome.t -> unit) -> unit

(* NOT one-shot either: a route declared here answers every URL that
   matches it, for the life of the process. *)
val link_route : app -> pattern:string -> f:((string * string) list -> unit) -> unit

val link_opened : app -> int64 -> string -> (string * string) list -> unit

val pick_files :
  ?window:int64 -> ?filters:(string * string) list -> unit -> picked_file list ask

val pick_file :
  ?window:int64 -> ?filters:(string * string) list -> unit -> picked_file list ask

val save_file :
  ?window:int64 -> ?filters:(string * string) list -> string -> picked_file option ask

val copy :
  ?text:string ->
  ?html:string ->
  ?image:string ->
  ?files:picked_file list -> ?custom:(string * string) list -> unit -> unit

val read_clipboard : string list -> representation option ask

val set_accepts : widget -> string list -> unit

val draggable :
  ?text:string ->
  ?html:string ->
  ?image:string ->
  ?files:picked_file list ->
  ?custom:(string * string) list ->
  ?operations:Op.t list -> widget -> unit -> unit

(* ONE stamped copy's drag declaration: the template node and the copy's
   keys, outermost first. *)
val draggable_at :
  ?text:string ->
  ?html:string ->
  ?image:string ->
  ?files:picked_file list ->
  ?custom:(string * string) list ->
  ?operations:Op.t list ->
  node -> keys:key list -> unit -> unit

val set_drop_target : widget -> Op.t list -> unit
val set_reorderable : widget -> bool -> unit


(* Redeem a picked (or dropped) file's handle for a real descriptor,
   plus whether it seeks. BLOCKS, possibly for a long time, so call it
   from a thread you chose and post the result back (DESIGN.md, File
   dialogs). THE DESCRIPTOR BECOMES OCAML'S. *)
val open_picked : picked_file -> File_mode.t -> Unix.file_descr * bool

(* Mount a root into the default window; mounting presents. *)
val mount : widget -> unit

(* The closed standard-command vocabulary the core enforces at runtime. *)
module Menu_role : sig
  type t = Settings | Cut | Copy | Paste | Undo | Redo
end

(* An action — a leaf command firing exactly one menu_activated
   occurrence. [~on_activate_node] is the template-node flavor: the
   copy's key path arrives first. *)
val item :
  ?shortcut:string ->
  ?enabled:bool ->
  ?bind_enabled:bool signal ->
  ?icon:bytes ->
  ?symbol:symbol ->
  ?primary:bool ->
  ?role:Menu_role.t ->
  ?on_activate:(unit -> unit) ->
  ?on_activate_node:(key list -> unit) -> label:string -> unit -> menu_item

(* A toggle — a stateful leaf reusing the Checkbox contract. *)
val toggle :
  ?checked:bool ->
  ?bind_checked:bool signal ->
  ?enabled:bool ->
  ?bind_enabled:bool signal ->
  ?icon:bytes ->
  ?symbol:symbol ->
  ?shortcut:string ->
  ?on_toggle:(bool -> unit) ->
  ?on_toggle_node:(key list -> bool -> unit) ->
  label:string -> unit -> menu_item

(* One labeled radio option, appended in declaration order. *)
val option :
  ?enabled:bool ->
  ?bind_enabled:bool signal ->
  ?icon:bytes ->
  ?symbol:symbol -> ?shortcut:string -> label:string -> unit -> menu_item

(* Native grouping chrome: no label, no props, no handle kept. *)
val separator : unit -> menu_item

(* A menu grouping node — a bar root through the window construct's
   [~menus], or nested as a bare partial application in a parent's child
   list. *)
val menu :
  ?enabled:bool ->
  ?bind_enabled:bool signal ->
  ?icon:bytes ->
  ?symbol:symbol ->
  label:string -> (unit -> menu_item) list -> unit -> menu_item

(* A radio group — the Choice contract with the platform's checkmark
   idiom. *)
val radio_group :
  ?value:int ->
  ?bind_value:float signal ->
  ?enabled:bool ->
  ?bind_enabled:bool signal ->
  ?icon:bytes ->
  ?symbol:symbol ->
  ?on_select:(int -> unit) ->
  ?on_select_node:(key list -> int -> unit) ->
  label:string -> (unit -> menu_item) list -> unit -> menu_item

(* A context menu on a LIVE widget: the same item vocabulary scoped to a
   NOUN, with the platform's own gesture. *)
val context_menu : widget -> (unit -> menu_item) list -> unit

(* Build a context catalog UNANCHORED — free root items for a
   template-node anchor; [Tpl.context_menu] attaches it. *)
val context_catalog : (unit -> menu_item) list -> context_catalog

(* The dynamic tier for a RETAINED item. *)
val set_menu_label : menu_item -> string -> unit
val set_menu_primary : menu_item -> bool -> unit

(* A named vocabulary for the accept list's closed half. A MISTYPED BARE
   STRING IS SILENT, so these are the ones a guest spells. *)
val accept_text : string
val accept_image : string
val accept_files : string

(* Append children to a retained parent at any time. *)
val menu_append : menu_item -> (unit -> menu_item) list -> unit

(* Realize a For's body once for every entry, in key order; the widget
   [for_each] returns is the collection's own container. *)
val for_each : collection -> (unit -> 'a) -> unit -> widget * 'a

(* A nested For AS A CHILD: [for_each] with the body's result thrown
   away. *)
val each : collection -> (unit -> 'a) -> unit -> widget

(* The header bar's sort indicator: which column shows it, in which
   direction — the guest's declaration, re-sent with the new state after
   it handles a sort request. *)
type sort = { sort_column : int32; sort_direction : int32 }

val sort_none : sort
val sort_asc : int -> sort
val sort_desc : int -> sort

(* Declare the column header bar on a For's container. [~on_sort]
   answers the header clicks with the 0-based column. *)
val columns : ?on_sort:(int -> unit) -> widget -> string list -> sort -> unit

(* Re-declare ONE stamped copy's header bar — the per-copy sort arrows.
   [node] is the nested For's template node and [keys] the copy's key
   path outermost first. *)
val columns_at : node -> key list -> string list -> sort -> unit

(* Sums: a variant type whose constructors carry inline records — what
   [@@deriving kaya_gen] emits for a sum type
   (bindings/ocaml/ppx/kaya_ppx.ml). *)
type 'a sum_type = {
  st_schemas : int list list;
  st_variant : 'a -> int;
  st_to_values : 'a -> Kaya_wire.value list;
  st_of_values : int -> Kaya_wire.value list -> 'a;
}

type 'a sum_collection

val sum_of : 'a sum_type -> 'a sum_collection

(* Insert witnesses the value's own constructor onto the wire. *)
val sum_insert : 'a sum_collection -> key -> 'a -> unit

(* Update replaces a record wholesale; a different constructor than the
   entry's current one restamps its copy in place. *)
val sum_update : 'a sum_collection -> key -> 'a -> unit

(* The typed model, in insertion order; [match] eliminates the values. *)
val sum_items : 'a sum_collection -> (key * 'a) list

(* The entry's current value — the scrutinee for the match that precedes
   a patch. *)
val sum_get : 'a sum_collection -> key -> 'a option

(* The witnessed field write, called by the generated per-constructor
   patches: the match that produced the write names the variant. *)
val sum_update_field :
  'a sum_collection -> key -> variant:int -> ('b, 'c) field -> 'c -> unit

(* The collection-derived signal, over the sum's entries. *)
val sum_derive :
  'a Scalar.t -> 'b sum_collection -> ((key * 'b) list -> 'a) -> 'a signal

(* The eliminator's mechanism: (variant, arm) pairs in declaration order,
   each arm a Tpl program — what the generated [<type>_each] calls. *)
val each_sum : 'a sum_collection -> (int * (unit -> 'b)) list -> unit -> widget

(* A When over a Bool signal: stamps on true, unstamps on false; the
   widget is the When's own container and the body's result rides beside
   it, as [for_each]'s does. *)
val when_ : bool signal -> (unit -> 'a) -> unit -> widget * 'a

(* A When AS A CHILD: [when_] with the body's result thrown away. *)
val shown : bool signal -> (unit -> 'a) -> unit -> widget

(* THE TEMPLATE ZONE: every constructor here stamps once per row inside
   a [for_each]/[each_sum] body, addressing the row through the SAME
   names the live zone uses ([bind_field] instead of [bind], a node
   instead of a widget). *)
module Tpl : sig
  val collection : unit -> collection
  val collection_of : 'a record_type -> 'a record_collection
  val for_each : collection -> (unit -> 'a) -> unit -> node * 'a
  val each : collection -> (unit -> 'a) -> unit -> node

  val columns :
    ?on_sort:(key list -> int -> unit) -> node -> string list -> sort -> unit

  val draggable :
    ?text:string ->
    ?text_field:('a, 'b) field ->
    ?html:string ->
    ?html_field:('c, 'd) field ->
    ?image:string ->
    ?image_field:('e, 'f) field ->
    ?files:picked_file list ->
    ?custom:(string * string) list ->
    ?custom_fields:(string * ('g, bytes) field) list ->
    ?operations:Op.t list -> node -> unit -> unit

  val set_drop_target : node -> Op.t list -> unit
  val set_accepts : node -> string list -> unit
  val set_align : node -> align -> unit
  val when_ : bool signal -> (unit -> 'a) -> unit -> node * 'a

  val button :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?a11y_hint_bind:string signal ->
    ?a11y_hint_field:('d, string) field ->
    ?role:role ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('e, string) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_click:(key list -> unit) -> unit -> node

  val textarea :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?placeholder:string ->
    ?placeholder_bind:string signal ->
    ?placeholder_field:('d, string) field ->
    ?accepts:string list ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('e, string) field ->
    ?document_field:('f, document) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_change:(key list -> string -> unit) -> unit -> node

  val label :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?role:role ->
    ?href:string ->
    ?href_bind:string signal ->
    ?href_field:('d, string) field ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('e, string) field ->
    ?level:int -> ?a11y_level:int -> unit -> node

  val heading :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('d, string) field ->
    ?level:int -> ?a11y_level:int -> unit -> node

  val caption :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('d, string) field ->
    ?level:int -> ?a11y_level:int -> unit -> node

  (* A single-line text field per stamped copy. UNCONTROLLED as its live
     twin is: every edit arrives at [~on_change] with that copy's keys
     first. *)
  val entry :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?placeholder:string ->
    ?placeholder_bind:string signal ->
    ?placeholder_field:('d, string) field ->
    ?accepts:string list ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('e, string) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_change:(key list -> string -> unit) -> unit -> node

  val search :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?placeholder:string ->
    ?placeholder_bind:string signal ->
    ?placeholder_field:('d, string) field ->
    ?accepts:string list ->
    ?text:string ->
    ?bind:string signal ->
    ?bind_field:('e, string) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_change:(key list -> string -> unit) -> unit -> node

  val progress :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?value:float ->
    ?bind:float signal ->
    ?bind_field:('d, float) field ->
    ?level:int -> ?a11y_level:int -> ?indeterminate:bool -> unit -> node

  (* A slider per stamped copy, over [~min]..[~max] at a position from
     any of the three sources. *)
  val slider :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?min:float ->
    ?max:float ->
    ?value:float ->
    ?step:float ->
    ?tick_spacing:float ->
    ?bind:float signal ->
    ?bind_field:('d, float) field ->
    ?level:int ->
    ?a11y_level:int ->
    ?on_change:(key list -> float -> unit) ->
    ?on_commit:(key list -> float -> unit) -> unit -> node

  (* A dropdown select per stamped copy, over fixed options — each
     option becomes a label child. *)
  val select :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?a11y_hint_bind:string signal ->
    ?a11y_hint_field:('d, string) field ->
    ?selected:int ->
    ?bind:float signal ->
    ?bind_field:('e, float) field ->
    ?level:int ->
    ?a11y_level:int ->
    ?on_select:(key list -> int -> unit) -> string list -> unit -> node

  (* A radio group per stamped copy — the choice contract in its inline
     presentation. *)
  val radio :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?a11y_hint_bind:string signal ->
    ?a11y_hint_field:('d, string) field ->
    ?selected:int ->
    ?bind:float signal ->
    ?bind_field:('e, float) field ->
    ?level:int ->
    ?a11y_level:int ->
    ?on_select:(key list -> int -> unit) -> string list -> unit -> node

  val checkbox :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?a11y_hint_bind:string signal ->
    ?a11y_hint_field:('d, string) field ->
    ?checked:bool ->
    ?bind:bool signal ->
    ?bind_field:('e, bool) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_toggle:(key list -> bool -> unit) -> unit -> node

  (* A date picker per stamped copy: [~value] a constant, [~bind] a
     signal, [~bind_field] the row's own (_, date) field. Picks carry the
     copy's keys first. *)
  val date_picker :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?value:date ->
    ?bind:date signal ->
    ?bind_field:('d, date) field ->
    ?level:int ->
    ?a11y_level:int -> ?on_change:(key list -> date -> unit) -> unit -> node

  (* A time picker per stamped copy — the date picker's three sources,
     hours and minutes. *)
  val time_picker :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_hint:string ->
    ?value:time ->
    ?bind:time signal ->
    ?bind_field:('d, time) field ->
    ?step:int ->
    ?level:int ->
    ?a11y_level:int -> ?on_change:(key list -> time -> unit) -> unit -> node

  (* An image per stamped copy: [~source] gives every copy the same
     bytes, [~bind] a Blob signal, [~bind_field] each row's own (_,
     bytes) field. *)
  val image :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?source:bytes ->
    ?bind:bytes signal ->
    ?bind_field:('d, bytes) field ->
    ?level:int -> ?a11y_level:int -> unit -> node

  (* A canvas per stamped copy -- a sparkline in a table cell. The drawing
     is declared with the node, so every copy is born with it; [draw_at]
     re-declares one copy's. *)
  val canvas :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int ->
    viewbox:viewbox -> draw:(draw -> unit) -> unit -> node

  val container :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int ->
    ?inset:float -> int -> (unit -> node) list -> unit -> node

  val grid :
    columns:int ->
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int ->
    ?inset:float ->
    ?columns_auto:float -> (unit -> node) list -> unit -> node

  val labeled :
    ?label:string ->
    ?label_bind:string signal ->
    ?label_field:('a, string) field ->
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('b, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('c, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('d, string) field ->
    ?a11y_level:int -> ?level:int -> (unit -> node) list -> unit -> node

  val spacer : ?grow:float -> unit -> node

  val column :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int -> ?inset:float -> (unit -> node) list -> unit -> node

  val scroll :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int -> (unit -> node) list -> unit -> node

  val row :
    ?grow:float ->
    ?fill:bool ->
    ?a11y_id:string ->
    ?a11y_id_bind:string signal ->
    ?a11y_id_field:('a, string) field ->
    ?a11y_label:string ->
    ?a11y_label_bind:string signal ->
    ?a11y_label_field:('b, string) field ->
    ?help:string ->
    ?help_bind:string signal ->
    ?help_field:('c, string) field ->
    ?a11y_level:int ->
    ?inset:float -> ?wrap:bool -> (unit -> node) list -> unit -> node

  (* A context menu on a template node: the same item vocabulary,
     attached from an unanchored [context_catalog]. *)
  val context_menu : node -> context_catalog -> unit

  (* An existing node as a child. *)
  val w : 'a -> unit -> 'a
end

val on_click : app -> widget -> (unit -> unit) -> unit

(* Register a click handler for a template node; it also receives the
   stamped copy's keys, outermost first. *)
val on_click_node : app -> node -> (key list -> unit) -> unit

(* Take pasted content at a live widget. *)
val on_paste : app -> widget -> (representation -> unit) -> unit

(* A paste onto a stamped copy: the handler also receives the copy's key
   path, outermost first. *)
val on_paste_node : app -> node -> (key list -> representation -> unit) -> unit

(* Take dropped content at a live widget, or a reorderable For's
   landings. Only fires for a widget that declared [set_drop_target]
   over an accept list. *)
val on_drop : app -> widget -> (dropped -> unit) -> unit

(* A drag that began at this widget has ended: [None] is a cancelled or
   refused drag, not an error. *)
val on_drag_ended : app -> widget -> (op option -> unit) -> unit

(* A drop on a stamped copy: the handler also receives the copy's key
   path, outermost first. *)
val on_drop_node : app -> node -> (key list -> dropped -> unit) -> unit

(* A stamped copy of this node — a reorderable row is one — finished its
   drag; the copy's keys first. *)
val on_drag_ended_node : app -> node -> (key list -> op option -> unit) -> unit

(* Register a change handler for a live entry: the widget owns its text
   and reports each edit here; there is no read-back, by doctrine. *)
val on_change : app -> widget -> (string -> unit) -> unit

(* One addressed user edit of a [rich] textarea; [~on_change] still
   fires beside it. The registration twin of [textarea ~on_edit], for a
   handler that reads the widget's own [document] and so cannot be
   written before the widget exists. *)
val on_edit : app -> widget -> (edit -> unit) -> unit

(* The user formatted a range; a format over a collapsed caret is
   pending state and arrives as the next edit's runs, never here. *)
val on_format : app -> widget -> (format_act -> unit) -> unit

(* A stamped rich copy's edit, with its row's key path outermost first —
   the row's document field has already taken the act when this fires,
   so the handler reads the ROW and never the widget. *)
val on_edit_node : app -> node -> (key list -> edit -> unit) -> unit

val on_format_node : app -> node -> (key list -> format_act -> unit) -> unit

(* The value a live slider's gesture SETTLED ON -- once per release or
   key move, after that gesture's moves (docs/slider-plan.md S2). *)
val on_value_committed : app -> widget -> (float -> unit) -> unit

(* A stamped slider's settled value, the copy's keys first. *)
val on_value_committed_node : app -> node -> (key list -> float -> unit) -> unit
