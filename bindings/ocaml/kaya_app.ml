(* kaya's idiomatic surface for OCaml, over kaya_runtime.ml and the
   generated kaya_wire.ml. THE TEMPLATE ZONE IS THE Tpl SUBMODULE. THE
   TRANSACTION IS AMBIENT, so a builder called outside [build] is a loud
   RUNTIME error ([the_tx]). THE TRAILING-UNIT CONVENTION: a creator ends
   in [()]; omit it and the partial application is the [unit -> widget]
   child form, realized left to right ([List.iter]'s specified order —
   never OCaml's unspecified list-literal order). *)

(* A phantom-typed signal handle — the [field] idiom (below) extended to
   signals: [enc] is the one place a signal's value crosses onto the
   wire, so [signal_str]/[signal_bool]/[signal_i64]/[signal_f64] and
   [write] can never mismatch a signal's declared type against what it
   is written. *)
type 'a signal = { sig_id : int64; sig_enc : 'a -> Kaya_wire.value }

type widget = Widget of int64
type node = Node of int64

(* A canvas's coordinate system AND its natural size in
   device-independent points (docs/canvas-plan.md §3.2). The op stream is
   written in these units on every platform, so a scene can freeze it. *)
type viewbox = float * float

(* The drawing scope's recorder: the calls read as immediate-mode
   drawing but are recorded, and ONE record is submitted when the scope
   closes (docs/canvas-plan.md §2.1). [d_ops] accumulates reversed. *)
type draw = { d_viewbox : viewbox; mutable d_ops : Kaya_wire.value list }

(* WHAT THIS HOST CAN DO — see crates/kaya/src/app.rs for the canonical
   note, which every binding's copy of this surface shortens. *)
(* [notifications] is a RUNTIME bit: this process can post a local
   notification the desktop will show (docs/tasks-s3-plan.md N3). *)
type capabilities = { aux_windows : bool; notifications : bool }

(* This host's capabilities. Constant for the life of the process, so
   asking once and remembering is fine. *)
let capabilities () =
  let bits = Kaya_runtime.capability_bits () in
  {
    aux_windows = Int64.logand bits Kaya_runtime.cap_aux_windows <> 0L;
    notifications = Int64.logand bits Kaya_runtime.cap_notifications <> 0L;
  }


(* The app's own directory: /data/data/<id>/files on Android,
   ~/Library/Application Support/<id> on macOS, the app's sandboxed
   directory on iOS, /data/user/0/<id>/files -- no, this is the actual
   directory on Android, $XDG_DATA_HOME/<id> on Linux,
   %LOCALAPPDATA%\<id> on Windows. Created on first ask.

   KAYA OWNS THE PLACE AND NOTHING ELSE: the app's document is the app's,
   written the standard way. Settings are small and typed and belong in
   [prefs].

   RAISES where the platform has handed no directory over -- an error
   state a guest cannot plan around, so all nine bindings refuse rather
   than answering an absent value (ruled 2026-09-09). *)
let app_data_dir () =
  match Kaya_runtime.app_data_dir () with
  | Some dir -> dir
  | None ->
      failwith
        "kaya: app_data_dir asked before the platform handed one over \
         (Android before attach)"

(* The app's preferences store (docs/tasks-s4-plan.md P2/P3): a small
   typed key-value record under the app's id, the platform's own where
   the platform has one -- UserDefaults on Apple, SharedPreferences on
   Android, a key file on Linux and Windows.

   A PULL, NOT A SIGNAL: a setting is read when the app builds and
   written when the user changes it. Every getter takes the default it
   answers when the key is absent OR holds another type. Writes are
   durable when they return, and the store may be used from any thread.

   A RECORD OF CLOSURES rather than a module, because the charge is one
   HANDLE in all nine bindings and OCaml's module system has no value to
   hand back. *)
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

(* A guest may READ any key and WRITE any key kaya has not reserved
   (docs/tasks-s4-plan.md P4: window memory lives under [kaya.]). *)
let pref_key key =
  if String.length key = 0 then
    failwith "kaya: a preference key must not be empty";
  key

let pref_write_key key =
  ignore (pref_key key);
  if String.length key >= 5 && String.sub key 0 5 = "kaya." then
    failwith
      (Printf.sprintf
         "kaya: preference key \"%s\" is reserved (the kaya. prefix is \
          kaya's own)"
         key);
  key

let the_prefs =
  {
    get_string =
      (fun key default ->
        match Kaya_runtime.pref_get_string (pref_key key) with
        | Some v -> v
        | None -> default);
    get_i64 =
      (fun key default ->
        match Kaya_runtime.pref_get_i64 (pref_key key) with
        | Some v -> v
        | None -> default);
    get_f64 =
      (fun key default ->
        match Kaya_runtime.pref_get_f64 (pref_key key) with
        | Some v -> v
        | None -> default);
    get_bool =
      (fun key default ->
        match Kaya_runtime.pref_get_bool (pref_key key) with
        | Some v -> v
        | None -> default);
    set_string =
      (fun key value -> Kaya_runtime.pref_set_string (pref_write_key key) value);
    set_i64 =
      (fun key value -> Kaya_runtime.pref_set_i64 (pref_write_key key) value);
    set_f64 =
      (fun key value -> Kaya_runtime.pref_set_f64 (pref_write_key key) value);
    set_bool =
      (fun key value -> Kaya_runtime.pref_set_bool (pref_write_key key) value);
    remove = (fun key -> Kaya_runtime.pref_remove (pref_write_key key));
  }

(* The app's preferences store -- one per process. *)
let prefs () = the_prefs

(* A live menu item: its OWN id space (the c_menu_item counter) behind its
   own constructor, so cross-use with widget or node handles is a type
   error. *)
type menu_item = MenuItem of int64

(* A context catalog built UNANCHORED ([context_catalog]) for a template
   node: menu items are live and shared across stamped copies, so the
   catalog is built live and [Tpl.context_menu] attaches it. *)
type context_catalog = { cc_roots : int64 list; mutable cc_attached : bool }

(* A collection instance handle: the collection plus the key path selecting
   one stamped copy's table. *)
type collection = { cid : int64; cpath : Kaya_wire.value list }

(* One instance of a collection: the table inside the stamped copy selected
   by [path] (the empty path for a live-zone collection). *)
type instance = {
  path : Kaya_wire.value list;
  (* (key, (variant, fields)): the discriminant rides with the
     record, so refined reads and witnessed writes see the same fold
     the core holds. *)
  entries : (Kaya_wire.value * (int * Kaya_wire.value list)) list;
}

(* A collection entry's key: a string or a minted int64, the only two
   shapes [insert]/[insert_fresh] ever produce. The guest-facing type for
   every key a guest spells or reads back — never the wire's own sum. A
   MODULE with unprefixed members, the shape every other per-type module
   here takes ([Menu_role], [Run], [Document]). *)
module Key = struct
  type t = Str of string | Int of int64

  (* The smart constructors, for the call sites that pass one as a
     function ([List.map Key.str]). *)
  let str s = Str s
  let int n = Int n
  let text = function Str s -> s | Int n -> Int64.to_string n
end

type key = Key.t

let key_of_wire = function
  | Kaya_wire.Str s -> Key.Str s
  | Kaya_wire.I64 n -> Key.Int n
  | _ -> invalid_arg "kaya: a collection key is a string or an int64"

let key_to_wire = function
  | Key.Str s -> Kaya_wire.Str s
  | Key.Int n -> Kaya_wire.I64 n

let key_text = Key.text

(* An alert's three outcomes: the action the user pressed, by its slot,
   or the cancel every platform-native dismissal answers. A TYPE, not an
   int and a sentinel (DESIGN.md, Binding conventions). *)
module Alert_choice = struct
  type t = Action0 | Action1 | Cancel

  let of_wire code =
    if code = Kaya_wire.alert_choice_action0 then Action0
    else if code = Kaya_wire.alert_choice_action1 then Action1
    else if code = Kaya_wire.alert_choice_cancel then Cancel
    else
      invalid_arg
        (Printf.sprintf
           "kaya: an alert result carries choice %d, which this build does \
            not know"
           code)
end

(* A notification's two outcomes (docs/tasks-s3-plan.md N1). Dismissal is
   not one of them: two platforms never report it. *)
module Notification_outcome = struct
  type t = Activated | Refused

  let of_wire code =
    if code = Kaya_wire.notification_outcome_activated then Activated
    else if code = Kaya_wire.notification_outcome_refused then Refused
    else
      invalid_arg
        (Printf.sprintf
           "kaya: a notification result carries outcome %d, which this build \
            does not know"
           code)

  let name = function Activated -> "activated" | Refused -> "refused"
end

(* The app's OWN light/dark choice, applied process-wide from the
   default window (docs/tasks-s2b-plan.md R1-R3). [System] defers to the
   platform's own setting and to the harness knob. *)
module Appearance = struct
  type t = System | Light | Dark

  let wire = function
    | System -> Int64.of_int Kaya_wire.appearance_system
    | Light -> Int64.of_int Kaya_wire.appearance_light
    | Dark -> Int64.of_int Kaya_wire.appearance_dark
end

(* The height the phones open a sheet at (docs/sheet-plan.md §1.4); the
   desktops have nothing to say and ignore it. *)
module Detent = struct
  type t = Medium | Large

  let wire = function
    | Medium -> Int64.of_int Kaya_wire.detent_medium
    | Large -> Int64.of_int Kaya_wire.detent_large
end

(* How a picked file is re-opened: read, write (truncates; a save
   destination only adds the create) or both. *)
module File_mode = struct
  type t = Read | Write | Read_write

  let wire = function
    | Read -> Kaya_wire.file_mode_read
    | Write -> Kaya_wire.file_mode_write
    | Read_write -> Kaya_wire.file_mode_read_write
end

(* One file the picker answered with: a handle to redeem, a display
   name, and [local_path] — a RE-OPENABLE NAME, empty unless
   re-opening it actually works, which measurement puts at the three
   desktops and neither phone (DESIGN.md, File dialogs). *)
type picked_file = { handle : int64; name : string; local_path : string }

(* AN ASSET — a file this app's own BUILD put where the running program
   can find it (docs/assets-plan.md; tools/check-assets.py refuses a guest
   that resolves one itself). A MISS RAISES [Failure] carrying the core's
   sentence and nothing added; EACH CALL READS, and release is explicit
   ([asset_close]) and automatic (a [Gc.finalise] per handle). The byte
   value IS the reader here (DESIGN.md, Binding conventions). *)
type asset = Kaya_runtime.asset

let asset = Kaya_runtime.open_asset

(* Why [asset name] would raise — the sentence it would carry, handed
   over without raising. [""] means the name resolves. LINE 1 is the same
   on every platform and is the line a scene freezes; line 2 names the
   resolved place. Authored by [asset_why_not] in
   crates/kaya/src/assets.rs. *)
let asset_miss_sentence = Kaya_runtime.asset_miss_sentence
let asset_bytes = Kaya_runtime.asset_bytes
let asset_close = Kaya_runtime.asset_close

(* One collection entry's restored state, as the core states it. *)
module Undo_entry = struct
  type t = {
    collection : int64;
    (* The instance path: one key per enclosing For, empty at top level. *)
    path : key list;
    key : key;
    state : (int * Kaya_wire.value list) option;
  }
end


(* One collection instance's restored key order — present only for the
   instances whose order the step changed, because position is the one
   thing per-entry statements cannot carry. *)
module Undo_order = struct
  type t = { collection : int64; path : key list; keys : key list }
end


(* One text field's restored contents, and the FIELD'S OWN NAME beside
   it. [path] EMPTY means [id] is a live widget's id; a non-empty
   path means it is a TEMPLATE NODE's id and the path is the stamped
   copy's keys, outermost first. *)
module Undo_text = struct
  type t = { id : int64; path : key list; text : string }
end

type undo_text = Undo_text.t

(* WHAT THE CORE PUT BACK, and a STATEMENT of it rather than a replay of
   ops: every run says what a thing now IS, so applying it twice is the same
   as applying it once. APPLYING AN INVERSE EMITS NOTHING ELSE (the echo
   doctrine), so this is the ONLY thing an app hears about the step. *)
(* One signal an undo restored, in the BINDING's terms: the wire's own
   value type never reaches a guest, so the restored value is asked for
   by the type it was written as. *)
module Undo_signal = struct
  type t = { id : int64; value : Kaya_wire.value }

  let id s = s.id
  let as_str s = match s.value with Kaya_wire.Str v -> Some v | _ -> None
  let as_bool s = match s.value with Kaya_wire.Bool v -> Some v | _ -> None
  let as_i64 s = match s.value with Kaya_wire.I64 v -> Some v | _ -> None
  let as_f64 s = match s.value with Kaya_wire.F64 v -> Some v | _ -> None
end

module Undo_delta = struct
  type t = {
    signals : Undo_signal.t list;
    texts : Undo_text.t list;
    entries : Undo_entry.t list;
    orders : Undo_order.t list;
  }
end

type undo_delta = Undo_delta.t

(* One representation, arriving. Bytes ride as [string], OCaml's own
   binary buffer. [Image] may be a RE-ENCODE of what was copied, so
   compare what the image IS, never the bytes it arrived in. *)
type representation =
  | Text of string
  | Html of string
  | Image of string
  | Files of picked_file list
  | Custom of string * string

(* A drag operation (docs/dnd-plan.md D3): copy and move, nothing else;
   [None] is the outcome of a cancelled or refused drag. A MODULE
   because the menu-role type already owns the constructor [Copy]. *)
module Op = struct
  type t = Copy | Move
end

type op = Op.t

(* What a drop delivered (docs/dnd-plan.md D1): the representation a
   paste already delivers, the point in the destination's own
   coordinates, the operation the core settled on, and — for a reorder —
   the anchor row and the side it landed on. *)
type dropped = {
  point : float * float;
  operation : op option;
  anchor : key list;
  before : bool;
  clip : representation option;
}

(* --- Rich text (docs/rich-text-plan.md R1) --------------------------
   EVERY OFFSET IS A UTF-8 BYTE OFFSET into the widget's text
   (docs/ranges-units.md §7), and OCaml's [string] IS a byte sequence, so
   this binding converts nothing. A RANGE IS THE RANGES SUGAR'S PAIR,
   [(start, stop)], half-open. *)

(* One paragraph kind; drawn, never stored (docs/rich-text-plan.md R3). *)
type block =
  | Body
  | Heading1
  | Heading2
  | Heading3
  | Quote
  | Code_block

let block_name = function
  | Body -> "body"
  | Heading1 -> "heading1"
  | Heading2 -> "heading2"
  | Heading3 -> "heading3"
  | Quote -> "quote"
  | Code_block -> "code_block"

(* One attribute over one span; [value] is "true" for the flags, a URL
   for [link], a kind for [block]. *)
(* A span the CORE sent, refused BY NAME if its ends are out of order:
   no scene reaches it — the core always sends ordered spans — and a
   reversed one means the mirror and the core disagree (the idiom
   review's S3, in OCaml). *)
let decoded_span what start stop =
  if start > stop then
    invalid_arg
      (Printf.sprintf "kaya: a %s carries %d..%d, a reversed span" what start stop)
  else (start, stop)

(* The wire's own spelling of a flag attribute; [flag] coerces a bool to
   it at the boundary and [Run.is_flag] reads it back. *)
let flag_value = "true"

module Run = struct
  type t = { range : int * int; name : string; value : string }

  (* A flag attribute, on: bold, italic, underline, strike, code. *)
  let is_flag r = r.value = flag_value
end

type run = Run.t

(* A [rich] textarea's text and runs, kept current by the binding from
   the edits it delivers. *)
module Document = struct
  type t = { text : string; runs : Run.t list }

  let create text = { text; runs = [] }

  (* THE DOCUMENT COMES LAST, so a declaration reads as a pipeline:
     [Document.create doc |> Document.bold (0, 6) |> ...]. *)
  let mark range name value doc =
    { doc with runs = doc.runs @ [ { Run.range; name; value } ] }

  (* A FLAG attribute, on or off — the boolean spelling, coerced to the
     wire's own string here at the boundary. *)
  let flag range name on doc =
    mark range name (if on then flag_value else "false") doc

  let bold range doc = mark range "bold" "true" doc
  let italic range doc = mark range "italic" "true" doc
  let underline range doc = mark range "underline" "true" doc
  let strike range doc = mark range "strike" "true" doc
  let code range doc = mark range "code" "true" doc
  let link range url doc = mark range "link" url doc

  (* A paragraph's kind; the range covers whole paragraphs or is refused. *)
  let block range kind doc = mark range "block" (block_name kind) doc

  let attr_at doc byte name =
    Option.map
      (fun (r : Run.t) -> r.value)
      (List.find_opt
         (fun (r : Run.t) ->
        let start, stop = r.range in
        r.name = name && start <= byte && byte < stop)
         doc.runs)
end

type document = Document.t

(* What provoked an edit the widget reports (docs/rich-text-plan.md §13). *)
type edit_source = User | Ime_commit | Paste | Native_undo | Drop

let edit_source_name = function
  | User -> "user"
  | Ime_commit -> "ime_commit"
  | Paste -> "paste"
  | Native_undo -> "native_undo"
  | Drop -> "drop"

let edit_source_of_wire n =
  if n = Kaya_wire.edit_source_user then User
  else if n = Kaya_wire.edit_source_ime_commit then Ime_commit
  else if n = Kaya_wire.edit_source_paste then Paste
  else if n = Kaya_wire.edit_source_native_undo then Native_undo
  else if n = Kaya_wire.edit_source_drop then Drop
  else
    failwith
      (Printf.sprintf
         "kaya: text_edited carries edit source %d, which this build does \
          not know"
         n)

(* Replace [start..stop] with [inserted], whose runs carry offsets
   RELATIVE to the inserted text. [source] is what provoked an edit the
   widget delivered and [None] on one the app builds. *)
module Edit = struct
  type t = {
    range : int * int;
    inserted : string;
    runs : Run.t list;
    source : edit_source option;
  }

  let insert at text =
    { range = (at, at); inserted = text; runs = []; source = None }

  let delete range = { range; inserted = ""; runs = []; source = None }
  let replace range text = { range; inserted = text; runs = []; source = None }

  (* One attribute over the INSERTED text's own offsets. *)
  let mark range name value e =
    { e with runs = e.runs @ [ { Run.range; name; value } ] }

  (* A flag attribute over the inserted text, on or off. *)
  let flag range name on e =
    mark range name (if on then flag_value else "false") e
end

type edit = Edit.t

(* A toolbar act over a range; [value = None] is the attribute taken
   off. *)
module Format = struct
  type t = { range : int * int; name : string; value : string option }

  (* A flag attribute, on. *)
  let is_flag a = a.value = Some flag_value
end

type format_act = Format.t

type app = {
  (* Work handed over by other threads, waiting to run as transactions
     on the app thread. THE ONLY FIELD HERE TOUCHED FROM ANOTHER
     THREAD, and the only reason this record carries a mutex at all —
     everything else is app-thread-only by construction. *)
  post_lock : Mutex.t;
  mutable posted : (unit -> unit) list;
  mutable c_signal : int64;
  (* Live widgets AND template nodes, one sequence (DESIGN.md, Binding
     conventions). There is deliberately no [c_node]: without the field,
     a second node counter does not compile. *)
  mutable c_widget : int64;
  mutable c_collection : int64;
  mutable c_menu_item : int64;
  widget_handlers : (int64, unit -> unit) Hashtbl.t;
  (* Table sort requests, keyed by the For container's widget id
     (docs/tables-plan.md): the handler receives the 0-based column. *)
  sort_handlers : (int64, int -> unit) Hashtbl.t;
  (* A nested For's sort requests, keyed by its TEMPLATE NODE id: the
     handler receives the stamped copy's key path outermost first, then
     the 0-based column. *)
  node_sorts : (int64, Kaya_wire.value list -> int -> unit) Hashtbl.t;
  (* Menu dispatch tables, keyed by MENU ITEM id — their own id space,
     separate from every widget/node table. The node flavors receive the
     stamped copy's key path. *)
  menu_activated : (int64, unit -> unit) Hashtbl.t;
  menu_activated_node : (int64, Kaya_wire.value list -> unit) Hashtbl.t;
  menu_toggled : (int64, bool -> unit) Hashtbl.t;
  menu_toggled_node : (int64, Kaya_wire.value list -> bool -> unit) Hashtbl.t;
  menu_selected : (int64, int -> unit) Hashtbl.t;
  menu_selected_node : (int64, Kaya_wire.value list -> int -> unit) Hashtbl.t;
  node_handlers : (int64, Kaya_wire.value list -> unit) Hashtbl.t;
  widget_changes : (int64, string -> unit) Hashtbl.t;
  node_changes : (int64, Kaya_wire.value list -> string -> unit) Hashtbl.t;
  (* The rich mirror, one document per [rich] textarea
     (docs/rich-text-plan.md R1): folded from the two occurrences and
     from the app's own [set_document]/[apply_edit] as they are SENT. *)
  documents : (int64, document) Hashtbl.t;
  (* Template node -> (collection, field, level) for every template
     textarea bound to a document, so a copy's act folds into its ROW
     (docs/rich-text-plan.md §19). *)
  document_binds : (int64, int64 * int * int) Hashtbl.t;
  widget_edits : (int64, edit -> unit) Hashtbl.t;
  widget_formats : (int64, format_act -> unit) Hashtbl.t;
  (* A stamped rich copy's own acts, the node flavor of the two above:
     the handler receives the copy's key path first
     (docs/rich-text-plan.md §19). *)
  node_edits : (int64, Kaya_wire.value list -> edit -> unit) Hashtbl.t;
  node_formats : (int64, Kaya_wire.value list -> format_act -> unit) Hashtbl.t;
  widget_toggles : (int64, bool -> unit) Hashtbl.t;
  widget_values : (int64, float -> unit) Hashtbl.t;
  (* The pickers' committed values arrive as the packed I64; the sugar
     lifts them to [date]/[time] at registration. *)
  widget_dates : (int64, int64 -> unit) Hashtbl.t;
  widget_times : (int64, int64 -> unit) Hashtbl.t;
  node_dates : (int64, Kaya_wire.value list -> int64 -> unit) Hashtbl.t;
  node_times : (int64, Kaya_wire.value list -> int64 -> unit) Hashtbl.t;
  (* Window lifecycle: one handler each, receiving the window id. *)
  close_requested : (int64, unit -> unit) Hashtbl.t;
  entry_popped : (int64, unit -> unit) Hashtbl.t;
  back_requested : (int64, unit -> unit) Hashtbl.t;
  (* Per-sheet, keyed by sheet surface id (docs/sheet-plan.md). *)
  sheet_dismissed : (int64, unit -> unit) Hashtbl.t;
  dismiss_requested : (int64, unit -> unit) Hashtbl.t;
  section_selected : (int64, unit -> unit) Hashtbl.t;
  alert_handlers : (int64, Alert_choice.t -> unit) Hashtbl.t;
  mutable next_alert : int64;
  (* One-shot, keyed by the GUEST's notification id (the alert's
     request/result grammar; many may be live at once). *)
  notification_handlers : (int64, Notification_outcome.t -> unit) Hashtbl.t;
  (* NOT one-shot, and not keyed at all: the process-level handler for a
     result whose id has none above (docs/tasks-s9-plan.md R1). A
     relaunched process never called show_notification. *)
  mutable notification_activation : (int64 -> Notification_outcome.t -> unit) option;
  (* NOT one-shot either: a route declared by [link_route] answers every
     URL that matches it, for the life of the process
     (docs/app-links-plan.md §4), and the core owns the pattern table —
     nothing is kept here but the handler. *)
  link_handlers : (int64, (string * string) list -> unit) Hashtbl.t;
  mutable next_link_route : int64;
  (* [link_route] may be called before the first transaction, so its
     record waits here for one (the transaction drains it head-first). *)
  mutable pending_routes : string list;
  file_dialog_handlers : (int64, picked_file list -> unit) Hashtbl.t;
  mutable next_file_dialog : int64;
  (* Clipboard reads share the alert's request/result grammar and so
     its table shape: one-shot, keyed by request id. *)
  clipboard_handlers : (int64, representation option -> unit) Hashtbl.t;
  mutable next_clipboard_read : int64;
  widget_pastes : (int64, representation -> unit) Hashtbl.t;
  node_pastes : (int64, Kaya_wire.value list -> representation -> unit) Hashtbl.t;
  widget_drops : (int64, dropped -> unit) Hashtbl.t;
  node_drops : (int64, Kaya_wire.value list -> dropped -> unit) Hashtbl.t;
  drag_ended_handlers : (int64, op option -> unit) Hashtbl.t;
  node_drag_ended : (int64, Kaya_wire.value list -> op option -> unit) Hashtbl.t;
  window_closed : (int64, unit -> unit) Hashtbl.t;
  (* The history, per window and NOT one-shot: a history is walked as
     often as the user likes. *)
  undone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  redone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  node_toggles : (int64, Kaya_wire.value list -> bool -> unit) Hashtbl.t;
  (* A stamped slider's move and a stamped choice's pick, the node flavor of
     [widget_values]. *)
  node_values : (int64, Kaya_wire.value list -> float -> unit) Hashtbl.t;
  (* A slider gesture's SETTLED value, live and stamped
     (docs/slider-plan.md S2). *)
  widget_commits : (int64, float -> unit) Hashtbl.t;
  node_commits : (int64, Kaya_wire.value list -> float -> unit) Hashtbl.t;
  model : (int64, instance list) Hashtbl.t;
  (* The minter's counters, keyed by path the way [model] is. Kept on the
     app and NOT in the transaction's rollback journal, on purpose: the
     journal restores the model, never the counter, so a key spent by an
     abandoned transaction stays spent ([insert_fresh]). *)
  fresh : (int64, (Kaya_wire.value list * int64 ref) list) Hashtbl.t;
  children : (int64, int64 list) Hashtbl.t;
  mutable open_fors : int64 list;
  (* The record-time mirror-read guard's arming counter: >0 while any
     template body (a For body, a When body, a sum eliminator's arms) is
     being DECLARED. *)
  mutable tpl_depth : int;
  (* Signals recomputed from a collection after each of its mutations,
     written into the same transaction. *)
  derived : (int64, (unit -> unit) list) Hashtbl.t;
  (* Each canvas's declared viewbox, so a redraw in a LATER transaction
     does not have to repeat it (docs/canvas-plan.md §2.2). *)
  canvas_viewboxes : (int64, viewbox) Hashtbl.t;
  (* A canvas's DRAWING AS A FUNCTION OF THE SIZE IT WAS ASSIGNED
     (docs/canvas-plan.md §3.2.1), keyed by canvas id. [dispatch_loop]
     answers the ask itself and the guest never hears it. ONE SHAPE, NOT
     TWO: [~on_draw]'s handler is widened with an ignored time, so the
     arity never depends on the record kind. *)
  canvas_draws : (int64, draw -> viewbox -> float -> unit) Hashtbl.t;
}

(* One transaction: everything queued inside build (or a handler) applies
   atomically when it returns. *)
and tx = {
  app : app;
    mutable records : string list;
  (* The undo group's (window, label), kept OUT of [records] because it
     rides at the HEAD of the batch wherever [undoable] was called. *)
  mutable undo_group : (int64 * string) option;
  mutable journal : (int64 * instance list) list;
  (* Deriveds registered in this transaction: promoted on submit,
     abandoned with a rolled-back tx (their signals were never made). *)
  mutable pending_derived : (int64 * (unit -> unit)) list;
}

(* The ambient transaction: set for the extent of [build] (handler
   dispatch runs through build, so handlers get it too). *)
let ambient_tx : tx option ref = ref None

(* The app thread's id, learned when the dispatch loop starts. None
   before then, which is the single-threaded construction phase. *)
let app_thread : int option ref = ref None

(* The OCaml spelling of a rule the handle bindings get from a stale-tx
   check. [ambient_tx] above is a GLOBAL ref, NOT thread-local, so a
   transaction opened on a background thread would stamp its records into
   the app thread's open transaction — silently, and interleaved. *)
let require_app_thread () =
  match !app_thread with
  | Some owner when owner <> Thread.id (Thread.self ()) ->
      failwith
        (Printf.sprintf
           "kaya: a transaction belongs to the app thread -- this is thread %d, the app \
            thread is %d. To mutate from a background thread use Kaya_app.post, which runs \
            your function as a transaction over there."
           (Thread.id (Thread.self ()))
           owner)
  | _ -> ()

(* The five engine reads bindings/ocaml/checks/*.ml makes, and nothing
   else — the door that lets [app] and [tx] be abstract in the .mli
   (the idiom review's O1). A guest calls none of them. *)
module For_checks = struct
  let derived app = app.derived
  let sort_handlers app = app.sort_handlers

  let node_sorts app =
    let out : (int64, key list -> int -> unit) Hashtbl.t =
      Hashtbl.create (max 1 (Hashtbl.length app.node_sorts))
    in
    Hashtbl.iter
      (fun id f ->
        Hashtbl.replace out id (fun keys c -> f (List.map key_to_wire keys) c))
      app.node_sorts;
    out

  let pending_routes app = app.pending_routes
  let records tx = tx.records
  let collection_id c = c.cid

  (* The decode-side span refusal: no scene can produce a reversed span
     (the core always sends ordered ones), so the check drives it here. *)
  let decoded_span = decoded_span
end

let the_tx () =
  match !ambient_tx with
  | Some tx -> tx
  | None ->
      invalid_arg
        "kaya: builder called outside build (no ambient transaction)"

let create () =
  {
    post_lock = Mutex.create ();
    posted = [];
    c_signal = 0L;
    c_widget = 0L;
    c_collection = 0L;
    c_menu_item = 0L;
    widget_handlers = Hashtbl.create 8;
    sort_handlers = Hashtbl.create 8;
    node_sorts = Hashtbl.create 8;
    menu_activated = Hashtbl.create 8;
    menu_activated_node = Hashtbl.create 8;
    menu_toggled = Hashtbl.create 8;
    menu_toggled_node = Hashtbl.create 8;
    menu_selected = Hashtbl.create 8;
    menu_selected_node = Hashtbl.create 8;
    node_handlers = Hashtbl.create 8;
    widget_changes = Hashtbl.create 8;
    node_changes = Hashtbl.create 8;
    documents = Hashtbl.create 8;
    document_binds = Hashtbl.create 8;
    node_edits = Hashtbl.create 8;
    node_formats = Hashtbl.create 8;
    widget_edits = Hashtbl.create 8;
    widget_formats = Hashtbl.create 8;
    widget_toggles = Hashtbl.create 8;
    widget_values = Hashtbl.create 8;
    widget_dates = Hashtbl.create 8;
    widget_times = Hashtbl.create 8;
    node_dates = Hashtbl.create 8;
    node_times = Hashtbl.create 8;
    close_requested = Hashtbl.create 8;
    entry_popped = Hashtbl.create 8;
    back_requested = Hashtbl.create 8;
    sheet_dismissed = Hashtbl.create 8;
    dismiss_requested = Hashtbl.create 8;
    section_selected = Hashtbl.create 8;
    alert_handlers = Hashtbl.create 8;
    next_alert = 0L;
    notification_handlers = Hashtbl.create 8;
    notification_activation = None;
    link_handlers = Hashtbl.create 4;
    next_link_route = 0L;
    pending_routes = [];
    file_dialog_handlers = Hashtbl.create 4;
    next_file_dialog = 0L;
    clipboard_handlers = Hashtbl.create 4;
    next_clipboard_read = 0L;
    widget_pastes = Hashtbl.create 4;
    node_pastes = Hashtbl.create 4;
    widget_drops = Hashtbl.create 4;
    node_drops = Hashtbl.create 4;
    drag_ended_handlers = Hashtbl.create 4;
    node_drag_ended = Hashtbl.create 4;
    window_closed = Hashtbl.create 8;
    undone_handlers = Hashtbl.create 4;
    redone_handlers = Hashtbl.create 4;
    node_toggles = Hashtbl.create 8;
    node_values = Hashtbl.create 8;
    widget_commits = Hashtbl.create 8;
    node_commits = Hashtbl.create 8;
    model = Hashtbl.create 8;
    fresh = Hashtbl.create 8;
    children = Hashtbl.create 8;
    open_fors = [];
    tpl_depth = 0;
    derived = Hashtbl.create 8;
    canvas_viewboxes = Hashtbl.create 8;
    canvas_draws = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records

let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

let counter_of app cid path =
  let instances = Option.value ~default:[] (Hashtbl.find_opt app.fresh cid) in
  match List.assoc_opt path instances with
  | Some counter -> counter
  | None ->
      let counter = ref 0L in
      Hashtbl.replace app.fresh cid (instances @ [ (path, counter) ]);
      counter

let mint_key app cid path =
  let counter = counter_of app cid path in
  counter := Int64.add !counter 1L;
  !counter

let absorb_key app cid path key =
  match key with
  | Kaya_wire.I64 n ->
      let counter = counter_of app cid path in
      if Int64.compare n !counter > 0 then counter := n
  | _ -> ()

(* The record-time mirror-read guard: a template body records once and the
   core replays it — a model read inside one bakes this moment's data into
   every future stamp, silently dead. *)
let guard_mirror_read () =
  let tx = the_tx () in
  if tx.app.tpl_depth > 0 then
    failwith
      "kaya: model read inside a template body — the template records once \
       and replays; bind a signal, use the element's field, or derive for \
       computed values"

(* Bracket a template body: the depth arms the guard; a raise out of
   the body (the guard's own included) must not leave it stuck — the
   tx boundary rolls back and the app survives the raise. *)
let in_tpl_scope app f =
  app.tpl_depth <- app.tpl_depth + 1;
  Fun.protect ~finally:(fun () -> app.tpl_depth <- app.tpl_depth - 1) f

let touch tx cid =
  if not (List.mem_assoc cid tx.journal) then
    tx.journal <- (cid, instances_of tx.app cid) :: tx.journal

(* One [value list] per entry: the record's wire fields (a scalar
   collection is the one-field case). *)
let model_set tx cid path key variant value =
  touch tx cid;
  let entry = (variant, value) in
  let upsert i =
    if List.mem_assoc key i.entries then
      { i with entries = List.map (fun (k, v) -> (k, if k = key then entry else v)) i.entries }
    else { i with entries = i.entries @ [ (key, entry) ] }
  in
  let instances = instances_of tx.app cid in
  let instances =
    if List.exists (fun i -> i.path = path) instances then
      List.map (fun i -> if i.path = path then upsert i else i) instances
    else instances @ [ { path; entries = [ (key, entry) ] } ]
  in
  Hashtbl.replace tx.app.model cid instances

let rec purge_children tx cid prefix =
  let starts_with i =
    List.length i.path >= List.length prefix
    && List.filteri (fun at _ -> at < List.length prefix) i.path = prefix
  in
  List.iter
    (fun kid ->
      touch tx kid;
      Hashtbl.replace tx.app.model kid
        (List.filter (fun i -> not (starts_with i)) (instances_of tx.app kid));
      purge_children tx kid prefix)
    (Option.value ~default:[] (Hashtbl.find_opt tx.app.children cid))

let model_remove tx cid path key =
  touch tx cid;
  Hashtbl.replace tx.app.model cid
    (List.map
       (fun i ->
         if i.path = path then { i with entries = List.filter (fun (k, _) -> k <> key) i.entries }
         else i)
       (instances_of tx.app cid));
  (* The core tears down the copy, taking descendant collection
     instances with it; the model follows. *)
  purge_children tx cid (path @ [ key ])

(* The mechanical reorder; move_entry validates key and anchor first,
   so the anchor is always present here when given. *)
let model_move tx cid path key before =
  touch tx cid;
  Hashtbl.replace tx.app.model cid
    (List.map
       (fun i ->
         if i.path <> path || not (List.mem_assoc key i.entries) then i
         else begin
           let entry = (key, List.assoc key i.entries) in
           let rest = List.filter (fun (k, _) -> k <> key) i.entries in
           let entries =
             match before with
             | Some anchor ->
                 List.concat_map
                   (fun (k, v) -> if k = anchor then [ entry; (k, v) ] else [ (k, v) ])
                   rest
             | None -> rest @ [ entry ]
           in
           { i with entries }
         end)
       (instances_of tx.app cid))

let recompute_derived tx cid path =
  if path = [] then begin
    (match Hashtbl.find_opt tx.app.derived cid with
    | Some fns -> List.iter (fun f -> f ()) fns
    | None -> ());
    List.iter (fun (c, f) -> if c = cid then f ()) (List.rev tx.pending_derived)
  end

(* Run a scene program with a fresh ambient transaction and submit it
   atomically. *)
let build app (program : unit -> 'a) =
  require_app_thread ();
  let tx =
    { app; records = []; undo_group = None; journal = []; pending_derived = [] }
  in
  let outer = !ambient_tx in
  ambient_tx := Some tx;
  let restore () = ambient_tx := outer in
  match program () with
  | result ->
      restore ();
      List.iter
        (fun (cid, f) ->
          Hashtbl.replace app.derived cid
            (Option.value ~default:[] (Hashtbl.find_opt app.derived cid) @ [ f ]))
        (List.rev tx.pending_derived);
      (* The group marker leads the batch whatever order the program
         wrote it in: head-of-batch is the one unambiguous position. *)
      let records =
        match tx.undo_group with
        | Some (window, label) ->
            Kaya_wire.tx_undo_group window (Kaya_wire.Str label)
            :: List.rev tx.records
        | None -> List.rev tx.records
      in
      (* The pending link-route declarations go FIRST, in declaration
         order (docs/app-links-plan.md §4; Rust's PENDING_ROUTES drained
         head-first by Tx::commit is the shape). *)
      let records = app.pending_routes @ records in
      app.pending_routes <- [];
      if records <> [] then Kaya_runtime.submit records;
      result
  | exception e ->
      restore ();
      List.iter (fun (cid, saved) -> Hashtbl.replace app.model cid saved) tx.journal;
      raise e

(* Run [program] as a transaction on the app thread, soon. THE ONE
   function safe to call from another thread. A posted thunk runs in its
   OWN transaction, after whatever is running now, so posting from inside
   a handler queues for after and never nests. *)
let post app (program : unit -> unit) =
  Mutex.lock app.post_lock;
  app.posted <- app.posted @ [ program ];
  Mutex.unlock app.post_lock;
  (* The app thread may be parked in C waiting on the ring. Posted work
     is not an occurrence and never enters that ring, so this is the
     only way it hears about it. *)
  Kaya_runtime.wake ()

(* One handler dispatch: an exception crosses the build boundary (which
   restored the model and dropped the records), is logged, and the loop
   moves to the next occurrence. *)
let dispatch app (program : unit -> unit) =
  try build app program
  with e ->
    Printf.eprintf "kaya: handler raised (transaction rolled back): %s\n%!"
      (Printexc.to_string e)

(* Make this transaction ONE undoable step, under [label]
   (docs/undo-plan.md D2). CALLABLE ANYWHERE IN THE TRANSACTION — the
   marker still rides at the HEAD of the batch. WHAT A GROUP MAY HOLD is
   the reactive half: signal writes and collection deltas. *)
let undoable ?(window = 0L) label =
  let tx = the_tx () in
  if tx.undo_group <> None then
    failwith "kaya: this transaction is already an undo group — one name per step";
  tx.undo_group <- Some (window, label)

(* A civil date: year (proleptic Gregorian), month 1-12, day 1-31, with
   no zone and no instant (docs/datetime-plan.md D2). An I64 in packed
   decimal on the wire; a date picker's value and a Date record field. *)
type date = { year : int; month : int; day : int }

(* A civil time of day: hour 0-23, minute 0-59. No seconds (D3). *)
type time = { hour : int; minute : int }

let string_of_date d = Printf.sprintf "%04d-%02d-%02d" d.year d.month d.day
let string_of_time t = Printf.sprintf "%02d:%02d" t.hour t.minute

let days_in_month year month =
  if month = 2 && year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0) then 29
  else [| 31; 28; 31; 30; 31; 30; 31; 31; 30; 31; 30; 31 |].(month - 1)

(* The packing, and the wall a plain record cannot be given by its type:
   an impossible date is refused BY NAME here rather than at apply. *)
let pack_date d =
  if d.month < 1 || d.month > 12 then
    invalid_arg
      (Printf.sprintf "kaya: %d is not a month (1..12) — that is not a date" d.month);
  if d.day < 1 || d.day > days_in_month d.year d.month then
    invalid_arg
      (Printf.sprintf "kaya: %04d-%02d has no day %d" d.year d.month d.day);
  Kaya_wire.pack_date d.year d.month d.day

let pack_time t =
  if t.hour < 0 || t.hour > 23 then
    invalid_arg
      (Printf.sprintf "kaya: %d is not an hour (0..23) — that is not a time" t.hour);
  if t.minute < 0 || t.minute > 59 then
    invalid_arg (Printf.sprintf "kaya: %d is not a minute (0..59)" t.minute);
  Kaya_wire.pack_time t.hour t.minute

let date_of_packed packed =
  let year, month, day = Kaya_wire.unpack_date packed in
  { year; month; day }

let time_of_packed packed =
  let hour, minute = Kaya_wire.unpack_time packed in
  { hour; minute }

(* The one place a signal is minted: [enc] is recorded once, on the
   handle, so every later write goes through the same wire tag the
   signal was declared with. Internal — a guest reaches this only
   through the four typed constructors below. *)
let signal_of (enc : 'a -> Kaya_wire.value) (initial : 'a) : 'a signal =
  let tx = the_tx () in
  tx.app.c_signal <- Int64.add tx.app.c_signal 1L;
  let id = tx.app.c_signal in
  emit tx (Kaya_wire.tx_create_signal id (enc initial));
  { sig_id = id; sig_enc = enc }

(* THE TYPE WITNESS, ONE FOR THE BINDING (the idiom review's O3): a GADT
   is OCaml's own answer to type-directed dispatch (Fmt, Irmin.Type,
   Caqti's row types), and it is CHECKED where a constructor passed as
   [\'a -> \'a signal] was not — any function of that shape satisfied the
   old [derive]. Qualified on purpose: [Scalar.Str] is this binding's
   word, never the wire's. *)
module Scalar = struct
  type _ t =
    | Str : string t
    | Bool : bool t
    | I64 : int64 t
    | F64 : float t
    | Date : date t
    | Time : time t
end

let signal : type a. a Scalar.t -> a -> a signal =
 fun witness initial ->
  match witness with
  | Scalar.Str -> signal_of (fun s -> Kaya_wire.Str s) initial
  | Scalar.Bool -> signal_of (fun b -> Kaya_wire.Bool b) initial
  | Scalar.I64 -> signal_of (fun n -> Kaya_wire.I64 n) initial
  | Scalar.F64 -> signal_of (fun x -> Kaya_wire.F64 x) initial
  | Scalar.Date -> signal_of (fun d -> Kaya_wire.I64 (pack_date d)) initial
  | Scalar.Time -> signal_of (fun t -> Kaya_wire.I64 (pack_time t)) initial

let write (s : 'a signal) (v : 'a) : unit =
  emit (the_tx ()) (Kaya_wire.tx_write_signal s.sig_id (s.sig_enc v))

let widget kind =
  let tx = the_tx () in
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_widget id kind);
  Widget id

(* A widget's text: a button's caption, a label's line — and, on the
   uncontrolled text widgets, the "open a document into the editor"
   write. A write that CHANGES a textarea's text DROPS whatever ranges
   were declared over it and spends the field's native undo history,
   which is why undo's D7 treats it as an episode boundary. *)
let set_text (Widget id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

(* Set a widget's flex weight within its row/column: 0 is natural size,
   positive weights divide the container's leftover main-axis space in
   proportion (see Prop::Grow in the core). *)
let set_grow (Widget id) weight = emit (the_tx ()) (Kaya_wire.tx_set_grow id weight)

(* Whether a widget spans its container's cross axis — a column's width,
   a row's height — whatever the container's [~align]
   (docs/layout-knobs-plan.md §1). Unset, the kind's own default holds. *)
let set_fill (Widget id) on = emit (the_tx ()) (Kaya_wire.tx_set_fill id on)

(* THE GRID THAT FITS (docs/layout-knobs-plan.md §3): as many columns as
   fit this grid's width at [min_width] DIP each, sharing the extra. An
   explicit [~columns_when] still wins while its class holds. *)
let set_columns_auto (Widget id) min_width =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_set_columns id 0.0);
  emit tx (Kaya_wire.tx_set_min_column_width id min_width)

(* A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): children keep their
   natural size and move onto the next line when the row runs out of
   width, leading-aligned, the row's [~spacing] on both axes. Rows only,
   and no child of a wrapping row may grow. *)
let set_wrap (Widget id) on = emit (the_tx ()) (Kaya_wire.tx_set_wrap id on)

(* A widget's accessibility IDENTIFIER: a stable authored key that assistive
   tooling and UI automation address it by, and which is NEVER spoken. *)
let set_a11y_id (Widget id) value = emit (the_tx ()) (Kaya_wire.tx_set_a11y_id id value)

(* What an assistive client SPEAKS for a widget, deliberately separate
   from the identifier. Leave it unset to keep whatever the platform
   derives from the control's own content; setting it OVERRIDES that. *)
let set_a11y_label (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_label id value)

(* What ACTIVATING this widget does — the platforms' hint (Apple defines it
   as the result of performing an action; Android carries it as the click
   action's label). Write a VERB PHRASE. *)
let set_a11y_hint (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_hint id value)

(* The SIGNAL-SOURCED forms of the trio, spelled as [bind_text] is; the
   constructors take them as [?a11y_id_bind] and [?a11y_label_bind]. *)
let bind_a11y_id (Widget id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_a11y_id id s.sig_id)
let bind_a11y_label (Widget id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_a11y_label id s.sig_id)
let bind_a11y_hint (Widget id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_a11y_hint id s.sig_id)

(* A widget's HELP TEXT: one short sentence saying what the control is or
   does (docs/tooltip-plan.md T1). Universal. The platform picks the
   surface — a tooltip on the desktops, nothing visible on the iPhone —
   and hands the text to its assistive reader; an authored hint wins the
   hint slot (T3). *)
let set_help (Widget id) value = emit (the_tx ()) (Kaya_wire.tx_set_help id value)
let bind_help (Widget id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_help id s.sig_id)

(* The PROMPT a text field shows while it is empty (docs/search-plan.md
   S3): the platform's own placeholder, never part of the text and never
   emitted. Entry, textarea and search only, checked at the root. *)
let set_placeholder (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_placeholder id value)

let bind_placeholder (Widget id) (s : string signal) =
  emit (the_tx ()) (Kaya_wire.tx_bind_placeholder id s.sig_id)

(* The DESTINATION a [Link] label opens (docs/tasks-s2-plan.md T3): the
   platform's own opener takes it and nothing is emitted. *)
let set_href (Widget id) value = emit (the_tx ()) (Kaya_wire.tx_set_href id value)

let bind_href (Widget id) (s : string signal) =
  emit (the_tx ()) (Kaya_wire.tx_bind_href id s.sig_id)

(* The three universal props as they ride every constructor: applied
   together, in one place, so a new constructor cannot pick up [~grow]
   and quietly miss these. *)
let set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w =
  Option.iter (fun v -> set_a11y_id w v) a11y_id;
  Option.iter (fun s -> bind_a11y_id w s) a11y_id_bind;
  Option.iter (fun v -> set_a11y_label w v) a11y_label;
  Option.iter (fun s -> bind_a11y_label w s) a11y_label_bind;
  Option.iter (fun v -> set_help w v) help;
  Option.iter (fun s -> bind_help w s) help_bind

(* A container's inter-child gap (main axis, DIP; the normalized default is
   8). *)
let set_spacing (Widget id) gap = emit (the_tx ()) (Kaya_wire.tx_set_spacing id gap)

(* A container's OWN padding (DIP between its bounds and its children,
   uniform on all four sides) — the window inset one level down, which is
   why a full-bleed [window ~inset:0.0] can still hold an inset status row. *)
let set_inset (Widget id) pad = emit (the_tx ()) (Kaya_wire.tx_set_inset id pad)

(* A container's cross-axis child placement (the align spec enum; the
   normalized default is [Start]). *)
type align = Start | Center | End | Stretch | Baseline

let align_wire = function
  | Start -> 0L
  | Center -> 1L
  | End -> 2L
  | Stretch -> 3L
  | Baseline -> 4L

let set_align (Widget id) a = emit (the_tx ()) (Kaya_wire.tx_set_align id (align_wire a))

(* A container's ARRANGEMENT AXIS (docs/adaptive-layout-plan.md D1/D2):
   identity is the creation kind, presentation is this prop, so a widget
   built by [row] stays addressable as [row#N] whatever its axis says.
   No constructor spells it; the runtime toggle and a breakpoint do. *)
type axis = Horizontal | Vertical

(* A window's named SIZE CLASS (spec enum "size_class"): what
   [~stack_when] speaks in place of an author-invented width. An app
   names a class, it never asks which one the window is. *)
type size_class = Compact

let axis_wire = function
  | Horizontal -> Int64.of_int Kaya_wire.axis_horizontal
  | Vertical -> Int64.of_int Kaya_wire.axis_vertical

let set_axis (Widget id) a = emit (the_tx ()) (Kaya_wire.tx_set_axis id (axis_wire a))

(* SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
   never how it looks. [Destructive] and [Prominent] are an ACTION's
   emphasis and belong to a button; [Heading] and [Caption] are text
   hierarchy facts and belong to a label. *)
type role = Destructive | Prominent | Heading | Caption | Plain | Switch | Link

let role_wire = function
  | Destructive -> Int64.of_int Kaya_wire.role_destructive
  | Prominent -> Int64.of_int Kaya_wire.role_prominent
  | Heading -> Int64.of_int Kaya_wire.role_heading
  | Caption -> Int64.of_int Kaya_wire.role_caption
  | Plain -> Int64.of_int Kaya_wire.role_plain
  | Switch -> Int64.of_int Kaya_wire.role_switch
  | Link -> Int64.of_int Kaya_wire.role_link

let set_role (Widget id) r = emit (the_tx ()) (Kaya_wire.tx_set_role id (role_wire r))

(* THE SEMANTIC ICON VOCABULARY (spec enum "symbol";
   docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes"). *)
type symbol =
  | Add
  | Remove
  (* Destroying something, the wastebasket idiom — distinct from
     [Remove], which takes an item out of a list. *)
  | Delete
  | Edit
  (* Confirmation, the checkmark idiom. *)
  | Done
  (* Dismissal, the ✕ idiom — not [Delete]. *)
  | Close
  | Search
  | Settings
  | Refresh
  | Info
  | Warning
  (* The direction-relative pair: every platform mirrors these under a
     right-to-left layout, so they mean BACKWARD and FORWARD in reading
     order, never "left" and "right". *)
  | Back
  | Forward
  (* The overflow affordance (the ellipsis idiom). *)
  | More
  | Copy
  | Paste
  (* Favourite. *)
  | Star
  | Lock
  (* A person or account. *)
  | Person
  | Home

let symbol_wire = function
  | Add -> Int64.of_int Kaya_wire.symbol_add
  | Remove -> Int64.of_int Kaya_wire.symbol_remove
  | Delete -> Int64.of_int Kaya_wire.symbol_delete
  | Edit -> Int64.of_int Kaya_wire.symbol_edit
  | Done -> Int64.of_int Kaya_wire.symbol_done
  | Close -> Int64.of_int Kaya_wire.symbol_close
  | Search -> Int64.of_int Kaya_wire.symbol_search
  | Settings -> Int64.of_int Kaya_wire.symbol_settings
  | Refresh -> Int64.of_int Kaya_wire.symbol_refresh
  | Info -> Int64.of_int Kaya_wire.symbol_info
  | Warning -> Int64.of_int Kaya_wire.symbol_warning
  | Back -> Int64.of_int Kaya_wire.symbol_back
  | Forward -> Int64.of_int Kaya_wire.symbol_forward
  | More -> Int64.of_int Kaya_wire.symbol_more
  | Copy -> Int64.of_int Kaya_wire.symbol_copy
  | Paste -> Int64.of_int Kaya_wire.symbol_paste
  | Star -> Int64.of_int Kaya_wire.symbol_star
  | Lock -> Int64.of_int Kaya_wire.symbol_lock
  | Person -> Int64.of_int Kaya_wire.symbol_person
  | Home -> Int64.of_int Kaya_wire.symbol_home

(* WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
   "platform"; docs/styling-plan.md Slice 2b).

   AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS: [Sys.os_type] is
   "Unix" for macOS, Linux, iOS and Android alike. *)
type platform = Mac | Ios | Linux | Windows | Android

let platform_wire = function
  | Mac -> Int64.of_int Kaya_wire.platform_mac
  | Ios -> Int64.of_int Kaya_wire.platform_ios
  | Linux -> Int64.of_int Kaya_wire.platform_linux
  | Windows -> Int64.of_int Kaya_wire.platform_windows
  | Android -> Int64.of_int Kaya_wire.platform_android

let bind_text (Widget id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_text id s.sig_id)
let set_checked (Widget id) checked = emit (the_tx ()) (Kaya_wire.tx_set_checked id checked)

(* An image's content: one registration copy of the encoded bytes into core-
   owned memory. *)
let set_source (Widget id) data =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_set_source id (Kaya_runtime.register_blob data))

(* The same slot from an open asset: the core clones one refcount into the
   blob table, so the picture never enters the OCaml heap
   ([~icon_asset]'s route, verbatim). *)
let set_source_asset (Widget id) a =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_set_source id (Kaya_runtime.asset_blob a))

let bind_source (Widget id) (s : bytes signal) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_bind_source id s.sig_id)

(* Drop an entry's content now (the field stays authoritative). *)
let clear (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_clear)

(* Give this widget the keyboard focus. *)
let focus (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_focus)

(* --- Text ranges: the three primitives an editor cannot write itself -
   A RANGE IS A PAIR OF UTF-8 BYTE OFFSETS [(start, stop)], half-open;
   OCaml's [string] IS a byte sequence, so this binding converts nothing.
   THE CORE VALIDATES AND REFUSES at one chokepoint, loudly, because
   macOS ABORTS THE PROCESS on a malformed offset (docs/traps.md). An
   endpoint inside a grapheme cluster is NOT refused. *)

(* DECLARE the decorated ranges of a textarea, replacing whatever was
   declared before; [[]] is the clear. APP-OWNED AND NEVER TRACKED
   (docs/ranges-plan.md D2): the first edit of any kind DROPS the set. *)
let highlight_ranges (Widget id) ranges =
  emit (the_tx ())
    (Kaya_wire.tx_highlight_ranges id (List.length ranges)
       (List.concat_map
          (fun (start, stop) ->
            [ Kaya_wire.I64 (Int64.of_int start); Kaya_wire.I64 (Int64.of_int stop) ])
          ranges))

(* Put the textarea's selection at one range; [(at, at)] is a caret.
   REFUSED WHILE THE USER IS COMPOSING through an input method (D4), and
   the refusal is a NO-OP rather than an exception: composition state is
   on no kaya channel. Ask again after the next [~on_change]. *)
let select_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_select_range id (Int64.of_int start) (Int64.of_int stop))

(* Scroll the textarea so a range is inside the viewport. A PURE EFFECT: no
   state moves, the selection is untouched, and undo does not put the scroll
   back — undo restores state, not where you were looking. *)
let reveal_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_reveal_range id (Int64.of_int start) (Int64.of_int stop))

(* --- Rich text: the document, its edits, the widget's own acts ------
   (docs/rich-text-plan.md R1). The offsets are the ranges' own unit.
   [Run], [Document], [Edit] and [Format] are declared earlier, beside
   [block]/[block_name], the one thing [Document.block] needs. *)

(* Four values per run — start, stop, name, value — the shape both
   writes and both occurrences carry. *)
let run_values (runs : Run.t list) =
  List.concat_map
    (fun (r : Run.t) ->
      [
        Kaya_wire.I64 (Int64.of_int (fst r.range));
        Kaya_wire.I64 (Int64.of_int (snd r.range));
        Kaya_wire.Str r.name;
        Kaya_wire.Str r.value;
      ])
    runs

let rec runs_of_values values : Run.t list =
  match values with
  | Kaya_wire.I64 start :: Kaya_wire.I64 stop :: Kaya_wire.Str name
    :: Kaya_wire.Str value :: rest ->
      {
        Run.range = decoded_span "run" (Int64.to_int start) (Int64.to_int stop);
        name;
        value;
      }
      :: runs_of_values rest
  | _ -> []

(* A stamped copy's document is a record FIELD (docs/rich-text-plan.md
   §19): the field's Blob bytes are ONE flat value list — the text, then
   four values per run — the bytes [set_rich_text] already ships
   (crates/kaya/src/wire.rs, [document_blob] / [read_document_blob]). *)
let document_blob (doc : Document.t) =
  let b = Buffer.create 64 in
  Kaya_wire.encode_values b
    (Kaya_wire.Str doc.text :: run_values doc.runs);
  Buffer.contents b

let document_of_blob bytes : Document.t =
  if String.length bytes < 8 then
    invalid_arg
      (Printf.sprintf "kaya: a document blob carries its count first; this one is %d byte(s)"
         (String.length bytes));
  let byte i = Char.code bytes.[i] in
  let count = Kaya_wire.u32_at byte 0 in
  let at = ref 8 in
  let values = ref [] in
  for _ = 1 to count do
    let v, next = Kaya_wire.parse_value byte !at in
    values := v :: !values;
    at := next
  done;
  match List.rev !values with
  | Kaya_wire.Str text :: rest -> { Document.text; runs = runs_of_values rest }
  | _ ->
      invalid_arg
        (Printf.sprintf
           "kaya: a document blob starts with its text; this one holds %d value(s)"
           count)

(* The core's normal form (crates/kaya/src/scene.rs, [RichDoc::normalize]),
   so the mirror and the core's document spell one string. *)
let normalize_runs (runs : Run.t list) : Run.t list =
  let names = List.sort_uniq compare (List.map (fun (r : Run.t) -> r.name) runs) in
  let per_name name =
    let painted =
      List.fold_left
        (fun painted (run : Run.t) ->
          let start, stop = run.range in
          if start >= stop then painted
          else
            List.concat_map
              (fun (old : Run.t) ->
                let o_start, o_stop = old.range in
                if o_stop <= start || o_start >= stop then [ old ]
                else
                  (if o_start < start then [ { old with Run.range = (o_start, start) } ]
                   else [])
                  @
                  if o_stop > stop then [ { old with Run.range = (stop, o_stop) } ]
                  else [])
              painted
            @ [ run ])
        []
        (List.filter (fun (r : Run.t) -> r.name = name) runs)
    in
    let sorted =
      List.stable_sort
        (fun (a : Run.t) (b : Run.t) -> compare (fst a.range) (fst b.range))
        painted
    in
    List.rev
      (List.fold_left
         (fun merged (run : Run.t) ->
           match merged with
           | (last : Run.t) :: rest
             when snd last.range = fst run.range && last.value = run.value ->
               { last with Run.range = (fst last.range, snd run.range) } :: rest
           | _ -> run :: merged)
         [] sorted)
  in
  List.stable_sort
    (fun (a : Run.t) (b : Run.t) ->
      compare (fst a.range, a.name) (fst b.range, b.name))
    (List.concat_map per_name names)

let the_document app id : Document.t =
  match Hashtbl.find_opt app.documents id with
  | Some doc -> doc
  | None -> { text = ""; runs = [] }

(* The core's own fold rule, over ANY document — a live mirror or a
   stamped copy's row field (crates/kaya/src/app.rs, [fold_edit];
   docs/rich-text-plan.md §19). *)
let fold_edit (doc : Document.t) (start, stop) inserted (runs : Run.t list) : Document.t =
  let len = String.length doc.text in
  let boundary at =
    at = len || Char.code doc.text.[at] land 0xc0 <> 0x80
  in
  if start < 0 || start > stop || stop > len || not (boundary start)
     || not (boundary stop)
  then
    (* A mirror out of step with the core would splice garbage. *)
    { Document.text = inserted; runs }
  else begin
    let shift = String.length inserted - (stop - start) in
    let kept =
      List.concat_map
        (fun (run : Run.t) ->
          let r_start, r_stop = run.range in
          (if r_start < start then
             [ { run with Run.range = (r_start, min r_stop start) } ]
           else [])
          @
          if r_stop > stop then
            [ { run with Run.range = (max r_start stop + shift, r_stop + shift) } ]
          else [])
        doc.runs
    in
    let landed =
      List.map
        (fun (run : Run.t) ->
          let r_start, r_stop = run.range in
          { run with Run.range = (r_start + start, r_stop + start) })
        runs
    in
    let text =
      String.sub doc.text 0 start ^ inserted
      ^ String.sub doc.text stop (len - stop)
    in
    { Document.text; runs = normalize_runs (kept @ landed) }
  end

(* The core's [fold_format], over any document. *)
let fold_format (doc : Document.t) (start, stop) name value : Document.t =
  if start >= stop then doc
  else begin
    let kept =
      List.concat_map
        (fun (run : Run.t) ->
          let r_start, r_stop = run.range in
          if run.name <> name || r_stop <= start || r_start >= stop then [ run ]
          else
            (if r_start < start then [ { run with Run.range = (r_start, start) } ]
             else [])
            @
            if r_stop > stop then [ { run with Run.range = (stop, r_stop) } ] else [])
        doc.runs
    in
    let painted =
      match value with
      | Some v -> kept @ [ { Run.range = (start, stop); name; value = v } ]
      | None -> kept
    in
    { doc with runs = normalize_runs painted }
  end

(* One delivered act, into the live mirror (crates/kaya/src/app.rs,
   [absorb_edit] / [absorb_format]). *)
let absorb_edit app id range inserted runs =
  Hashtbl.replace app.documents id
    (fold_edit (the_document app id) range inserted runs)

let absorb_format app id range name value =
  Hashtbl.replace app.documents id
    (fold_format (the_document app id) range name value)

(* A stamped copy's edit or format act reaches its ROW's Document field
   (docs/rich-text-plan.md §19): the node is bound to (collection, field)
   by [Tpl.textarea ~document_field], and the occurrence's path names the
   row. A row that is gone has no field to fold into, and that is not a
   fault. *)
let fold_row_document app node keys fold =
  let path = List.map key_to_wire keys in
  let bind = Hashtbl.find_opt app.document_binds node in
  let up = match bind with Some (_, _, level) -> level | None -> 0 in
  (* [level] Fors up is [level] keys shorter: the innermost copy's own
     keys are the trailing ones. *)
  let path = List.filteri (fun i _ -> i < List.length path - up) path in
  match (bind, List.rev path) with
  | Some (cid, field, _), key :: rev_ancestors ->
      let ancestors = List.rev rev_ancestors in
      let entry (k, (variant, values)) =
        if k <> key then (k, (variant, values))
        else
          let doc : Document.t =
            match List.nth_opt values field with
            | Some (Kaya_wire.Str bytes) -> document_of_blob bytes
            | _ -> { text = ""; runs = [] }
          in
          let packed = Kaya_wire.Str (document_blob (fold doc)) in
          ( k,
            ( variant,
              List.mapi (fun i v -> if i = field then packed else v) values ) )
      in
      Hashtbl.replace app.model cid
        (List.map
           (fun i ->
             if i.path <> ancestors then i
             else { i with entries = List.map entry i.entries })
           (instances_of app cid))
  | _ -> ()

(* The folded document of a [rich] textarea; empty until the first edit
   or write. Reads the ambient transaction, as [items] does. *)
let document (Widget id) = the_document (the_tx ()).app id

(* This widget carries attribute runs: [set_document], [apply_edit],
   [~on_edit]. A textarea edits them; a label draws them read-only
   (docs/rich-text-plan.md R8, §15). *)
let set_rich (Widget id) on = emit (the_tx ()) (Kaya_wire.tx_set_rich id on)

(* The app owns this textarea's history (docs/rich-text-plan.md R6, §14):
   the platform's own stack goes off and Edit>Undo reaches the app through
   the role item's activation. *)
let set_own_undo (Widget id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_own_undo id on)

(* Replace a [rich] textarea's whole document: echoes nothing and, like
   [set_text], spends the native undo history (docs/undo-plan.md D7). *)
let set_document (Widget id) (doc : Document.t) =
  let tx = the_tx () in
  Hashtbl.replace tx.app.documents id doc;
  emit tx
    (Kaya_wire.tx_set_rich_text id (List.length doc.runs) (run_values doc.runs)
       (Kaya_wire.Str doc.text))

(* One edit into a [rich] textarea: echoes nothing, never resets undo,
   and is held rather than refused mid-composition (R5). THE MIRROR TAKES
   IT AS IT IS SENT, so the app's document is ahead of the widget's until
   a live composition ends (docs/rich-text-plan.md §7). *)
let apply_edit (Widget id) (e : Edit.t) =
  let tx = the_tx () in
  absorb_edit tx.app id e.range e.inserted e.runs;
  emit tx
    (Kaya_wire.tx_apply_edit id
       (Int64.of_int (fst e.range))
       (Int64.of_int (snd e.range))
       (List.length e.runs) (run_values e.runs) (Kaya_wire.Str e.inserted))

(* Format the widget's CURRENT SELECTION through its own act — what a
   toolbar button sends; the widget answers through [~on_format]. Over a
   collapsed selection the attribute is armed for the next keystroke
   instead. [value] is "true" for a flag, the URL for [link]. *)
let format (Widget id) name value =
  emit (the_tx ())
    (Kaya_wire.tx_format_text id 0 0 0L 0L
       [ Kaya_wire.Str name; Kaya_wire.Str value ])

(* A flag attribute over the selection, on or off. *)
let format_flag w name on = format w name (if on then flag_value else "false")

(* The named acts (docs/rich-text-plan.md §18): [format] with its own name
   over the widget's selection. The app-links route declarator is
   [link_route], since [link] is this act. *)
let bold (Widget id) = format (Widget id) "bold" "true"
let italic (Widget id) = format (Widget id) "italic" "true"
let underline (Widget id) = format (Widget id) "underline" "true"
let strike (Widget id) = format (Widget id) "strike" "true"
let code (Widget id) = format (Widget id) "code" "true"
let link (Widget id) url = format (Widget id) "link" url

(* Take an attribute off the widget's current selection. *)
let unformat (Widget id) name =
  emit (the_tx ())
    (Kaya_wire.tx_format_text id 1 0 0L 0L
       [ Kaya_wire.Str name; Kaya_wire.Str "" ])

(* A ranged act's range in the fold's text: a [block] covers the whole
   paragraphs it touches, as the core snaps it. *)
let ranged_act_bounds app id (start, stop) name =
  if name <> "block" then (start, stop)
  else
    let text = (the_document app id).text in
    let len = String.length text in
    let start = min start len and stop = min stop len in
    let rec back i = if i <= 0 then 0 else if text.[i - 1] = '\n' then i else back (i - 1) in
    let rec forward i = if i >= len then len else if text.[i] = '\n' then i else forward (i + 1) in
    (back start, forward stop)

(* One attribute over a BYTE RANGE of the document, the selection left
   where it is: a document write, echoed by nothing, legal on a rich
   label, and the fold moves here as [apply_edit]'s does
   (docs/rich-text-plan.md §17). A [block] covers the range's whole
   paragraphs, and [block] with "body" takes the kind off. *)
let format_range (Widget id) range name value =
  let tx = the_tx () in
  let start, stop = ranged_act_bounds tx.app id range name in
  let value = if name = "block" && value = "body" then None else Some value in
  absorb_format tx.app id (start, stop) name value;
  emit tx
    (Kaya_wire.tx_format_text id
       (if Option.is_none value then 1 else 0)
       1 (Int64.of_int start) (Int64.of_int stop)
       [ Kaya_wire.Str name; Kaya_wire.Str (Option.value value ~default:"") ])

(* A flag attribute over a byte range, on or off. *)
let format_range_flag w range name on =
  format_range w range name (if on then flag_value else "false")

(* [format_range]'s removal. *)
let unformat_range (Widget id) range name =
  let tx = the_tx () in
  let start, stop = ranged_act_bounds tx.app id range name in
  absorb_format tx.app id (start, stop) name None;
  emit tx
    (Kaya_wire.tx_format_text id 1 1 (Int64.of_int start) (Int64.of_int stop)
       [ Kaya_wire.Str name; Kaya_wire.Str "" ])

(* Make the selection's paragraphs [kind]; [Body] clears. *)
let set_block widget kind = format widget "block" (block_name kind)

(* What an [~own_undo] textarea's app can take back right now, and put
   back: the route reads these (docs/rich-text-plan.md §14), so a write
   re-reads Edit>Undo's and Edit>Redo's enablement. *)
let can_undo (Widget id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_can_undo id on)

let can_redo (Widget id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_can_redo id on)

let add_child (Widget parent) (Widget child) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_child parent child)


let button ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?a11y_hint ?role ?text ?on_click () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_button in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  (* [Destructive] or [Prominent]; a [Heading] or [Caption] button dies
     at the root. *)
  Option.iter (fun r -> set_role w r) role;
  Option.iter (fun t -> set_text w t) text;
  (match on_click with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_handlers id handler
  | None -> ());
  w

(* A multi-line text editor: the entry's uncontrolled contract over
   the platform's real multi-line editor. [~rich:true] adds the
   attribute-run channel (docs/rich-text-plan.md R1); [~on_edit] and
   [~on_format] answer only on one. *)
let textarea ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?placeholder ?placeholder_bind ?on_change ?rich ?own_undo ?on_edit ?on_format () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_textarea in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_placeholder w v) placeholder;
  Option.iter (fun s -> bind_placeholder w s) placeholder_bind;
  Option.iter (fun v -> set_rich w v) rich;
  Option.iter (fun v -> set_own_undo w v) own_undo;
  let (Widget id) = w in
  (match on_change with
  | Some handler -> Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  Option.iter (Hashtbl.replace tx.app.widget_edits id) on_edit;
  Option.iter (Hashtbl.replace tx.app.widget_formats id) on_format;
  w

let label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?role ?rich ?href ?href_bind ?text ?bind () =
  let w = widget Kaya_wire.kind_label in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  (* [Heading] and [Caption] are the label's roles; the two button
     emphases die here. *)
  Option.iter (fun r -> set_role w r) role;
  (* Read-only here: the app writes the runs (docs/rich-text-plan.md R8). *)
  Option.iter (fun v -> set_rich w v) rich;
  Option.iter (fun u -> set_href w u) href;
  Option.iter (fun s -> bind_href w s) href_bind;
  Option.iter (fun t -> set_text w t) text;
  Option.iter (fun s -> bind_text w s) bind;
  w

(* A label wearing [Heading], in one word (the h1 tradition): the
   platform's heading text style AND the trait assistive users skim by,
   and on a grouped screen the section-header seat. *)
let heading ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?text ?bind () =
  label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ~role:Heading ?text ?bind ()

(* The heading's counterpart in one word: the platform's footnote tier
   under the content it explains, and the section-footer seat. *)
let caption ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?text ?bind () =
  label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ~role:Caption ?text ?bind ()

let entry ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?placeholder ?placeholder_bind ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_entry in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_placeholder w v) placeholder;
  Option.iter (fun s -> bind_placeholder w s) placeholder_bind;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

(* A search field: the entry's uncontrolled contract under the platform's
   search chrome (docs/search-plan.md), filtering on every keystroke. The
   clear affordance reaches [~on_change] with "". *)
let search ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?placeholder ?placeholder_bind ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_search in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_placeholder w v) placeholder;
  Option.iter (fun s -> bind_placeholder w s) placeholder_bind;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

(* A progress bar: display-only, like label and image. [~value] is
   the determinate fraction (0..=1); [~indeterminate:true] switches
   to the platform's activity mode. *)
let progress ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?(value = 0.0) ?indeterminate () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_progress in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_value id value);
  Option.iter (fun i -> emit tx (Kaya_wire.tx_set_indeterminate id i)) indeterminate;
  w

(* A slider over min..max at value. Uncontrolled, like the entry: the bar
   owns its position and reports each change to [on_change] (the new value
   as a float). *)
let slider ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?(min = 0.0) ?(max = 1.0) ?(value = 0.0) ?step ?tick_spacing ?bind
    ?on_change ?on_commit () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_slider in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_min id min);
  emit tx (Kaya_wire.tx_set_max id max);
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_step id v)) step;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_tick_spacing id v)) tick_spacing;
  (match (bind : float signal option) with
  | Some s -> emit tx (Kaya_wire.tx_bind_value id s.sig_id)
  | None -> emit tx (Kaya_wire.tx_set_value id value));
  (match on_change with
  | Some handler -> Hashtbl.replace tx.app.widget_values id handler
  | None -> ());
  (match on_commit with
  | Some handler -> Hashtbl.replace tx.app.widget_commits id handler
  | None -> ());
  w

(* A dropdown select over fixed [options] — each option becomes a label
   child (labels only, scene-checked) — at [~selected], the initial
   0-based index (domain-checked at the root). [~on_select] receives each
   USER pick's new index; programmatic writes never echo. *)
let select ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?a11y_hint ?(selected = 0) ?on_select options () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_select in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  List.iter
    (fun option_text ->
      let o = widget Kaya_wire.kind_label in
      set_text o option_text;
      add_child w o)
    options;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_value id (float_of_int selected));
  (match on_select with
  | Some handler ->
      Hashtbl.replace tx.app.widget_values id
        (fun v -> handler (int_of_float v))
  | None -> ());
  w

(* A radio group over fixed [options] — the choice contract
   ([select]) in its inline presentation: same option children, same
   0-based [~selected] index, same [~on_select] pick handler. *)
let radio ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?a11y_hint ?(selected = 0) ?on_select options () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_radio in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  List.iter
    (fun option_text ->
      let o = widget Kaya_wire.kind_label in
      set_text o option_text;
      add_child w o)
    options;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_value id (float_of_int selected));
  (match on_select with
  | Some handler ->
      Hashtbl.replace tx.app.widget_values id
        (fun v -> handler (int_of_float v))
  | None -> ());
  w

let checkbox ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?a11y_hint ?text ?checked ?on_toggle () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_checkbox in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  Option.iter (fun t -> set_text w t) text;
  Option.iter (fun c -> set_checked w c) checked;
  (match on_toggle with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_toggles id handler
  | None -> ());
  w

(* A date picker over civil dates — the compact field that opens the
   platform's calendar (docs/datetime-plan.md). UNCONTROLLED: the control
   owns its value and reports each COMMITTED pick to [~on_change].
   [~value] is a constant, [~bind] a signal; [~min]/[~max] are the
   inclusive range, and a pick past a bound lands on the bound. *)
let date_picker ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind
    ?help ?help_bind ?a11y_hint ?value ?bind ?min ?max ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_date_picker in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  let (Widget id) = w in
  Option.iter
    (fun (d : date) ->
      ignore (pack_date d);
      emit tx (Kaya_wire.tx_set_min_date id d.year d.month d.day))
    min;
  Option.iter
    (fun (d : date) ->
      ignore (pack_date d);
      emit tx (Kaya_wire.tx_set_max_date id d.year d.month d.day))
    max;
  Option.iter
    (fun (d : date) ->
      ignore (pack_date d);
      emit tx (Kaya_wire.tx_set_date id d.year d.month d.day))
    value;
  Option.iter (fun (s : date signal) -> emit tx (Kaya_wire.tx_bind_date id s.sig_id)) bind;
  (match on_change with
  | Some handler ->
      Hashtbl.replace tx.app.widget_dates id (fun packed ->
          handler (date_of_packed packed))
  | None -> ());
  w

(* A time picker over civil times: hours and minutes, no seconds.
   [~step] is the minute granularity (1, 5, 10, 15 or 30) and a pick
   snaps to it. *)
let time_picker ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind
    ?help ?help_bind ?a11y_hint ?value ?bind ?step ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_time_picker in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  let (Widget id) = w in
  Option.iter
    (fun n -> emit tx (Kaya_wire.tx_set_minute_step id (float_of_int n)))
    step;
  Option.iter
    (fun (t : time) ->
      ignore (pack_time t);
      emit tx (Kaya_wire.tx_set_time id t.hour t.minute))
    value;
  Option.iter (fun (s : time signal) -> emit tx (Kaya_wire.tx_bind_time id s.sig_id)) bind;
  (match on_change with
  | Some handler ->
      Hashtbl.replace tx.app.widget_times id (fun packed ->
          handler (time_of_packed packed))
  | None -> ());
  w

(* An image displaying encoded bytes (PNG, JPEG, ...): decode failure
   renders the placeholder, never a crash. [~source] ships the bytes and
   [~source_asset] names the picture instead (the bytes never enter the
   OCaml heap). The two are EXCLUSIVE. *)
let image ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?source ?source_asset ?bind () =
  let w = widget Kaya_wire.kind_image in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  (match (source, source_asset) with
   | Some _, Some _ ->
     invalid_arg
       "kaya: image takes ~source or ~source_asset, never both — there is \
        one source slot on the wire"
   | Some data, None -> set_source w data
   | None, Some a -> set_source_asset w a
   | None, None -> ());
  Option.iter (fun s -> bind_source w s) bind;
  w

(* --- THE CANVAS VOCABULARIES (docs/canvas-plan.md §3.3, §3.4) --------
   The paint ROLE an op names, never RGB: the roles resolve in the core
   per appearance. The numbers stay in the generated wire module. *)
type paint = Series | Series_fill | Grid | Axis | Ground

let paint_wire = function
  | Series -> Int64.of_int Kaya_wire.paint_series
  | Series_fill -> Int64.of_int Kaya_wire.paint_series_fill
  | Grid -> Int64.of_int Kaya_wire.paint_grid
  | Axis -> Int64.of_int Kaya_wire.paint_axis
  | Ground -> Int64.of_int Kaya_wire.paint_ground

(* Which way a fill resolves its own crossings. *)
type fill_rule = Nonzero | Even_odd

let fill_rule_wire = function
  | Nonzero -> Int64.of_int Kaya_wire.fill_rule_nonzero
  | Even_odd -> Int64.of_int Kaya_wire.fill_rule_even_odd


let draw_op d code operands =
  d.d_ops <- List.rev_append (Kaya_wire.I64 (Int64.of_int code) :: operands) d.d_ops

(* Start a subpath at (x, y). *)
let move_to d x y =
  draw_op d Kaya_wire.draw_op_move_to [ Kaya_wire.F64 x; Kaya_wire.F64 y ]

(* Extend the current subpath to (x, y). *)
let line_to d x y =
  draw_op d Kaya_wire.draw_op_line_to [ Kaya_wire.F64 x; Kaya_wire.F64 y ]

(* Close the current subpath. *)
let close d = draw_op d Kaya_wire.draw_op_close []

(* Fill the built path and clear it. *)
let fill d ~paint ?(rule = Nonzero) () =
  draw_op d Kaya_wire.draw_op_fill
    [ Kaya_wire.I64 (paint_wire paint); Kaya_wire.I64 (fill_rule_wire rule) ]

(* One drawing, recorded and framed: keys FIRST, then the op stream —
   TX 46's Values order (docs/canvas-plan.md §3.1). *)
let drawing_record id keys ((vb_w, vb_h) as vb) body =
  let d = { d_viewbox = vb; d_ops = [] } in
  body d;
  let ops = List.rev d.d_ops in
  Kaya_wire.tx_set_drawing id (Kaya_wire.F64 vb_w) (Kaya_wire.F64 vb_h)
    (List.length ops) (List.length keys) (keys @ ops)

(* WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
   (docs/canvas-plan.md §3.2.1). THE SIZE POLICY IS A LIVE-ZONE
   DECLARATION IN THIS SLICE: the LIVE [canvas] can be CALLED inside a
   template body, where [Widget] says nothing about which zone the id
   landed in, so the refusal is [tpl_depth] (docs/deferred.md, the
   template-zone size policy entry). *)
let declare_size_policy tx id policy =
  if tx.app.tpl_depth > 0 then
    failwith
      "kaya: the size policy is a LIVE-ZONE declaration in this slice — a \
       canvas inside a row template keeps `scale` (docs/deferred.md, the \
       template-zone size policy entry)";
  emit tx (Kaya_wire.tx_set_size_policy id policy)

(* A drawing surface. [~viewbox] is the coordinate system the ops are
   written in AND the canvas's natural size in points (§3.2). [~draw]
   declares what it draws at construction; [draw] re-declares it later.
   THE THREE SIZE-POLICY DECLARATIONS RIDE HERE (§3.2.1, ruling 1):
   [~fixed:true] refuses coercion, [~on_draw] and [~on_tick] take the
   assigned size, and REGISTERING IS DECLARING. Writing none is `scale`. *)
let canvas ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ~viewbox ?draw ?(fixed = false)
    ?(on_draw : (draw -> viewbox -> unit) option)
    ?(on_tick : (draw -> viewbox -> float -> unit) option) () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_canvas in
  Option.iter (fun g -> set_grow w g) grow;
  Option.iter (fun v -> set_fill w v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind w;
  let (Widget id) = w in
  (* The viewbox rides the DRAWING on the wire, not a prop; the guest
     side remembers it so a later redraw need not repeat it. *)
  Hashtbl.replace tx.app.canvas_viewboxes id viewbox;
  (* The policy is a PROP and rides ahead of the drawing, as it does in
     the Rust model's chain. *)
  if fixed then declare_size_policy tx id Kaya_wire.size_policy_fixed;
  Option.iter
    (fun f ->
      declare_size_policy tx id Kaya_wire.size_policy_redraw;
      (* Widened to the stored shape at REGISTRATION, never chosen at
         dispatch: see [canvas_draws]. *)
      Hashtbl.replace tx.app.canvas_draws id (fun d size _ -> f d size))
    on_draw;
  Option.iter
    (fun f ->
      declare_size_policy tx id Kaya_wire.size_policy_tick;
      Hashtbl.replace tx.app.canvas_draws id f)
    on_tick;
  Option.iter (fun body -> emit tx (drawing_record id [] viewbox body)) draw;
  w


(* A container from its children. A child is a PARTIALLY APPLIED creator
   — omitting the trailing [()] leaves a [unit -> widget] thunk, so the
   child list literal only allocates closures and the container realizes
   them left to right ([List.iter]'s specified order IS document order).
   Props are labeled optional arguments, the lablgtk idiom. *)
let container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?align ?inset kind children () =
  let parent = widget kind in
  Option.iter (fun g -> set_grow parent g) grow;
  Option.iter (fun v -> set_fill parent v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun a -> set_align parent a) align;
  Option.iter (fun p -> set_inset parent p) inset;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A grid from its children, laid out row-major into [~columns] columns —
   each column takes its NATURAL width, aligned across rows (the thing
   nested rows cannot express). The columns record lands BEFORE the
   add_childs (backends re-flow either way).

   [~columns_when] is a (size class, count) pair laying the grid out in
   that many columns while the window's SIZE CLASS is the named one,
   reverting on leaving it (docs/adaptive-layout-plan.md D6.2). LIVE
   ONLY: [Tpl.grid] carries no such label. *)
let grid ~columns ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?inset ?columns_when ?columns_auto children () =
  let tx = the_tx () in
  let parent = widget Kaya_wire.kind_grid in
  let (Widget id) = parent in
  emit tx (Kaya_wire.tx_set_columns id (float_of_int columns));
  Option.iter
    (fun (Compact, count) ->
      emit tx
        (Kaya_wire.tx_create_breakpoint 0L
           (Kaya_wire.I64 (Int64.of_int Kaya_wire.size_class_compact)) 1
           [
             Kaya_wire.I64 id;
             Kaya_wire.I64 (Int64.of_int Kaya_wire.prop_columns);
             Kaya_wire.F64 (float_of_int count);
           ]))
    columns_when;
  Option.iter (fun m -> set_columns_auto parent m) columns_auto;
  Option.iter (fun g -> set_grow parent g) grow;
  Option.iter (fun v -> set_fill parent v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun p -> set_inset parent p) inset;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A LABELLED ROW (docs/forms-plan.md): [~label] (or [~label_bind]) names
   the one control the children declare, with an optional trailing button
   after it. A column of nothing but these renders as the platform's
   form. The label child is always declared, so the shape the root checks
   holds even when neither argument is passed. *)
let labeled ?label ?label_bind ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?inset children () =
  let parent = widget Kaya_wire.kind_labeled in
  Option.iter (fun g -> set_grow parent g) grow;
  Option.iter (fun v -> set_fill parent v) fill;
  set_a11y ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun p -> set_inset parent p) inset;
  let name = widget Kaya_wire.kind_label in
  Option.iter (fun t -> set_text name t) label;
  Option.iter (fun s -> bind_text name s) label_bind;
  add_child parent name;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A spacer: PURE SUGAR for an empty grown column — it consumes the
   leftover main-axis space between its siblings. *)
let spacer ?(grow = 1.0) () =
  let w = widget Kaya_wire.kind_column in
  set_grow w grow;
  w

let column ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?align ?inset children =
  container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?align ?inset Kaya_wire.kind_column
    children

(* A vertical scroll viewport over EXACTLY ONE child (the signature
   says so; the scene enforces it too). Pass [~grow] so the enclosing
   track CONSTRAINS it — an unconstrained viewport hugs its content
   and nothing overflows. *)
let scroll ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind children =
  container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind Kaya_wire.kind_scroll children

(* [~stack_when] stacks this row's children vertically while the window's
   SIZE CLASS is the named one, reverting on leaving it — a
   core-evaluated breakpoint (docs/adaptive-layout-plan.md D3). LIVE
   ONLY: [Tpl.row] carries no such label, since a breakpoint's setters
   name live widgets and a template row is stamped per entry. *)
let row ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?align ?inset ?stack_when ?wrap children () =
  let parent =
    container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind ?spacing ?align ?inset Kaya_wire.kind_row
      children ()
  in
  Option.iter (fun v -> set_wrap parent v) wrap;
  Option.iter
    (fun Compact ->
      let (Widget id) = parent in
      emit (the_tx ())
        (Kaya_wire.tx_create_breakpoint 0L
           (Kaya_wire.I64 (Int64.of_int Kaya_wire.size_class_compact)) 1
           [
             Kaya_wire.I64 id;
             Kaya_wire.I64 (Int64.of_int Kaya_wire.prop_axis);
             Kaya_wire.I64 (Int64.of_int Kaya_wire.axis_vertical);
           ]))
    stack_when;
  parent

(* An existing widget as a child: [w wid] wraps an already-realized
   handle in an inert thunk, so a widget created earlier slots into a
   child list. *)
let w wid () = wid


let collection () =
  let tx = the_tx () in
  tx.app.c_collection <- Int64.add tx.app.c_collection 1L;
  let id = tx.app.c_collection in
  (* Declared inside a For's template: torn down with its copies, so
     record the edge the model purges along. *)
  (match tx.app.open_fors with
  | parent :: _ ->
      Hashtbl.replace tx.app.children parent
        (Option.value ~default:[] (Hashtbl.find_opt tx.app.children parent) @ [ id ])
  | [] -> ());
  emit tx (Kaya_wire.tx_create_collection id [ [ Kaya_wire.value_str ] ]);
  { cid = id; cpath = [] }

(* The instance of this collection inside the copy keyed by [key] of
   the next enclosing For; chain for deeper nesting. *)
let at c (key : key) = { c with cpath = c.cpath @ [ key_to_wire key ] }

let assert_root c =
  if c.cpath <> [] then
    invalid_arg "kaya: for_each binds the collection itself, not an instance — drop the at"

let insert c (k : key) (value : string) =
  let tx = the_tx () in
  let key = key_to_wire k in
  (* ABSORPTION, the one path every explicit key travels: a numeric key
     at or above the minter's counter carries it up ([insert_fresh]). *)
  absorb_key tx.app c.cid c.cpath key;
  model_set tx c.cid c.cpath key 0 [ Kaya_wire.Str value ];
  emit tx (Kaya_wire.tx_collection_insert c.cid c.cpath key 0 [ Kaya_wire.Str value ]);
  recompute_derived tx c.cid c.cpath

(* Insert a value under a key the binding authors, and hand the key back.
   ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key is
   [I64] and is counter+1. MIXING IS SAFE BY ABSORPTION, and NO DECREMENT
   IS EXPRESSIBLE — a history walk never moves the counter, and an
   abandoned transaction does not move it back either. *)
let insert_fresh c (value : string) =
  let tx = the_tx () in
  let key = mint_key tx.app c.cid c.cpath in
  insert c (Key.Int key) value;
  key

let update c (k : key) (value : string) =
  let tx = the_tx () in
  let key = key_to_wire k in
  model_set tx c.cid c.cpath key 0 [ Kaya_wire.Str value ];
  emit tx (Kaya_wire.tx_collection_update c.cid c.cpath key 0 [ Kaya_wire.Str value ]);
  recompute_derived tx c.cid c.cpath

let remove c (k : key) =
  let tx = the_tx () in
  let key = key_to_wire k in
  model_remove tx c.cid c.cpath key;
  emit tx (Kaya_wire.tx_collection_remove c.cid c.cpath key);
  recompute_derived tx c.cid c.cpath

let entry_keys tx cid path =
  match List.find_opt (fun i -> i.path = path) (instances_of tx.app cid) with
  | Some i -> List.map fst i.entries
  | None -> []

(* The raw, wire-keyed mover every typed move below wraps — kept
   internal so the membership checks below stay in one representation. *)
let move_entry c key before =
  let tx = the_tx () in
  let keys = entry_keys tx c.cid c.cpath in
  if not (List.mem key keys) then invalid_arg "kaya: move of missing key";
  (match before with
  | Some anchor when not (List.mem anchor keys) ->
      invalid_arg "kaya: move before missing key"
  | _ -> ());
  if before = Some key then ()
  else begin
    model_move tx c.cid c.cpath key before;
    emit tx (Kaya_wire.tx_collection_move c.cid c.cpath key (Option.to_list before));
    recompute_derived tx c.cid c.cpath
  end

(* Reposition an entry before another's. *)
let move_before c (key : key) (anchor : key) =
  move_entry c (key_to_wire key) (Some (key_to_wire anchor))

(* Reposition an entry at the end of its collection. *)
let move_to_end c (key : key) = move_entry c (key_to_wire key) None

(* Reposition an entry at the front. *)
let move_to_front c (key : key) =
  let tx = the_tx () in
  match entry_keys tx c.cid c.cpath with
  | [] -> invalid_arg "kaya: move of missing key"
  | first :: _ -> move_entry c (key_to_wire key) (Some first)

(* Reposition an entry directly after another's. *)
let move_after c (key : key) (anchor : key) =
  let tx = the_tx () in
  let key = key_to_wire key in
  let anchor = key_to_wire anchor in
  let keys = entry_keys tx c.cid c.cpath in
  if not (List.mem key keys) then invalid_arg "kaya: move of missing key";
  if not (List.mem anchor keys) then invalid_arg "kaya: move after missing key";
  if key = anchor then ()
  else begin
    let rec succ_of = function
      | a :: b :: _ when a = anchor -> Some b
      | _ :: rest -> succ_of rest
      | [] -> None
    in
    match succ_of keys with
    | Some s when s = key -> () (* already directly after the anchor *)
    | Some s -> move_entry c key (Some s)
    | None -> move_entry c key None
  end

(* The model: what this guest wrote, exactly — the fold of every patch
   so far (this transaction's included), in insertion order. *)
let items c : (key * string) list =
  let tx = the_tx () in
  guard_mirror_read ();
  match List.find_opt (fun i -> i.path = c.cpath) (instances_of tx.app c.cid) with
  | Some i ->
      List.map
        (fun (k, (_, vs)) ->
          ( key_of_wire k,
            match List.hd vs with
            | Kaya_wire.Str s -> s
            | _ -> invalid_arg "kaya: a scalar collection's element is a string" ))
        i.entries
  | None -> []

(* count reads through items, so the mirror-read guard fires there. *)
let count c = List.length (items c)

(* Records: a first-class descriptor is the schema — the honest floor a
   future ppx deriver ([@@deriving kaya_gen]) will generate. *)
type 'a record_type = {
  rt_schema : int list;
  rt_to_values : 'a -> Kaya_wire.value list;
  rt_of_values : Kaya_wire.value list -> 'a;
}

(* A typed projection: one field of a record type, by wire position. *)
type ('a, 'v) field = {
  fd_index : int;
  fd_to_value : 'v -> Kaya_wire.value;
}

let str_field index : ('a, string) field =
  { fd_index = index; fd_to_value = (fun s -> Kaya_wire.Str s) }

(* THE WHOLE ELEMENT OF A SCALAR COLLECTION, as a field token. *)
let element : ('a, string) field = str_field 0

let bool_field index : ('a, bool) field =
  { fd_index = index; fd_to_value = (fun b -> Kaya_wire.Bool b) }

let i64_field index : ('a, int64) field =
  { fd_index = index; fd_to_value = (fun n -> Kaya_wire.I64 n) }

let f64_field index : ('a, float) field =
  { fd_index = index; fd_to_value = (fun x -> Kaya_wire.F64 x) }

(* A Date field: a [date] in the app, an I64 in packed decimal on the
   wire (docs/datetime-plan.md D10). The phantom is what keeps a picker
   off the int64 field it shares a tag with. *)
let date_field index : ('a, date) field =
  { fd_index = index; fd_to_value = (fun d -> Kaya_wire.I64 (pack_date d)) }

let time_field index : ('a, time) field =
  { fd_index = index; fd_to_value = (fun t -> Kaya_wire.I64 (pack_time t)) }

(* A blob field's MODEL value carries the guest's own bytes (a binary
   Str), so record_items reads back exactly what was written. *)
let blob_field index : ('a, bytes) field =
  { fd_index = index; fd_to_value = (fun d -> Kaya_wire.Str (Bytes.to_string d)) }

(* A [document] field: a Blob slot whose bytes are the document's own
   wire list, so a stamped copy's document binds through the template
   zone as a string field does (docs/rich-text-plan.md §19). *)
let document_field index : ('a, document) field =
  { fd_index = index; fd_to_value = (fun d -> Kaya_wire.Str (document_blob d)) }

(* The model-to-wire crossing for one record field: a blob field's model
   value registers a fresh copy with the core here — handles are
   single-submit, so insert, update and update_field each re-register. *)
let encode_field tag v =
  if tag = Kaya_wire.value_blob then
    match v with
    | Kaya_wire.Str s ->
        Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string s))
    | _ -> invalid_arg "kaya: blob field out of shape"
  else v

let encode_fields schema fields = List.map2 encode_field schema fields

type 'a record_collection = {
  rc_handle : collection;
  rc_type : 'a record_type;
}

(* The plain handle, for for_each. *)
let record_handle rc = rc.rc_handle

(* The instance of this record collection inside the copy keyed by [key].
   THE TYPED TWIN OF [at]: [at (record_handle rc) key] loses ['a] and
   every record mutation below takes ['a record_collection]
   (docs/deferred.md, the nested-record-collection gap). *)
let record_at rc key = { rc with rc_handle = at rc.rc_handle key }

(* Declare a collection of records; the descriptor is the schema. *)
let collection_of rt =
  let tx = the_tx () in
  tx.app.c_collection <- Int64.add tx.app.c_collection 1L;
  let id = tx.app.c_collection in
  (match tx.app.open_fors with
  | parent :: _ ->
      Hashtbl.replace tx.app.children parent
        (Option.value ~default:[] (Hashtbl.find_opt tx.app.children parent) @ [ id ])
  | [] -> ());
  emit tx (Kaya_wire.tx_create_collection id [ rt.rt_schema ]);
  { rc_handle = { cid = id; cpath = [] }; rc_type = rt }

let insert_record rc (k : key) value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let fields = rc.rc_type.rt_to_values value in
  (* ABSORPTION, on the one path every explicit key of a record
     collection travels — see [insert_fresh]. *)
  absorb_key tx.app rc.rc_handle.cid rc.rc_handle.cpath key;
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 fields;
  emit tx
    (Kaya_wire.tx_collection_insert rc.rc_handle.cid rc.rc_handle.cpath key 0
       (encode_fields rc.rc_type.rt_schema fields));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* [insert_fresh] for a record collection: the binding authors the key and
   hands it back. *)
let insert_record_fresh rc value =
  let tx = the_tx () in
  let key = mint_key tx.app rc.rc_handle.cid rc.rc_handle.cpath in
  insert_record rc (Key.Int key) value;
  key

let update_record rc (k : key) value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 fields;
  emit tx
    (Kaya_wire.tx_collection_update rc.rc_handle.cid rc.rc_handle.cpath key 0
       (encode_fields rc.rc_type.rt_schema fields));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* One field's delta: the rest of the record never travels; the
   model's copy updates the same slot. *)
let update_field rc (k : key) fd value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let mv = fd.fd_to_value value in
  let current =
    match
      List.find_opt
        (fun i -> i.path = rc.rc_handle.cpath)
        (instances_of tx.app rc.rc_handle.cid)
    with
    | Some i -> (
        match List.assoc_opt key i.entries with
        | Some (_, vs) -> vs
        | None -> invalid_arg "kaya: update of missing key")
    | None -> invalid_arg "kaya: update of missing instance"
  in
  let updated = List.mapi (fun i v -> if i = fd.fd_index then mv else v) current in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 updated;
  emit tx
    (Kaya_wire.tx_collection_update_field rc.rc_handle.cid rc.rc_handle.cpath key
       fd.fd_index 0
       (encode_field (List.nth rc.rc_type.rt_schema fd.fd_index) mv));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* The typed model: what this guest wrote, in insertion order. *)
let record_items rc : (key * 'a) list =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt (fun i -> i.path = rc.rc_handle.cpath) (instances_of tx.app rc.rc_handle.cid)
  with
  | Some i ->
      List.map (fun (k, (_, vs)) -> (key_of_wire k, rc.rc_type.rt_of_values vs)) i.entries
  | None -> []

(* One row by its key — the [get]/[find_opt] shape over a record
   collection, so a guest stops hand-rolling [List.assoc_opt] over
   [record_items]. *)
let record_get rc (k : key) =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt (fun i -> i.path = rc.rc_handle.cpath) (instances_of tx.app rc.rc_handle.cid)
  with
  | Some i ->
      Option.map
        (fun (_, vs) -> rc.rc_type.rt_of_values vs)
        (List.assoc_opt (key_to_wire k) i.entries)
  | None -> None

(* A signal recomputed from this collection's entries after every
   mutation, written into the same transaction — the items-left label
   with no handler remembering to update it. [mk] is one of the typed
   signal constructors ([signal_str] and so on), so the derived signal's
   type is the type [compute] answers. *)
let derive witness rc compute =
  let tx = the_tx () in
  let s = signal witness (compute (record_items rc)) in
  tx.pending_derived <-
    (rc.rc_handle.cid, fun () -> write s (compute (record_items rc)))
    :: tx.pending_derived;
  s

(* REQUEST this app's brand accent (docs/styling-plan.md D1/D2): one sRGB
   hex is the whole call and the core derives the rest. THE APP NEVER
   WRITES A FOREGROUND. [~light] and [~dark] are the per-appearance form;
   whatever they leave unstated comes from the seed. SET ONCE, BEFORE THE
   FIRST MOUNT: the root refuses a second write and a late one. *)
let brand_accent ?light ?dark seed =
  let mask =
    (match light with Some _ -> 1 | None -> 0)
    lor match dark with Some _ -> 2 | None -> 0
  in
  emit (the_tx ())
    (Kaya_wire.tx_set_brand_accent seed mask
       (Option.value light ~default:0)
       (Option.value dark ~default:0))

(* REQUEST this app's brand typeface (docs/styling-plan.md Slice 2b): one
   family name is the whole call. THE FAMILY, NEVER THE SCALE.
   [~platforms] rows TRAVEL UNRESOLVED; [~font] and [~font_asset] are the
   one font slot and are EXCLUSIVE. SET ONCE, BEFORE THE FIRST MOUNT. A
   FAMILY A PLATFORM DOES NOT HAVE leaves that platform's own typeface in
   place, deliberately and silently. *)
let brand_typeface ?(platforms = []) ?font ?font_asset family =
  let pairs =
    (* The filters' encoding one tier over: a FLAT list read in twos,
       an I64 platform tag then that platform's family. *)
    List.concat_map
      (fun (p, f) -> [ Kaya_wire.I64 (platform_wire p); Kaya_wire.Str f ])
      platforms
  in
  let slot =
    match (font, font_asset) with
    | Some _, Some _ ->
      invalid_arg
        "kaya: brand_typeface takes ~font or ~font_asset, never both — there \
         is one font slot on the wire"
    | Some bytes, None -> Some (Kaya_wire.Blob (Kaya_runtime.register_blob bytes))
    | None, Some a -> Some (Kaya_wire.Blob (Kaya_runtime.asset_blob a))
    | None, None -> None
  in
  emit (the_tx ())
    (Kaya_wire.tx_set_brand_typeface
       (match slot with Some _ -> 1 | None -> 0)
       (Kaya_wire.Str family) pairs
       (* THE FONT SLOT IS ALWAYS WRITTEN and the mask says whether it
          means anything, so the record's field count never varies. *)
       (Option.value slot ~default:(Kaya_wire.Str "")))

(* DECLARE this app's identity (docs/app-identity-plan.md,
   docs/tasks-s3-plan.md N4). NO ARGUMENTS: the name it goes by, the
   picture that stands for it and the reverse-DNS id it registers under
   are the asset root's own identity.toml, which the BUILD already reads,
   and the core reads the same file. SET ONCE, BEFORE THE FIRST MOUNT.

   STILL AN EXPLICIT CALL, because declaring an identity is a POLICY: a
   declared app is a Dock app on macOS (ruling 1), so an app that wants
   the platform's own identity declares none at all. *)
let app_identity () =
  (* THE SLOTS RIDE EMPTY and the root fills them from the asset root's own
     identity.toml: mask 0, no name, no blob. The record's shape is fixed, so
     the icon slot is written either way, as an empty Str. *)
  emit (the_tx ())
    (Kaya_wire.tx_set_app_identity 0 (Kaya_wire.Str "") (Kaya_wire.Str ""))

(* The window's ADVISORY sections hint (docs/multicolumn-plan.md): the
   width/height decide the actual presentation, this only nudges it. *)
module Sections_presentation = struct
  type t = Auto | Bar | Sidebar

  let wire = function
    | Auto -> Int64.of_int Kaya_wire.sections_presentation_auto
    | Bar -> Int64.of_int Kaya_wire.sections_presentation_bar
    | Sidebar -> Int64.of_int Kaya_wire.sections_presentation_sidebar
end

(* Set a window's attributes in one construct — the attribute set is
   EXACTLY [create_window]'s; the primary differs only in having no
   creation moment, since the process owns it. *)
let window ?title ?width ?height ?inset ?veto_close ?dirty ?remember_frame
    ?panes
    ?(sections_presentation : Sections_presentation.t option)
    ?(appearance : Appearance.t option)
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus ?(id = 0L) () =
  let tx = the_tx () in
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_window_title id t)) title;
  Option.iter (fun w -> emit tx (Kaya_wire.tx_set_window_width id w)) width;
  Option.iter (fun h -> emit tx (Kaya_wire.tx_set_window_height id h)) height;
  (* [~inset] is LAYOUT, not appearance (docs/styling-plan.md D3), which
     is why it rides here beside the size. *)
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_inset id v)) inset;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_veto_close id v)) veto_close;
  (* [~dirty] declares that this surface holds unsaved work; each backend
     spells its own platform's affordance (docs/dirty-plan.md D2/D4). THE
     TITLE STRING IS NEVER TOUCHED (D1). *)
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_dirty id v)) dirty;
  (* [~remember_frame] is the OPT-OUT from window memory
     (docs/tasks-s4-plan.md P4); inert on the phones. *)
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_window_remember_frame id v))
    remember_frame;
  (* [~panes] is the CEILING on how many of this window's stack entries
     present side by side: 1 is the serial stack, 2 and 3 are columns on
     a window wide enough, the shallowest shed first as it narrows
     (docs/multicolumn-plan.md). The root refuses 0 and anything above 3. *)
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_window_panes id (Int64.of_int v)))
    panes;
  Option.iter
    (fun p ->
      emit tx (Kaya_wire.tx_set_window_sections_presentation id (Sections_presentation.wire p)))
    sections_presentation;
  (* [~appearance] is the app's OWN light/dark choice, applied
     process-wide from the default window (docs/tasks-s2b-plan.md
     R1-R3): [Kaya_wire.appearance_system] defers to the harness knob
     and then the OS, [_light] and [_dark] win over both. *)
  Option.iter
    (fun a -> emit tx (Kaya_wire.tx_set_window_appearance id (Appearance.wire a)))
    appearance;
  (* The handlers ride the declaration: [~on_close_requested] fires per
     chrome close while veto_close is armed (answer with [destroy_window]
     to agree); [~on_closed] fires when the non-veto auxiliary is
     chrome-closed and retires with it. *)
  Option.iter
    (fun f -> Hashtbl.replace tx.app.close_requested id f)
    on_close_requested;
  Option.iter (fun f -> Hashtbl.replace tx.app.window_closed id f) on_closed;
  (* The history handlers ride the window construct — a ledger is per
     window — and are NOT one-shot. [~on_undone] hears every undo kaya
     ROUTED; an affordance kaya does not intercept moves the field's own
     stack and says nothing (docs/undo-plan.md A6). *)
  Option.iter (fun f -> Hashtbl.replace tx.app.undone_handlers id f) on_undone;
  Option.iter (fun f -> Hashtbl.replace tx.app.redone_handlers id f) on_redone;
  (* The menubar rides the window construct: [~menus] realizes its thunks
     left to right and appends each top-level grouping node to this
     window's command catalog. *)
  Option.iter
    (List.iter (fun th ->
         let (MenuItem m) = th () in
         emit tx (Kaya_wire.tx_menubar_append id m)))
    menus

(* Create an auxiliary window (capability-gated: phone hosts reject at the
   root); materializes hidden, [mount_in] presents. *)
let create_window ?title ?width ?height ?inset ?veto_close ?dirty
    ?remember_frame ?panes
    ?sections_presentation ?appearance
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_create_window id);
  window ?title ?width ?height ?inset ?veto_close ?dirty ?remember_frame
    ?panes
    ?sections_presentation ?appearance
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus ~id ()

(* Close and forget an auxiliary window — also the veto grammar's
   confirmation and the reconciliation after a chrome close. *)
let destroy_window id = emit (the_tx ()) (Kaya_wire.tx_destroy_window id)

(* Mount a root into a specific window; mounting presents. *)
let mount_in window (Widget root) = emit (the_tx ()) (Kaya_wire.tx_mount window root)

(* Push a navigation entry onto the primary surface's stack (entry ids are
   guest-allocated in the shared surface namespace, the [create_window]
   discipline); materializes covered, [mount_in] presents it. *)
let push_entry ?(window = 0L) ?title ?intercept_back ?on_popped
    ?on_back_requested id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_push_entry window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_entry_title id t)) title;
  Option.iter
    (fun i -> emit tx (Kaya_wire.tx_set_entry_intercept_back id i))
    intercept_back;
  Option.iter (fun f -> Hashtbl.replace tx.app.entry_popped id f) on_popped;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.back_requested id f)
    on_back_requested

(* Append a section to the window's section set; the set is append-only —
   sections have no destruction grammar, and every section's root is
   retained while covered (switching is SELECTION, not lifecycle).
   [~on_selected] fires each time the USER switches to it — NOT one-shot;
   a programmatic [select_section] does not fire it (the echo doctrine). *)
let add_section ?(window = 0L) ?title ?symbol ?badge ?badge_bind ?on_selected id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_section window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_section_title id t)) title;
  Option.iter
    (fun s -> emit tx (Kaya_wire.tx_set_section_symbol id (symbol_wire s)))
    symbol;
  (* The COUNT on the switcher item (docs/tasks-s2-plan.md T2); zero
     clears. *)
  Option.iter (fun c -> emit tx (Kaya_wire.tx_set_section_badge id c)) badge;
  Option.iter
    (fun (s : float signal) -> emit tx (Kaya_wire.tx_bind_section_badge id s.sig_id))
    badge_bind;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.section_selected id f)
    on_selected

(* Select a section programmatically: configuration, never echoes
   [~on_selected] (the echo doctrine). *)
let select_section ?(window = 0L) id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_select_section window id)

(* Pop the window's top navigation entry and forget its tree — also the
   back-veto grammar's confirmation after [on_back_requested]. *)
let pop_entry ?(window = 0L) () = emit (the_tx ()) (Kaya_wire.tx_pop_entry window)

(* Request a sheet over [~parent] — a window (0, the primary) or a LIVE
   SHEET, the chain (docs/sheet-plan.md): a modal hosting a root,
   [mount_in] presents it. [~on_dismissed] fires when the user's cancel
   path closes it natively (a programmatic [dismiss_sheet] does not) and
   retires with the one dismissal; [~on_dismiss_requested] fires per
   cancel while [~intercept_dismiss] is armed, nothing has gone. *)
let present_sheet ?(parent = 0L) ?title ?intercept_dismiss ?detent
    ?on_dismissed ?on_dismiss_requested id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_present_sheet parent id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_sheet_title id t)) title;
  Option.iter
    (fun i -> emit tx (Kaya_wire.tx_set_sheet_intercept_dismiss id i))
    intercept_dismiss;
  Option.iter
    (fun d -> emit tx (Kaya_wire.tx_set_sheet_detent id (Detent.wire d)))
    detent;
  Option.iter (fun f -> Hashtbl.replace tx.app.sheet_dismissed id f) on_dismissed;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.dismiss_requested id f)
    on_dismiss_requested

(* Dismiss a live sheet and forget its tree, child sheets with it — also
   the dismiss-veto grammar's confirmation after [on_dismiss_requested]. *)
let dismiss_sheet id = emit (the_tx ()) (Kaya_wire.tx_dismiss_sheet id)

(* Request a modal alert (the request/result grammar). The result handler
   rides the REQUEST and retires with its one answer — choice is an
   action index (0 or 1) or [alert_cancel], every platform-native
   dismissal. *)
(* A dialog is a QUESTION: [show_alert ~title ~cancel ()] shows the alert
   when handed its continuation, the callback the binding runs on the app
   thread in its own transaction, so [let*] chains questions with no
   runtime behind it (docs/async-dialogs-plan.md §3). *)
type 'a ask = ('a -> unit) -> unit

let ( let* ) (ask : 'a ask) k = ask k

let show_alert ?(window = 0L) ?(title = "") ?(message = "")
    ?(actions = []) ~cancel () k =
  let tx = the_tx () in
  if List.length actions > 2 then
    invalid_arg "kaya: an alert carries at most 2 actions (the platform floor)";
  if cancel = "" then
    invalid_arg "kaya: the cancel slot always exists and needs a name";
  let app = tx.app in
  app.next_alert <- Int64.add app.next_alert 1L;
  let id = app.next_alert in
  Hashtbl.replace app.alert_handlers id k;
  let nth i = match List.nth_opt actions i with Some a -> a | None -> "" in
  emit tx
    (Kaya_wire.tx_show_alert window id (List.length actions)
       (Kaya_wire.Str title) (Kaya_wire.Str message)
       (Kaya_wire.Str (nth 0)) (Kaya_wire.Str (nth 1))
       (Kaya_wire.Str cancel))


(* Post a local notification with a GUEST-CHOSEN id
   (docs/tasks-s3-plan.md N1, N2): the alert's grammar without a window
   — the platform shows it outside the app. [~on_result] fires exactly
   once and retires, with [notification_activated] when the user opened
   it and [notification_refused] when the platform would not post it.
   [~at] is a UNIX time in seconds handed to the OS scheduler where one
   exists; 0 posts now. Many may be live at once. *)
let show_notification ?(title = "") ?(body = "") ?(at = 0L) ?on_result
    notification =
  let tx = the_tx () in
  if title = "" then
    invalid_arg "kaya: a notification needs a title — pass ~title";
  Option.iter
    (fun f -> Hashtbl.replace tx.app.notification_handlers notification f)
    on_result;
  emit tx
    (Kaya_wire.tx_show_notification notification at (Kaya_wire.Str title)
       (Kaya_wire.Str body));
  notification

(* Withdraw a pending or delivered notification (a reminder that was
   cleared). No answer follows; an unknown id is ignored. *)
let cancel_notification notification =
  emit (the_tx ()) (Kaya_wire.tx_cancel_notification notification)

(* Register the PROCESS-LEVEL notification handler
   (docs/tasks-s9-plan.md R1): [~f notification outcome] receives every
   result whose id has no one-shot handler bound at the show — which is
   the whole of a process the platform RELAUNCHED for a tap, since it
   never called [show_notification]. It does not retire, and a one-shot
   handler for the same id still wins. Needs no transaction. *)
(* The notification_result decision, in a function of its own because
   the ring loop's branch has no seam a test can reach (the ring is C
   memory) — Go's [notification_result] for the same reason, and
   bindings/ocaml/checks/notify_order_check.ml drives the three cases
   through here. THE ORDER IS THE SEMANTICS (docs/tasks-s9-plan.md R1)
   and tools/check-sugar-surface.py reads it out of this body: the
   one-shot handler bound at the show first, retiring with the result;
   else the process-level one, which does not; else the drop is
   announced. *)
let notification_result app id outcome =
  match
    ( Hashtbl.find_opt app.notification_handlers id,
      app.notification_activation )
  with
  | Some handler, _ ->
      Hashtbl.remove app.notification_handlers id;
      dispatch app (fun () -> handler outcome)
  | None, Some f -> dispatch app (fun () -> f id outcome)
  | None, None ->
      prerr_endline
        (Printf.sprintf
           "kaya: notification %Ld outcome %s reached no handler — none was \
            bound at the show and no process-level handler is registered \
            (Kaya_app.on_notification_activation)"
           id
           (Notification_outcome.name outcome))

let on_notification_activation app ~f = app.notification_activation <- Some f

(* Declare a link ROUTE and the handler that answers it
   (docs/app-links-plan.md §4): [link app ~pattern:"task/{key}" ~f]
   matches [<scheme>://task/t1] and calls [f [ ("key", "t1") ]].
   Segments split on ['/'], [{name}] captures one segment, a literal
   segment matches itself; the query's pairs join the params and a
   capture wins a name clash. THE PARAMS ARE AN ASSOCIATION LIST, the
   shape OCaml already reads a query string into.

   PROCESS-LEVEL, [on_notification_activation]'s shape: it does not
   retire and it needs no transaction — declared before the first one the
   record waits and rides the head of it, declared inside a handler it
   rides that handler's. A URL that arrives before the app thread exists
   is delivered first, and one no route matched is announced by the core
   and reaches nothing here.

   NOTHING HERE READS THE PATTERN. The core is the one parser and the one
   author of every refusal — an empty pattern, an empty segment, a
   malformed one, a duplicate — and it faults at apply with the whole
   sentence, where every other declaration refusal in kaya lands
   (tools/check-sugar-surface.py refuses a reason spelled here). *)
let link_route app ~pattern ~f =
  let route = Int64.add app.next_link_route 1L in
  app.next_link_route <- route;
  Hashtbl.replace app.link_handlers route f;
  app.pending_routes <-
    app.pending_routes
    @ [ Kaya_wire.tx_declare_link_route route (Kaya_wire.Str pattern) ]

(* The link_opened decision, in a function of its own because the ring
   loop's branch has no seam a test can reach (the ring is C memory) —
   [notification_result] for the same reason, and
   bindings/ocaml/checks/notify_order_check.ml drives the cases through
   here. TWO DROPS WITH DISJOINT CAUSES (docs/app-links-plan.md §4):
   route 0 is a URL NO ROUTE TOOK, which the core announced naming every
   declared pattern, so it is silent here; a route that matched and
   reached no handler is this binding's to announce, naming its own
   registrar. *)
let link_opened app route url params =
  match Hashtbl.find_opt app.link_handlers route with
  | Some handler -> dispatch app (fun () -> handler params)
  | None ->
      if route <> 0L then
        prerr_endline
          (Printf.sprintf
             "kaya: link %s matched route %Ld and reached no handler — \
              none is registered for it (Kaya_app.link_route)"
             url route)

(* The filters encoding, written ONCE because two requests carry it:
   alternating label and space-separated extensions. *)
let filter_values filters =
  List.concat_map
    (fun (label, exts) -> [ Kaya_wire.Str label; Kaya_wire.Str exts ])
    filters

(* Both dialogs draw their id from ONE counter, because the platforms
   allow ONE live dialog per process whichever kind it is: a save
   request that numbered itself separately could collide with a picker's
   id in the result table. *)
let next_dialog app =
  app.next_file_dialog <- Int64.add app.next_file_dialog 1L;
  app.next_file_dialog

let pick ?(window = 0L) ?(filters = []) ~multiple () k =
  let tx = the_tx () in
  let app = tx.app in
  let id = next_dialog app in
  Hashtbl.replace app.file_dialog_handlers id k;
  emit tx
    (Kaya_wire.tx_show_file_dialog window id
       (if multiple then 1 else 0)
       (filter_values filters))

(* Ask the platform for files. THE PICK, NOT THE OPEN — the result
   carries handles you redeem later (DESIGN.md, File dialogs). [filters]
   is (label, space-separated extensions), ADVISORY everywhere.
   The continuation fires exactly once; CANCEL IS THE EMPTY LIST. *)
let pick_files ?(window = 0L) ?(filters = []) () k =
  pick ~window ~filters ~multiple:true () k

(* The single-file spelling. The floor always returns a LIST; this only
   asks the platform for one, so the handler receives zero or one. *)
let pick_file ?(window = 0L) ?(filters = []) () k =
  pick ~window ~filters ~multiple:false () k

(* Ask the platform WHERE TO SAVE — the picker's twin on the same grammar
   and out of the same one-live-dialog slot (docs/save-plan.md D2).
   [suggested_name] is the name the dialog OPENS with; every platform
   TAKES it and none guarantees it, so read the name you GOT (on macOS
   NSSavePanel appends the first allowed extension — docs/deferred.md).
   CANCEL IS [None], and WHAT YOU GET BACK OPENS EMPTY (D1). *)
let save_file ?(window = 0L) ?(filters = []) suggested_name k =
  let tx = the_tx () in
  let app = tx.app in
  let id = next_dialog app in
  Hashtbl.replace app.file_dialog_handlers id (fun files ->
      k (match files with [] -> None | destination :: _ -> Some destination));
  emit tx
    (Kaya_wire.tx_show_save_dialog window id
       (Kaya_wire.Str suggested_name)
       (filter_values filters))

(* --- The clipboard (DESIGN.md, Clipboard) --------------------------- *)

(* Join an accept list: the closed kinds by name plus any custom ids,
   space separated. Ids reach every platform's registry verbatim, so they
   carry NO SPACES — which is what makes the join unambiguous, and what
   this refuses to let you break. *)
let accept_list kinds =
  List.iter
    (fun kind ->
      if kind = "" || String.contains kind ' ' then
        invalid_arg
          (Printf.sprintf
             "kaya: %S is not an accept-list entry — the closed kinds are \
              \"text\", \"html\", \"image\" and \"files\", and a custom format \
              id reaches the platform's own registry verbatim, so it carries \
              no spaces"
             kind))
    kinds;
  String.concat " " kinds

(* Put ONE clip on the system clipboard, offered in as many
   representations as the call fills in. *)
let copy ?text ?html ?image ?(files = []) ?(custom = []) () =
  let tx = the_tx () in
  let present = ref 0 in
  let values = ref [] in
  let add v = values := v :: !values in
  List.iter
    (fun (id, bytes) ->
      ignore (accept_list [ id ]);
      add (Kaya_wire.Str id);
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    custom;
  List.iter (fun (f : picked_file) -> add (Kaya_wire.I64 f.handle)) files;
  Option.iter
    (fun bytes ->
      present := !present lor Kaya_wire.clip_image;
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    image;
  Option.iter
    (fun html ->
      present := !present lor Kaya_wire.clip_html;
      add (Kaya_wire.Str html))
    html;
  Option.iter
    (fun text ->
      present := !present lor Kaya_wire.clip_text;
      add (Kaya_wire.Str text))
    text;
  emit tx
    (Kaya_wire.tx_copy !present (List.length files) (List.length custom)
       (List.rev !values))

(* Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE. The
   platforms have deliberately made it expensive (DESIGN.md, and
   docs/clipboard-plan.md): reach for it to detect a URL or import, never to
   implement Paste — that is the Paste command, and it is free. *)
let read_clipboard accepting k =
  let tx = the_tx () in
  let app = tx.app in
  app.next_clipboard_read <- Int64.add app.next_clipboard_read 1L;
  let id = app.next_clipboard_read in
  Hashtbl.replace app.clipboard_handlers id k;
  emit tx (Kaya_wire.tx_read_clipboard id (Kaya_wire.Str (accept_list accepting)))

(* Declare what a widget takes from a paste — the closed kinds by name
   plus any custom format ids. It drives whether Paste is live while this
   widget is focused, filters what reaches the paste hook, and on Android
   IS the native registration. A widget that declares NOTHING gets the
   platform's own insertion. *)
let set_accepts (Widget id) kinds =
  emit (the_tx ()) (Kaya_wire.tx_set_accepts id (accept_list kinds))

(* The drag_op mask a guest's operations name; the empty list withdraws
   the declaration. *)
let operation_mask ops =
  List.fold_left
    (fun mask op ->
      mask
      lor
      match op with
      | Op.Copy -> Kaya_wire.drag_op_copy
      | Op.Move -> Kaya_wire.drag_op_move)
    0 ops

(* The drag_op word, or None for a cancelled or refused drag. *)
let operation_of mask =
  if mask = Kaya_wire.drag_op_copy then Some Op.Copy
  else if mask = Kaya_wire.drag_op_move then Some Op.Move
  else None

(* DECLARE what a widget hands over when dragged: a clip in [copy]'s own
   shapes plus the operations it allows (docs/dnd-plan.md D1). An EMPTY
   clip withdraws the declaration, which is how a same-app move removes
   its source (D2). *)
let draggable ?text ?html ?image ?(files = []) ?(custom = [])
    ?(operations = [ Op.Copy ]) (Widget id) () =
  let tx = the_tx () in
  let present = ref 0 in
  let values = ref [] in
  let add v = values := v :: !values in
  List.iter
    (fun (cid, bytes) ->
      ignore (accept_list [ cid ]);
      add (Kaya_wire.Str cid);
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    custom;
  List.iter (fun (f : picked_file) -> add (Kaya_wire.I64 f.handle)) files;
  Option.iter
    (fun bytes ->
      present := !present lor Kaya_wire.clip_image;
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    image;
  Option.iter
    (fun html -> present := !present lor Kaya_wire.clip_html; add (Kaya_wire.Str html))
    html;
  Option.iter
    (fun text -> present := !present lor Kaya_wire.clip_text; add (Kaya_wire.Str text))
    text;
  let empty = !present = 0 && files = [] && custom = [] in
  emit tx
    (Kaya_wire.tx_set_drag_source id !present (List.length files)
       (List.length custom)
       (if empty then 0 else operation_mask operations)
       0 0 (List.rev !values))

(* ONE STAMPED COPY's drag declaration (docs/dnd-plan.md §4): the
   template node and the copy's keys, outermost first. The per-row payload
   an app declares after the row's insert; it overrides the template's own
   for that copy and follows it through a re-stamp. *)
let draggable_at ?text ?html ?image ?(files = []) ?(custom = [])
    ?(operations = [ Op.Copy ]) (Node id) ~keys () =
  let keys = List.map key_to_wire keys in
  let tx = the_tx () in
  let present = ref 0 in
  let values = ref [] in
  let add v = values := v :: !values in
  List.iter
    (fun (cid, bytes) ->
      ignore (accept_list [ cid ]);
      add (Kaya_wire.Str cid);
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    custom;
  List.iter (fun (f : picked_file) -> add (Kaya_wire.I64 f.handle)) files;
  Option.iter
    (fun bytes ->
      present := !present lor Kaya_wire.clip_image;
      add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
    image;
  Option.iter
    (fun html -> present := !present lor Kaya_wire.clip_html; add (Kaya_wire.Str html))
    html;
  Option.iter
    (fun text -> present := !present lor Kaya_wire.clip_text; add (Kaya_wire.Str text))
    text;
  let empty = !present = 0 && files = [] && custom = [] in
  (* KEYS FIRST, then the reps (set_column_headers' convention). *)
  emit tx
    (Kaya_wire.tx_set_drag_source id !present (List.length files)
       (List.length custom)
       (if empty then 0 else operation_mask operations)
       (List.length keys)
       0
       (keys @ List.rev !values))

(* DECLARE that a widget receives drops, performing these operations;
   naming NONE withdraws it. WHAT it takes is its [set_accepts] list,
   which must be declared first — a destination has one vocabulary, not
   two (docs/dnd-plan.md D1). *)
let set_drop_target (Widget id) operations =
  emit (the_tx ()) (Kaya_wire.tx_set_drop_target id (operation_mask operations) 0 [])


(* [draggable_at]'s twin: ONE stamped copy receives drops with these
   operations, taking what the template's [set_accepts] names. *)
let set_drop_target_at (Node id) ~keys operations =
  let keys = List.map key_to_wire keys in
  emit (the_tx ())
    (Kaya_wire.tx_set_drop_target id (operation_mask operations)
       (List.length keys) keys)

(* Rows of this live For drag within their own collection
   (docs/dnd-plan.md D8): the landing arrives at [on_drop] on the For's
   own container — the widget [for_each] returns — and the app confirms
   with a move. *)
let set_reorderable (Widget id) enabled =
  emit (the_tx ()) (Kaya_wire.tx_set_reorderable id (if enabled then 1 else 0))

(* Redeem a picked (or dropped) file's handle for a real descriptor,
   plus whether it seeks. BLOCKS, possibly for a long time, so call it
   from a thread you chose and post the result back. *)
let open_picked file mode =
  Kaya_runtime.open_picked file.handle (File_mode.wire mode)



(* Mount a root into the default window; mounting presents. *)
let mount (Widget root) = emit (the_tx ()) (Kaya_wire.tx_mount 0L root)

(* --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------
   The curried-children convention extends to items; the window
   construct's [~menus] is the bar anchor, [context_menu] the noun's. *)

(* The closed standard-command vocabulary the core enforces at runtime
   (crates/kaya/src/scene.rs, MENU_ROLES) — a module because [symbol]
   already owns the constructor [Copy] ([Op] beside it is the same
   precedent for drag operations). *)
module Menu_role = struct
  type t = Settings | Cut | Copy | Paste | Undo | Redo

  let wire = function
    | Settings -> "settings"
    | Cut -> "cut"
    | Copy -> "copy"
    | Paste -> "paste"
    | Undo -> "undo"
    | Redo -> "redo"
end

(* Create one item in the menu-item id space. Menu records are live-zone
   only: items are live and shared across stamped copies — build the
   catalog with [context_catalog] and attach it with [Tpl.context_menu]. *)
let alloc_menu_item kind label =
  let tx = the_tx () in
  if tx.app.tpl_depth > 0 then
    invalid_arg
      "kaya: menu items are live — build the context catalog in the live \
       zone (context_catalog) and attach it inside the template with \
       Tpl.context_menu";
  tx.app.c_menu_item <- Int64.add tx.app.c_menu_item 1L;
  let id = tx.app.c_menu_item in
  emit tx (Kaya_wire.tx_menu_item_create id kind);
  Option.iter (fun l -> emit tx (Kaya_wire.tx_set_menu_label id l)) label;
  id

(* The shared optional-prop tail. The two icon slots ([?icon] the blob
   channel, [?symbol] the SEMANTIC one) are different channels, not
   alternatives. Both live on the TAIL so every item gets them once. *)
let menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol () =
  let tx = the_tx () in
  Option.iter (fun e -> emit tx (Kaya_wire.tx_set_menu_enabled id e)) enabled;
  Option.iter
    (fun (s : bool signal) -> emit tx (Kaya_wire.tx_bind_menu_enabled id s.sig_id))
    bind_enabled;
  Option.iter
    (fun data ->
      emit tx (Kaya_wire.tx_set_menu_icon id (Kaya_runtime.register_blob data)))
    icon;
  Option.iter
    (fun s -> emit tx (Kaya_wire.tx_set_menu_symbol id (symbol_wire s)))
    symbol

(* An action — a leaf command firing exactly one menu_activated
   occurrence (menu click OR its shortcut: ONE occurrence, one dispatch
   path). [~on_activate_node] is the template-node flavor: the copy's key
   path arrives first — the keys ARE the noun. *)
let item ?shortcut ?enabled ?bind_enabled ?icon ?symbol ?primary ?role
    ?on_activate ?on_activate_node ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_action (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  Option.iter
    (fun (r : Menu_role.t) -> emit tx (Kaya_wire.tx_set_menu_role id (Menu_role.wire r)))
    role;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun p -> emit tx (Kaya_wire.tx_set_menu_primary id p)) primary;
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_activated id f) on_activate;
  Option.iter
    (fun f ->
      Hashtbl.replace tx.app.menu_activated_node id (fun keys ->
          f (List.map key_of_wire keys)))
    on_activate_node;
  MenuItem id

(* A toggle — a stateful leaf reusing the Checkbox contract: user
   flips emit menu_toggled ([~on_toggle] receives the new state; the
   [_node] flavor gets the stamped keys first); programmatic checked
   writes are QUIET (the echo doctrine). *)
let toggle ?checked ?bind_checked ?enabled ?bind_enabled ?icon ?symbol
    ?shortcut ?on_toggle ?on_toggle_node ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_toggle (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  Option.iter (fun c -> emit tx (Kaya_wire.tx_set_menu_checked id c)) checked;
  Option.iter
    (fun (s : bool signal) -> emit tx (Kaya_wire.tx_bind_menu_checked id s.sig_id))
    bind_checked;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_toggled id f) on_toggle;
  Option.iter
    (fun f ->
      Hashtbl.replace tx.app.menu_toggled_node id (fun keys on ->
          f (List.map key_of_wire keys) on))
    on_toggle_node;
  MenuItem id

(* One labeled radio option, appended in declaration order — the order
   IS the index vocabulary the group's value selects over. *)
let option ?enabled ?bind_enabled ?icon ?symbol ?shortcut ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_radio_option (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  MenuItem id

(* Native grouping chrome: no label, no props, no handle kept. *)
let separator () = MenuItem (alloc_menu_item Kaya_wire.menu_kind_separator None)

(* Realize a child list under a grouping node, left to right —
   [List.iter]'s SPECIFIED order, the same reason widget containers
   take thunked children (docs/traps.md, right-to-left literals). *)
let realize_menu_children tx parent children =
  List.iter
    (fun th ->
      let (MenuItem c) = th () in
      emit tx (Kaya_wire.tx_menu_item_append parent c))
    children

(* A menu grouping node — a bar root through the window construct's
   [~menus], or nested as a bare partial application in a parent's child
   list (one nested grouping level is the cap, root-checked). *)
let menu ?enabled ?bind_enabled ?icon ?symbol ~label children () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_menu (Some label) in
  realize_menu_children tx id children;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  MenuItem id

(* A radio group — the Choice contract with the platform's checkmark
   idiom. The children are [option]s only (root-checked); [~value] /
   [~bind_value] is the selected 0-based index, applied AFTER the options
   so the index has options to address; [~on_select] gets each USER pick. *)
let radio_group ?value ?bind_value ?enabled ?bind_enabled ?icon ?symbol
    ?on_select ?on_select_node ~label options () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_radio_group (Some label) in
  realize_menu_children tx id options;
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_menu_value id (float_of_int v)))
    value;
  Option.iter
    (fun (s : float signal) -> emit tx (Kaya_wire.tx_bind_menu_value id s.sig_id))
    bind_value;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_selected id f) on_select;
  Option.iter
    (fun f ->
      Hashtbl.replace tx.app.menu_selected_node id (fun keys i ->
          f (List.map key_of_wire keys) i))
    on_select_node;
  MenuItem id

(* A context menu on a LIVE widget: the same item vocabulary scoped to a
   NOUN, with the platform's own gesture (right-click, long-press). *)
let context_menu (Widget target) children =
  let tx = the_tx () in
  List.iter
    (fun th ->
      let (MenuItem m) = th () in
      emit tx (Kaya_wire.tx_context_attach target m))
    children

(* Build a context catalog UNANCHORED — free root items for a
   template-node anchor; [Tpl.context_menu] attaches it inside the
   template, and each activation carries the copy's key path. *)
let context_catalog children =
  {
    cc_roots = List.map (fun th -> let (MenuItem m) = th () in m) children;
    cc_attached = false;
  }

(* The dynamic tier for a RETAINED item. Programmatic checked/value
   writes are configuration and stay QUIET (the echo doctrine). *)
let set_menu_label (MenuItem id) text =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_label id text)

(* The phone-bar promotion hint (actions only — root-checked).
   Flipping it recomputes the promoted set deterministically; INERT on
   desktops — not a toolbar grammar. *)
let set_menu_primary (MenuItem id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_primary id on)

(* A named vocabulary for the accept list's closed half. A MISTYPED BARE
   STRING IS SILENT: it becomes a custom format id no clipboard will ever
   offer, so Paste stays dead and the paste hook never fires, with
   nothing to see anywhere. *)
let accept_text = "text"
let accept_image = "image"
let accept_files = "files"

(* Reopen a RETAINED grouping node and append more children — the
   append-at-any-time discipline: [menu_append file [ item ~label:"Publish"
   ~primary:true ~on_activate:h ]]. *)
let menu_append (MenuItem id) children =
  realize_menu_children (the_tx ()) id children


let alloc_node tx =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  tx.app.c_widget

(* A For over a collection: [body] declares the template; the For
   itself (a live container) is returned alongside the body's result. *)
let for_each c body () =
  let tx = the_tx () in
  assert_root c;
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_for id c.cid);
  tx.app.open_fors <- c.cid :: tx.app.open_fors;
  let result = in_tpl_scope tx.app body in
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

(* A For as a child: for_each whose body keeps no handles — the
   common case once handlers co-locate at their constructors. *)
let each c body () = fst (for_each c body ())

(* The header bar's sort indicator (docs/tables-plan.md): which column
   shows it, in which direction — the guest's declaration, re-sent
   with the new state after it handles a sort request. The platform
   never sorts; a header click only asks. *)
type sort = { sort_column : int32; sort_direction : int32 }

let sort_none = { sort_column = -1l; sort_direction = 0l }
let sort_asc column = { sort_column = Int32.of_int column; sort_direction = 0l }
let sort_desc column = { sort_column = Int32.of_int column; sort_direction = 1l }

(* Declare the column header bar on a For's container — the widget
   [for_each] returns. One title per column; the row template's root must
   be a row of exactly one cell per column, refused loudly otherwise.
   Re-call after sorting to move the indicator. [~on_sort] answers the
   header clicks with the 0-based column. *)
let columns ?(on_sort : (int -> unit) option) (Widget id) titles sort =
  let tx = the_tx () in
  Option.iter
    (fun handler -> Hashtbl.replace tx.app.sort_handlers id handler)
    on_sort;
  (* path_len 0: no key path, so the values are titles alone
     (docs/tables-plan.md, dynamic tables). *)
  emit tx
    (Kaya_wire.tx_set_column_headers id
       (Int32.to_int sort.sort_column land 0xFFFFFFFF)
       (Int32.to_int sort.sort_direction)
       (List.length titles) 0
       (List.map (fun t -> Kaya_wire.Str t) titles))

(* Re-declare ONE stamped copy's header bar — the per-copy sort arrows.
   [node] is the nested For's template node and [keys] the copy's key path
   outermost first; an empty [keys] re-declares the template-wide bar. The
   core walls a keyed target whose template bar was never declared
   (docs/tables-plan.md). *)
let columns_at (Node id) (keys : key list) titles sort =
  let tx = the_tx () in
  let wire_keys = List.map key_to_wire keys in
  emit tx
    (Kaya_wire.tx_set_column_headers id
       (Int32.to_int sort.sort_column land 0xFFFFFFFF)
       (Int32.to_int sort.sort_direction)
       (List.length titles) (List.length keys)
       (wire_keys @ List.map (fun t -> Kaya_wire.Str t) titles))

(* Sums: a variant type whose constructors carry inline records. *)
type 'a sum_type = {
  st_schemas : int list list;
  st_variant : 'a -> int;
  st_to_values : 'a -> Kaya_wire.value list;
  st_of_values : int -> Kaya_wire.value list -> 'a;
}

type 'a sum_collection = { sc_handle : collection; sc_type : 'a sum_type }


let sum_of st =
  let tx = the_tx () in
  tx.app.c_collection <- Int64.add tx.app.c_collection 1L;
  let id = tx.app.c_collection in
  (match tx.app.open_fors with
  | parent :: _ ->
      Hashtbl.replace tx.app.children parent
        (Option.value ~default:[] (Hashtbl.find_opt tx.app.children parent) @ [ id ])
  | [] -> ());
  emit tx (Kaya_wire.tx_create_collection id st.st_schemas);
  { sc_handle = { cid = id; cpath = [] }; sc_type = st }

(* Insert witnesses the value's own constructor onto the wire. *)
let sum_insert sc (k : key) value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let variant = sc.sc_type.st_variant value in
  let fields = sc.sc_type.st_to_values value in
  (* ABSORPTION, on the one path every explicit key of a sum collection
     travels — see [insert_fresh]. *)
  absorb_key tx.app sc.sc_handle.cid sc.sc_handle.cpath key;
  model_set tx sc.sc_handle.cid sc.sc_handle.cpath key variant fields;
  emit tx
    (Kaya_wire.tx_collection_insert sc.sc_handle.cid sc.sc_handle.cpath key
       variant
       (encode_fields (List.nth sc.sc_type.st_schemas variant) fields));
  recompute_derived tx sc.sc_handle.cid sc.sc_handle.cpath


(* Update replaces a record wholesale; a different constructor than
   the entry's current one restamps its copy in place. *)
let sum_update sc (k : key) value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let variant = sc.sc_type.st_variant value in
  let fields = sc.sc_type.st_to_values value in
  model_set tx sc.sc_handle.cid sc.sc_handle.cpath key variant fields;
  emit tx
    (Kaya_wire.tx_collection_update sc.sc_handle.cid sc.sc_handle.cpath key
       variant
       (encode_fields (List.nth sc.sc_type.st_schemas variant) fields));
  recompute_derived tx sc.sc_handle.cid sc.sc_handle.cpath

(* The typed model, in insertion order; [match] eliminates the
   values. *)
let sum_items sc : (key * 'a) list =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt
      (fun i -> i.path = sc.sc_handle.cpath)
      (instances_of tx.app sc.sc_handle.cid)
  with
  | Some i ->
      List.map
        (fun (k, (v, vs)) -> (key_of_wire k, sc.sc_type.st_of_values v vs))
        i.entries
  | None -> []

(* The entry's current value — the scrutinee for the match that
   precedes a patch. *)
let sum_get sc (k : key) =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt
      (fun i -> i.path = sc.sc_handle.cpath)
      (instances_of tx.app sc.sc_handle.cid)
  with
  | Some i ->
      Option.map
        (fun (v, vs) -> sc.sc_type.st_of_values v vs)
        (List.assoc_opt (key_to_wire k) i.entries)
  | None -> None

(* The witnessed field write, called by the generated per-constructor
   patches: the match that produced the write names the variant, and
   the model refuses a drifted entry — the guard is checked, not
   trusted. *)
let sum_update_field sc (k : key) ~variant fd value =
  let tx = the_tx () in
  let key = key_to_wire k in
  let mv = fd.fd_to_value value in
  let stored, current =
    match
      List.find_opt
        (fun i -> i.path = sc.sc_handle.cpath)
        (instances_of tx.app sc.sc_handle.cid)
    with
    | Some i -> (
        match List.assoc_opt key i.entries with
        | Some (v, vs) -> (v, vs)
        | None -> invalid_arg "kaya: update of missing key")
    | None -> invalid_arg "kaya: update of missing instance"
  in
  if stored <> variant then
    invalid_arg "kaya: update_field witnessed a constructor the entry no longer holds";
  let updated = List.mapi (fun i v -> if i = fd.fd_index then mv else v) current in
  model_set tx sc.sc_handle.cid sc.sc_handle.cpath key variant updated;
  emit tx
    (Kaya_wire.tx_collection_update_field sc.sc_handle.cid sc.sc_handle.cpath
       key fd.fd_index variant
       (encode_field
          (List.nth (List.nth sc.sc_type.st_schemas variant) fd.fd_index)
          mv));
  recompute_derived tx sc.sc_handle.cid sc.sc_handle.cpath

(* The collection-derived signal, over the sum's entries. *)
let sum_derive witness sc compute =
  let tx = the_tx () in
  let s = signal witness (compute (sum_items sc)) in
  tx.pending_derived <-
    (sc.sc_handle.cid, fun () -> write s (compute (sum_items sc)))
    :: tx.pending_derived;
  s

(* The eliminator's mechanism: (variant, arm) pairs in declaration order,
   each arm a Tpl program. *)
let each_sum sc arms () =
  let tx = the_tx () in
  assert_root sc.sc_handle;
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_for id sc.sc_handle.cid);
  tx.app.open_fors <- sc.sc_handle.cid :: tx.app.open_fors;
  in_tpl_scope tx.app (fun () ->
      List.iter
        (fun (variant, arm) ->
          emit tx (Kaya_wire.tx_variant_case variant);
          (* The arm's result is its blueprint root, already recorded —
             discard so arms can END with the root, no ignore. *)
          ignore (arm ()))
        arms);
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  Widget id

(* A When over a Bool signal: stamps on true, unstamps on false. *)
let when_ (s : bool signal) body () =
  let tx = the_tx () in
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_when id s.sig_id);
  let result = in_tpl_scope tx.app body in
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

(* A When AS A CHILD: [when_] with the body's result thrown away — the
   [each] to its [for_each]. *)
let shown s body () = fst (when_ s body ())

module Tpl = struct
  (* The template zone, direct style like the outer zone: the ambient
     transaction serves template bodies too. *)

  (* --- THE FLOOR, IN A MODULE THAT SAYS SO -------------------------
     A MODULE AND NOT A NAME because the receiver's type is the whole
     difference between [set_text editor doc] and [set_text n "add"], and
     no pattern over a guest file sees a type; the qualifier is what a
     pattern CAN see (docs/tpl-props-plan.md F3). No example scene may
     spell this tier (invariant 5). *)
  module Floor = struct
    let widget kind =
      let tx = the_tx () in
      let id = alloc_node tx in
      emit tx (Kaya_wire.tx_create_widget id kind);
      Node id

    (* --- The const setters ------------------------------------------
       The live setters with [Node] destructured instead of [Widget]; the
       wrapper's constructor is what keeps a live setter off a blueprint
       and a template setter off a widget. *)

    let set_text (Node id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

    let set_checked (Node id) checked =
      emit (the_tx ()) (Kaya_wire.tx_set_checked id checked)

    let set_value (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_value id v)
    let set_min (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_min id v)
    let set_max (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_max id v)
    let set_step (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_step id v)

    let set_tick_spacing (Node id) v =
      emit (the_tx ()) (Kaya_wire.tx_set_tick_spacing id v)

    let set_indeterminate (Node id) on =
      emit (the_tx ()) (Kaya_wire.tx_set_indeterminate id on)

    let set_columns (Node id) n =
      emit (the_tx ()) (Kaya_wire.tx_set_columns id (float_of_int n))

    let set_source (Node id) data =
      emit (the_tx ()) (Kaya_wire.tx_set_source id (Kaya_runtime.register_blob data))

    let set_grow (Node id) weight = emit (the_tx ()) (Kaya_wire.tx_set_grow id weight)

    (* A stamped copy's cross-axis stretch (the live [set_fill]). *)
    let set_fill (Node id) on = emit (the_tx ()) (Kaya_wire.tx_set_fill id on)

    (* A stamped grid's auto columns at a floor (the live
       [set_columns_auto]; docs/layout-knobs-plan.md §3). *)
    let set_columns_auto (Node id) min_width =
      let tx = the_tx () in
      emit tx (Kaya_wire.tx_set_columns id 0.0);
      emit tx (Kaya_wire.tx_set_min_column_width id min_width)

    (* A stamped row that flows onto new lines (the live [set_wrap];
       docs/layout-knobs-plan.md §2). *)
    let set_wrap (Node id) on = emit (the_tx ()) (Kaya_wire.tx_set_wrap id on)

    (* CONST ONLY, like [set_accepts]: what a copy means, and how far its
       prototype holds its children off its edge, are facts about the
       PROTOTYPE. Neither needs a type-level wall — the root judges the
       combination while the blueprint is recorded, before a row stamps. *)

    let set_role (Node id) r = emit (the_tx ()) (Kaya_wire.tx_set_role id (role_wire r))
    let set_inset (Node id) pad = emit (the_tx ()) (Kaya_wire.tx_set_inset id pad)

    (* A DUPLICATE a11y ID ACROSS COPIES IS LEGAL and often right:
       nothing in the core deduplicates them and the harness addresses by
       kind#index, never by id. *)

    let set_a11y_id (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_id id value)

    let bind_a11y_id (Node id) (s : string signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_id id s.sig_id)

    (* A (_, string) field only: Prop::A11yId is Str in the spec and the
       scene refuses a field whose column type differs, so the phantom
       moves that abort to compile time. *)
    let bind_a11y_id_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_id_element ~level ~field:fd.fd_index id)

    let set_a11y_label (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_label id value)

    let bind_a11y_label (Node id) (s : string signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_label id s.sig_id)

    (* THE SOURCE THIS SLICE EXISTS FOR: each stamped copy speaks its OWN
       row's name to assistive tech. *)
    let bind_a11y_label_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_label_element ~level ~field:fd.fd_index id)

    let set_help (Node id) value = emit (the_tx ()) (Kaya_wire.tx_set_help id value)

    let bind_help (Node id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_help id s.sig_id)

    (* The row's own field as the copy's help — the source the zone
       exists for. *)
    let bind_help_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_help_element ~level ~field:fd.fd_index id)

    (* A stamped field's PROMPT while it is empty (docs/search-plan.md
       S3). *)
    let set_placeholder (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_placeholder id value)

    let bind_placeholder (Node id) (s : string signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_placeholder id s.sig_id)

    let bind_placeholder_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_placeholder_element ~level ~field:fd.fd_index id)

    (* A stamped link's DESTINATION (docs/tasks-s2-plan.md T3). *)
    let set_href (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_href id value)

    let bind_href (Node id) (s : string signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_href id s.sig_id)

    let bind_href_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_href_element ~level ~field:fd.fd_index id)

    (* ACTIVATION KINDS ONLY — button, checkbox, select, radio. It cannot
       be a type here ([node] is not typed by kind), so the wall is the
       constructors and the root's own refusal at DECLARE time. *)
    let set_a11y_hint (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_hint id value)

    let bind_a11y_hint (Node id) (s : string signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_hint id s.sig_id)

    let bind_a11y_hint_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_hint_element ~level ~field:fd.fd_index id)

    (* The two universal props as they ride every constructor here,
       applied in one place so a new constructor cannot pick up [~grow]
       and quietly miss them. [~a11y_level] is separate from [~level] on
       purpose: ONE SHARED LEVEL would have moved the label's source out
       one For as well, silently. *)
    let set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
        ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(a11y_level = 0) n =
      Option.iter (fun v -> set_a11y_id n v) a11y_id;
      Option.iter (fun s -> bind_a11y_id n s) a11y_id_bind;
      Option.iter (fun fd -> bind_a11y_id_field ~level:a11y_level n fd) a11y_id_field;
      Option.iter (fun v -> set_a11y_label n v) a11y_label;
      Option.iter (fun s -> bind_a11y_label n s) a11y_label_bind;
      Option.iter (fun fd -> bind_a11y_label_field ~level:a11y_level n fd) a11y_label_field;
      Option.iter (fun v -> set_help n v) help;
      Option.iter (fun s -> bind_help n s) help_bind;
      Option.iter (fun fd -> bind_help_field ~level:a11y_level n fd) help_field

    (* What a stamped copy takes from a paste — and the prop that lets a
       copy's paste hook fire at all: every backend gates the paste
       occurrence on the focused widget's ACCEPT LIST, so without this
       [on_paste_node] would wait forever (docs/tpl-props-plan.md §1).
       CONST ONLY: an accept list describes the PROTOTYPE. *)
    let set_accepts (Node id) kinds =
      emit (the_tx ()) (Kaya_wire.tx_set_accepts id (accept_list kinds))


    (* --- The signal leg ----------------------------------------------
       A signal is app-wide, so every stamped copy reads the SAME value:
       one download's fraction on every row's bar. *)

    let bind_text (Node id) (s : string signal) = emit (the_tx ()) (Kaya_wire.tx_bind_text id s.sig_id)

    let bind_checked (Node id) (s : bool signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_checked id s.sig_id)

    let bind_value (Node id) (s : float signal) = emit (the_tx ()) (Kaya_wire.tx_bind_value id s.sig_id)

    let bind_source (Node id) (s : bytes signal) =
      emit (the_tx ()) (Kaya_wire.tx_bind_source id s.sig_id)

    (* --- The element leg ---------------------------------------------
       The source only this zone has: the row's own data. [level] says
       how many Fors up the element sits (0 = nearest). *)


    (* Bind a label's text to one field of the element; a (_, string)
       field only — the phantom pins it at compile time. *)
    let bind_text_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_text_element ~level ~field:fd.fd_index id)

    (* Bind a checkbox's state to one field of the element; a (_, bool)
       field only. *)
    let bind_checked_field ?(level = 0) (Node id) (fd : (_, bool) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_checked_element ~level ~field:fd.fd_index id)

    (* Bind a fraction, a slider position or a choice's selected index to
       one field of the element. A (_, float) field, and a choice's index
       is no exception: Prop::Value is F64 and the scene refuses a field
       whose column type differs, so an i64 field would abort at declare. *)
    let bind_value_field ?(level = 0) (Node id) (fd : (_, float) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_value_element ~level ~field:fd.fd_index id)

    (* Bind a date picker's value to one field of the element; a
       (_, date) field only (docs/datetime-plan.md D10). *)
    let bind_date_field ?(level = 0) (Node id) (fd : (_, date) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_date_element ~level ~field:fd.fd_index id)

    (* Bind a time picker's value to one field of the element. *)
    let bind_time_field ?(level = 0) (Node id) (fd : (_, time) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_time_element ~level ~field:fd.fd_index id)

    (* Bind an image's source to one field of the element; a (_, bytes)
       field only — the phantom pins it at compile time. *)
    let bind_source_field ?(level = 0) (Node id) (fd : (_, bytes) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_source_element ~level ~field:fd.fd_index id)

    (* A stamped copy carries attribute runs (the live [set_rich]). *)
    let set_rich (Node id) on = emit (the_tx ()) (Kaya_wire.tx_set_rich id on)

    (* Bind a stamped rich textarea's whole document to one field of the
       element; a (_, document) field only. The core refuses [document]
       without [rich] before it, which is why [Tpl.textarea] sends the
       pair (docs/rich-text-plan.md §19). *)
    let bind_document_field ?(level = 0) (Node id) (fd : (_, document) field) =
      emit (the_tx ())
        (Kaya_wire.tx_bind_document_element ~level ~field:fd.fd_index id)

    let add_child (Node parent) (Node child) =
      emit (the_tx ()) (Kaya_wire.tx_add_child parent child)
  end

  let collection () = collection ()

  (* The record-schema constructor, in the zone a NESTED collection must
     be declared in; re-exported so the template zone's own surface
     carries it (docs/deferred.md, the nested-record-collection gap). *)
  let collection_of rt = collection_of rt

  let for_each c body () =
    let tx = the_tx () in
    assert_root c;
    let id = alloc_node tx in
    emit tx (Kaya_wire.tx_create_for id c.cid);
    tx.app.open_fors <- c.cid :: tx.app.open_fors;
    let result = in_tpl_scope tx.app body in
    tx.app.open_fors <- List.tl tx.app.open_fors;
    emit tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  (* A nested For AS A CHILD: [for_each] with the body's result thrown
     away, so the partial application is a [unit -> node] creator that
     slots into a child list. *)
  let each c body () = fst (for_each c body ())

  (* Declare the header bar of a nested For — one bar per stamped copy
     from ONE declaration on the template node. It goes on the NEXT LINE,
     inside the still-open parent scope: the nested For folds into that
     parent at its TemplateEnd and this op looks for it there, so a
     grandparent-scope target is not expressible (docs/tables-plan.md).
     ONE [~on_sort] answers every copy, keys before the column. *)
  let columns
      ?(on_sort : (key list -> int -> unit) option)
      (Node id) titles sort =
    let tx = the_tx () in
    Option.iter
      (fun handler ->
        Hashtbl.replace tx.app.node_sorts id (fun keys col ->
            handler (List.map key_of_wire keys) col))
      on_sort;
    (* path_len 0 against a TEMPLATE NODE: every copy's bar, stored on
       the site and applied at each stamp. *)
    emit tx
      (Kaya_wire.tx_set_column_headers id
         (Int32.to_int sort.sort_column land 0xFFFFFFFF)
         (Int32.to_int sort.sort_direction)
         (List.length titles) 0
         (List.map (fun t -> Kaya_wire.Str t) titles))

  (* The template zone's own drag surface (docs/dnd-plan.md §4), at the
     SUGAR tier beside [columns]: every stamped copy of this node hands
     this payload over with its own identity, and each representation is
     a CONSTANT or the ROW'S OWN FIELD — [~text_field:item_title] binds
     the way [label ~bind_field:item_title] does, resolved per copy and
     re-declared when the field changes. A file never binds; a copy's own
     payload is [draggable_at] after its insert, constants only. The
     copy's keys reach the app through [on_drag_ended_node]. *)
  let draggable ?text ?text_field ?html ?html_field ?image ?image_field
      ?(files = []) ?(custom = []) ?(custom_fields = [])
      ?(operations = [ Op.Copy ]) (Node id) () =
    let tx = the_tx () in
    let present = ref 0 in
    let bound = ref 0 in
    let count = ref 0 in
    let values = ref [] in
    let add v =
      values := v :: !values;
      incr count
    in
    (* A bound slot rides as the i64 [level << 32 | field], level 0 being
       the row this template is stamped for; the slot IS its index. *)
    let slot = function
      | None -> false
      | Some index ->
          bound := !bound lor (1 lsl !count);
          add (Kaya_wire.I64 (Int64.of_int index));
          true
    in
    let index_of fd = Option.map (fun f -> f.fd_index) fd in
    List.iter
      (fun (cid, bytes) ->
        ignore (accept_list [ cid ]);
        add (Kaya_wire.Str cid);
        add (Kaya_wire.Blob (Kaya_runtime.register_blob (Bytes.of_string bytes))))
      custom;
    List.iter
      (fun (cid, (fd : (_, bytes) field)) ->
        ignore (accept_list [ cid ]);
        add (Kaya_wire.Str cid);
        ignore (slot (Some fd.fd_index)))
      custom_fields;
    List.iter (fun (f : picked_file) -> add (Kaya_wire.I64 f.handle)) files;
    if image <> None || image_field <> None then begin
      present := !present lor Kaya_wire.clip_image;
      if not (slot (index_of image_field)) then
        add
          (Kaya_wire.Blob
             (Kaya_runtime.register_blob (Bytes.of_string (Option.get image))))
    end;
    if html <> None || html_field <> None then begin
      present := !present lor Kaya_wire.clip_html;
      if not (slot (index_of html_field)) then
        add (Kaya_wire.Str (Option.get html))
    end;
    if text <> None || text_field <> None then begin
      present := !present lor Kaya_wire.clip_text;
      if not (slot (index_of text_field)) then
        add (Kaya_wire.Str (Option.get text))
    end;
    let customs = List.length custom + List.length custom_fields in
    let empty = !present = 0 && files = [] && customs = 0 in
    emit tx
      (Kaya_wire.tx_set_drag_source id !present (List.length files) customs
         (if empty then 0 else operation_mask operations)
         0 !bound (List.rev !values))

  (* Every stamped copy receives drops with these operations, taking what
     [set_accepts] names; the landing arrives at [on_drop_node] with the
     copy's keys. *)
  let set_drop_target n operations = set_drop_target_at n ~keys:[] operations

  (* An accept list on a template node — re-exported here for
     [collection_of]'s reason: a drop target is any widget and shares the
     paste list, so the zone's own surface must carry the declaration
     [set_drop_target] reads. *)
  let set_accepts n kinds = Floor.set_accepts n kinds

  let when_ (s : bool signal) body () =
    let tx = the_tx () in
    let id = alloc_node tx in
    emit tx (Kaya_wire.tx_create_when id s.sig_id);
    let result = in_tpl_scope tx.app body in
    emit tx (Kaya_wire.tx_template_end ());
    (Node id, result)


  let button ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?role ?text ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_click () =
    let n = Floor.widget Kaya_wire.kind_button in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    (* [Destructive] or [Prominent] — the stamped row's own delete
       button, which is what this prop reaching the zone is for; a
       [Heading] or [Caption] button dies at the root, as it does live. *)
    Option.iter (fun r -> Floor.set_role n r) role;
    Option.iter (fun s -> Floor.bind_a11y_hint n s) a11y_hint_bind;
    Option.iter (fun fd -> Floor.bind_a11y_hint_field ~level:a11y_level n fd)
      a11y_hint_field;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (match on_click with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_handlers id (fun keys ->
            handler (List.map key_of_wire keys))
    | None -> ());
    n

  (* A multi-line editor per stamped copy: the entry's uncontrolled contract
     over the platform's real multi-line control. [~document_field] makes
     the copy RICH and binds its whole document to that field of the row
     (docs/rich-text-plan.md §19). *)
  let textarea ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?placeholder
      ?placeholder_bind ?placeholder_field ?accepts ?text ?bind ?bind_field
      ?document_field ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_textarea in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_placeholder n v) placeholder;
    Option.iter (fun s -> Floor.bind_placeholder n s) placeholder_bind;
    Option.iter (fun fd -> Floor.bind_placeholder_field ~level n fd) placeholder_field;
    Option.iter (fun kinds -> Floor.set_accepts n kinds) accepts;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (* [rich] FIRST, then the bound document — the core refuses the one
       without the other before it — and the bind is recorded so a copy's
       own act folds into its ROW. *)
    Option.iter
      (fun (fd : (_, document) field) ->
        let tx = the_tx () in
        Floor.set_rich n true;
        (match List.nth_opt tx.app.open_fors level with
        | Some cid ->
            let (Node id) = n in
            Hashtbl.replace tx.app.document_binds id (cid, fd.fd_index, level)
        | None -> ());
        Floor.bind_document_field ~level n fd)
      document_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_changes id (fun keys s ->
            handler (List.map key_of_wire keys) s)
    | None -> ());
    n

  let label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?role ?href
      ?href_bind ?href_field ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) () =
    let n = Floor.widget Kaya_wire.kind_label in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    (* [Heading] and [Caption] are the label's roles; the two button
       emphases die at the root. *)
    Option.iter (fun r -> Floor.set_role n r) role;
    Option.iter (fun u -> Floor.set_href n u) href;
    Option.iter (fun s -> Floor.bind_href n s) href_bind;
    Option.iter (fun fd -> Floor.bind_href_field ~level n fd) href_field;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    n

  (* A stamped label wearing [Heading], in one word: the section title of
     a row, styled and announced as a heading. *)
  let heading ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?text ?bind ?bind_field ?level
      ?a11y_level () =
    label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~role:Heading ?text ?bind ?bind_field
      ?level ?a11y_level ()

  (* Its counterpart: the stamped row's footnote, under the content it
     explains. *)
  let caption ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?text ?bind ?bind_field ?level
      ?a11y_level () =
    label ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~role:Caption ?text ?bind ?bind_field
      ?level ?a11y_level ()

  (* A single-line text field per stamped copy. UNCONTROLLED as its live
     twin is: the copy owns its text and every edit arrives at
     [~on_change] with that copy's keys first. *)
  let entry ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?placeholder
      ?placeholder_bind ?placeholder_field ?accepts ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_entry in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_placeholder n v) placeholder;
    Option.iter (fun s -> Floor.bind_placeholder n s) placeholder_bind;
    Option.iter (fun fd -> Floor.bind_placeholder_field ~level n fd) placeholder_field;
    Option.iter (fun kinds -> Floor.set_accepts n kinds) accepts;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_changes id (fun keys s ->
            handler (List.map key_of_wire keys) s)
    | None -> ());
    n

  (* A search field per stamped copy: [entry]'s uncontrolled contract
     under the platform's search chrome (docs/search-plan.md). *)
  let search ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?placeholder
      ?placeholder_bind ?placeholder_field ?accepts ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_search in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_placeholder n v) placeholder;
    Option.iter (fun s -> Floor.bind_placeholder n s) placeholder_bind;
    Option.iter (fun fd -> Floor.bind_placeholder_field ~level n fd) placeholder_field;
    Option.iter (fun kinds -> Floor.set_accepts n kinds) accepts;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_changes id (fun keys s ->
            handler (List.map key_of_wire keys) s)
    | None -> ());
    n

  (* A progress bar per stamped copy: display-only, like label and image. *)
  let progress ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?value ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?indeterminate () =
    let n = Floor.widget Kaya_wire.kind_progress in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_value n v) value;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    Option.iter (fun i -> Floor.set_indeterminate n i) indeterminate;
    n

  (* A slider per stamped copy, over [~min]..[~max] at a position from any
     of the three sources. *)
  let slider ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(min = 0.0) ?(max = 1.0) ?value ?step
      ?tick_spacing ?bind ?bind_field ?(level = 0) ?(a11y_level = level)
      ?on_change ?on_commit () =
    let n = Floor.widget Kaya_wire.kind_slider in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Floor.set_min n min;
    Floor.set_max n max;
    Option.iter (fun v -> Floor.set_step n v) step;
    Option.iter (fun v -> Floor.set_tick_spacing n v) tick_spacing;
    Option.iter (fun v -> Floor.set_value n v) value;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_values id (fun keys v ->
            handler (List.map key_of_wire keys) v)
    | None -> ());
    (match on_commit with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_commits id (fun keys v ->
            handler (List.map key_of_wire keys) v)
    | None -> ());
    n

  (* A dropdown select per stamped copy, over fixed [options] — each
     option becomes a label child. The SELECTED INDEX varies per row;
     [~bind_field] wants a (_, float) field (see [bind_value_field]). *)
  let select ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?selected ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_select options () =
    let n = Floor.widget Kaya_wire.kind_select in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    Option.iter (fun s -> Floor.bind_a11y_hint n s) a11y_hint_bind;
    Option.iter (fun fd -> Floor.bind_a11y_hint_field ~level:a11y_level n fd)
      a11y_hint_field;
    List.iter
      (fun option_text ->
        let o = Floor.widget Kaya_wire.kind_label in
        Floor.set_text o option_text;
        Floor.add_child n o)
      options;
    Option.iter (fun i -> Floor.set_value n (float_of_int i)) selected;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    (match on_select with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_values id (fun keys v ->
            handler (List.map key_of_wire keys) (int_of_float v))
    | None -> ());
    n

  (* A radio group per stamped copy — the choice contract ([select]) in
     its inline presentation: same option children, same 0-based index
     from the same three sources, same pick handler. *)
  let radio ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?selected ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_select options () =
    let n = Floor.widget Kaya_wire.kind_radio in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    Option.iter (fun s -> Floor.bind_a11y_hint n s) a11y_hint_bind;
    Option.iter (fun fd -> Floor.bind_a11y_hint_field ~level:a11y_level n fd)
      a11y_hint_field;
    List.iter
      (fun option_text ->
        let o = Floor.widget Kaya_wire.kind_label in
        Floor.set_text o option_text;
        Floor.add_child n o)
      options;
    Option.iter (fun i -> Floor.set_value n (float_of_int i)) selected;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    (match on_select with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_values id (fun keys v ->
            handler (List.map key_of_wire keys) (int_of_float v))
    | None -> ());
    n

  let checkbox ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?checked ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_toggle () =
    let n = Floor.widget Kaya_wire.kind_checkbox in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    Option.iter (fun s -> Floor.bind_a11y_hint n s) a11y_hint_bind;
    Option.iter (fun fd -> Floor.bind_a11y_hint_field ~level:a11y_level n fd)
      a11y_hint_field;
    Option.iter (fun c -> Floor.set_checked n c) checked;
    Option.iter (fun s -> Floor.bind_checked n s) bind;
    Option.iter (fun fd -> Floor.bind_checked_field ~level n fd) bind_field;
    (match on_toggle with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_toggles id (fun keys on ->
            handler (List.map key_of_wire keys) on)
    | None -> ());
    n

  (* A date picker per stamped copy: [~value] a constant, [~bind] a
     signal, [~bind_field] the row's own (_, date) field — the "due date
     per row" shape (docs/datetime-plan.md D10). Picks carry the copy's
     keys first. *)
  let date_picker ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?value ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_date_picker in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    let (Node id) = n in
    Option.iter
      (fun (d : date) ->
        ignore (pack_date d);
        emit (the_tx ())
          (Kaya_wire.tx_set_date id d.year d.month d.day))
      value;
    Option.iter
      (fun (s : date signal) -> emit (the_tx ()) (Kaya_wire.tx_bind_date id s.sig_id))
      bind;
    Option.iter (fun fd -> Floor.bind_date_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        Hashtbl.replace (the_tx ()).app.node_dates id (fun keys packed ->
            handler (List.map key_of_wire keys) (date_of_packed packed))
    | None -> ());
    n

  (* A time picker per stamped copy — the date picker's three sources,
     hours and minutes. *)
  let time_picker ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_hint ?value ?bind ?bind_field
      ?step ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_time_picker in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    let (Node id) = n in
    Option.iter
      (fun m -> emit (the_tx ()) (Kaya_wire.tx_set_minute_step id (float_of_int m)))
      step;
    Option.iter
      (fun (t : time) ->
        ignore (pack_time t);
        emit (the_tx ())
          (Kaya_wire.tx_set_time id t.hour t.minute))
      value;
    Option.iter
      (fun (s : time signal) -> emit (the_tx ()) (Kaya_wire.tx_bind_time id s.sig_id))
      bind;
    Option.iter (fun fd -> Floor.bind_time_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        Hashtbl.replace (the_tx ()).app.node_times id (fun keys packed ->
            handler (List.map key_of_wire keys) (time_of_packed packed))
    | None -> ());
    n

  (* An image per stamped copy: [~source] gives every copy the same bytes,
     [~bind] a Blob signal, [~bind_field] each row's own (_, bytes)
     field — the per-row thumbnail. *)
  let image ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?source ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) () =
    let n = Floor.widget Kaya_wire.kind_image in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun data -> Floor.set_source n data) source;
    Option.iter (fun s -> Floor.bind_source n s) bind;
    Option.iter (fun fd -> Floor.bind_source_field ~level n fd) bind_field;
    n

  (* A canvas per stamped copy -- a sparkline in a table cell
     (docs/canvas-plan.md §3.1). The drawing is declared with the node, so
     every copy is born with it; [draw_at] re-declares one copy's. *)
  let canvas ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(a11y_level = 0) ~viewbox ~draw () =
    let n = Floor.widget Kaya_wire.kind_canvas in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    let (Node id) = n in
    emit (the_tx ()) (drawing_record id [] viewbox draw);
    n


  (* Containers, the outer-zone convention: children are partially
     applied creators ([unit -> node] thunks), realized left to
     right; [()] realizes, omitting it nominates a child. *)
  let container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(a11y_level = 0) ?inset kind children ()
      =
    let parent = Floor.widget kind in
    Option.iter (fun g -> Floor.set_grow parent g) grow;
    Option.iter (fun v -> Floor.set_fill parent v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level parent;
    (* Every stamped copy's own padding. [~spacing] and [~align] stay
       floor-only on template containers, in every binding alike. *)
    Option.iter (fun p -> Floor.set_inset parent p) inset;
    List.iter (fun child -> Floor.add_child parent (child ())) children;
    parent

  (* A grid per stamped copy, laid out row-major into [~columns] columns —
     each column takes its NATURAL width. The count describes the
     prototype, so it stays a required constant. *)
  let grid ~columns ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(a11y_level = 0) ?inset ?columns_auto children () =
    let n = Floor.widget Kaya_wire.kind_grid in
    Floor.set_columns n columns;
    Option.iter (fun m -> Floor.set_columns_auto n m) columns_auto;
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Option.iter (fun v -> Floor.set_fill n v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level n;
    Option.iter (fun p -> Floor.set_inset n p) inset;
    List.iter (fun child -> Floor.add_child n (child ())) children;
    n

  (* A LABELLED ROW per stamped copy (docs/forms-plan.md): [~label],
     [~label_bind] or [~label_field] names the one control the children
     declare, with an optional trailing button after it. *)
  let labeled ?label ?label_bind ?label_field ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?(a11y_level = 0) ?(level = 0) children () =
    let parent = Floor.widget Kaya_wire.kind_labeled in
    Option.iter (fun g -> Floor.set_grow parent g) grow;
    Option.iter (fun v -> Floor.set_fill parent v) fill;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ~a11y_level parent;
    let name = Floor.widget Kaya_wire.kind_label in
    Option.iter (fun t -> Floor.set_text name t) label;
    Option.iter (fun s -> Floor.bind_text name s) label_bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level name fd) label_field;
    Floor.add_child parent name;
    List.iter (fun child -> Floor.add_child parent (child ())) children;
    parent

  (* A spacer: PURE SUGAR for an empty grown column — it consumes the
     leftover main-axis space between its siblings, in every stamped copy. *)
  let spacer ?(grow = 1.0) () =
    let n = Floor.widget Kaya_wire.kind_column in
    Floor.set_grow n grow;
    n

  (* The three named containers forward the props ONE BY ONE, which the
     partial application they used to be could not: an optional argument in
     front of a positional one is erased the moment the positional one is
     supplied, so [container kind_column] would have defaulted every prop
     and swallowed the caller's. *)
  let column ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level ?inset children =
    container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level ?inset
      Kaya_wire.kind_column children

  (* A vertical scroll viewport per stamped copy, over EXACTLY ONE child.
     Pass [~grow] so the enclosing track CONSTRAINS it. CAUTION: the scene
     enforces the one-child rule on the live path only; the template
     declare arm does not check it yet, so a second child here is accepted
     in silence until that gap closes. *)
  let scroll ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level children =
    container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level Kaya_wire.kind_scroll
      children

  (* [~inset] rides the two flex containers and the grid and stops there,
     exactly as it does live: the root admits the prop on Column, Row and
     Grid alone, so [scroll] forwards no inset. *)
  let row ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level ?inset ?wrap children () =
    let parent =
      container ?grow ?fill ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
        ?a11y_label_bind ?a11y_label_field ?help ?help_bind ?help_field ?a11y_level ?inset Kaya_wire.kind_row
        children ()
    in
    Option.iter (fun v -> Floor.set_wrap parent v) wrap;
    parent

  (* Attach a live-built context catalog to a template node: each
     activation carries that copy's key path — the keys ARE the noun. *)
  let context_menu (Node n) catalog =
    if catalog.cc_attached then
      invalid_arg "kaya: a context catalog takes exactly one anchor";
    catalog.cc_attached <- true;
    List.iter
      (fun m -> emit (the_tx ()) (Kaya_wire.tx_context_attach_node n m))
      catalog.cc_roots

  (* An existing node as a child (the floor's escape into a sugar
     list): the outer zone's [w], template flavor. *)
  let w n () = n
end

(* Register a click handler for a live widget: runs as one
   transaction per click (the ambient tx is set for its extent). *)
let on_click app (Widget id) (handler : unit -> unit) =
  Hashtbl.replace app.widget_handlers id handler

(* Register a click handler for a template node; it also receives the
   stamped copy's keys, outermost first. *)
let on_click_node app (Node id) (handler : key list -> unit) =
  Hashtbl.replace app.node_handlers id (fun keys ->
      handler (List.map key_of_wire keys))

(* Take pasted content at a live widget. *)
let on_paste app (Widget id) (handler : representation -> unit) =
  Hashtbl.replace app.widget_pastes id handler

(* A paste onto a stamped copy: the handler also receives the copy's key
   path, outermost first. *)
let on_paste_node app (Node id)
    (handler : key list -> representation -> unit) =
  Hashtbl.replace app.node_pastes id (fun keys rep ->
      handler (List.map key_of_wire keys) rep)

(* Take dropped content at a live widget, or a reorderable For's
   landings (docs/dnd-plan.md D8). Only fires for a widget that declared
   [set_drop_target] over an accept list. *)
let on_drop app (Widget id) (handler : dropped -> unit) =
  Hashtbl.replace app.widget_drops id handler

(* A drag that began at this widget has ended: [None] is a cancelled or
   refused drag, not an error. *)
let on_drag_ended app (Widget id) (handler : op option -> unit) =
  Hashtbl.replace app.drag_ended_handlers id handler

(* A drop on a stamped copy: the handler also receives the copy's key
   path, outermost first (docs/dnd-plan.md §4). *)
let on_drop_node app (Node id)
    (handler : key list -> dropped -> unit) =
  Hashtbl.replace app.node_drops id (fun keys d ->
      handler (List.map key_of_wire keys) d)

(* A stamped copy of this node — a reorderable row is one — finished its
   drag; the copy's keys first. *)
let on_drag_ended_node app (Node id)
    (handler : key list -> op option -> unit) =
  Hashtbl.replace app.node_drag_ended id (fun keys op ->
      handler (List.map key_of_wire keys) op)

(* Register a change handler for a live entry: the widget owns its text
   and reports each edit here; the app folds it into its own state —
   there is no read-back, by doctrine. *)
let on_change app (Widget id) (handler : string -> unit) =
  Hashtbl.replace app.widget_changes id handler


(* One addressed user edit of a [rich] textarea (docs/rich-text-plan.md
   R1); [~on_change] still fires beside it. The registration twin of
   [textarea ~on_edit], for a handler that reads the widget's own
   [document] and so cannot be written before the widget exists. *)
let on_edit app (Widget id) (handler : edit -> unit) =
  Hashtbl.replace app.widget_edits id handler

(* The user formatted a range; a format over a collapsed caret is
   pending state and arrives as the next edit's runs, never here. *)
let on_format app (Widget id) (handler : format_act -> unit) =
  Hashtbl.replace app.widget_formats id handler

(* A stamped rich copy's edit, with its row's key path outermost first —
   [on_edit] one zone over (docs/rich-text-plan.md §19). The row's
   document field has already taken the act when this fires, so the
   handler reads the ROW and never the widget. *)
let on_edit_node app (Node id)
    (handler : key list -> edit -> unit) =
  Hashtbl.replace app.node_edits id (fun keys e ->
      handler (List.map key_of_wire keys) e)

let on_format_node app (Node id)
    (handler : key list -> format_act -> unit) =
  Hashtbl.replace app.node_formats id (fun keys act ->
      handler (List.map key_of_wire keys) act)

(* The value a live slider's gesture SETTLED ON -- once per release or key
   move, after that gesture's moves (docs/slider-plan.md S2). *)
let on_value_committed app (Widget id) (handler : float -> unit) =
  Hashtbl.replace app.widget_commits id handler

(* A stamped slider's settled value, the copy's keys first. *)
let on_value_committed_node app (Node id)
    (handler : key list -> float -> unit) =
  Hashtbl.replace app.node_commits id (fun keys v ->
      handler (List.map key_of_wire keys) v)


(* Run everything posted, each as its own transaction, in order. *)
let drain_posted app =
  Mutex.lock app.post_lock;
  let batch = app.posted in
  app.posted <- [];
  Mutex.unlock app.post_lock;
  List.iter (fun program -> dispatch app program) batch

(* Turn the decoder's kind-and-values into the sum, or None. *)
let representation_of clip =
  match clip with
  | None -> None
  | Some (kind, values) ->
      let str i =
        match List.nth_opt values i with Some (Kaya_wire.Str s) -> s | _ -> ""
      in
      if kind = Kaya_wire.clip_text then Some (Text (str 0))
      else if kind = Kaya_wire.clip_html then Some (Html (str 0))
      else if kind = Kaya_wire.clip_image then Some (Image (str 0))
      else if kind = Kaya_wire.clip_custom then Some (Custom (str 0, str 1))
      else if kind = Kaya_wire.clip_files then begin
        (* The picker's own three-per-file grouping, so a guest that
           decodes a dialog result decodes this with the same loop. *)
        let rec regroup = function
          | Kaya_wire.I64 h :: Kaya_wire.Str name :: Kaya_wire.Str local_path
            :: rest ->
              { handle = h; name; local_path } :: regroup rest
          | _ -> []
        in
        Some (Files (regroup values))
      end
      else None

(* Cut one undone/redone body into the delta the app is handed. *)
let decode_undo body =
  let byte i = Char.code body.[i] in
  let n_signals = Kaya_wire.u32_at byte 8 in
  let n_texts = Kaya_wire.u32_at byte 12 in
  let n_entries = Kaya_wire.u32_at byte 16 in
  let n_orders = Kaya_wire.u32_at byte 20 in
  let label, at = Kaya_wire.parse_value byte 24 in
  let label = match label with Kaya_wire.Str s -> s | _ -> "" in
  let count = Kaya_wire.u32_at byte at in
  let at = ref (at + 8) in
  let flat = Array.make (max count 1) (Kaya_wire.I64 0L) in
  for i = 0 to count - 1 do
    let v, next = Kaya_wire.parse_value byte !at in
    (* A restored record's blob field (a document's bytes, an image's)
       rides the OCCURRENCE table like a paste's: redeem and release
       here, so the model holds the bytes the record readers expect
       (crates/kaya/src/wire.rs, [undo_body]). *)
    let v =
      match v with Kaya_wire.Blob h -> Kaya_wire.Str (!Kaya_wire.occurrence_blob h) | v -> v
    in
    flat.(i) <- v;
    at := next
  done;
  (* Read position, not a fold: every run below takes what it needs and
     leaves the cursor where the next one starts. *)
  let pos = ref 0 in
  let take () =
    if !pos >= count then failwith "kaya: undo delta is truncated";
    let v = flat.(!pos) in
    incr pos;
    v
  in
  let take_n n =
    let rec go n acc = if n <= 0 then List.rev acc else go (n - 1) (take () :: acc) in
    go n []
  in
  let i64 () = match take () with Kaya_wire.I64 n -> n | _ -> 0L in
  let int () = Int64.to_int (i64 ()) in
  let rec signals n acc =
    if n = 0 then List.rev acc
    else
      let id = i64 () in
      let value = take () in
      signals (n - 1) ({ Undo_signal.id; value } :: acc)
  in
  let rec texts n acc =
    if n = 0 then List.rev acc
    else begin
      let start = !pos in
      (* size, id, path_len — then the path, then the text. [size] counts
         itself, exactly as the two group runs below do, and it is what
         the cursor is advanced by. *)
      let size = int () in
      let id = i64 () in
      let path = take_n (int ()) in
      let text =
        match take_n (start + size - !pos) with
        | [ Kaya_wire.Str s ] -> s
        | _ -> ""
      in
      texts (n - 1)
        ({ Undo_text.id; path = List.map key_of_wire path; text } :: acc)
    end
  in
  let rec entries n acc =
    if n = 0 then List.rev acc
    else begin
      let start = !pos in
      (* size, collection, flags, variant, path_len — then the path, the
         key, and the record's fields. *)
      let size = int () in
      let collection = i64 () in
      let flags = i64 () in
      let variant = int () in
      let path = take_n (int ()) in
      let key = take () in
      let fields = take_n (start + size - !pos) in
      let state =
        (* Bit 0 is "the entry EXISTS"; clear means the state this
           restores does not have it at all. *)
        if Int64.logand flags 1L <> 0L then Some (variant, fields) else None
      in
      entries (n - 1)
        ({
           Undo_entry.collection;
           path = List.map key_of_wire path;
           key = key_of_wire key;
           state;
         }
        :: acc)
    end
  in
  let rec orders n acc =
    if n = 0 then List.rev acc
    else begin
      let start = !pos in
      let size = int () in
      let collection = i64 () in
      let path = take_n (int ()) in
      let keys = take_n (start + size - !pos) in
      orders (n - 1)
        ({
           Undo_order.collection;
           path = List.map key_of_wire path;
           keys = List.map key_of_wire keys;
         }
        :: acc)
    end
  in
  let ud_signals = signals n_signals [] in
  let ud_texts = texts n_texts [] in
  let ud_entries = entries n_entries [] in
  let ud_orders = orders n_orders [] in
  if !pos <> count then failwith "kaya: undo delta has trailing values";
  (label, { Undo_delta.signals = ud_signals; texts = ud_texts; entries = ud_entries; orders = ud_orders })

(* Fold an undo's payload into the collection mirror. The delta's own
   path/key fields are the guest-facing typed [key]; the model
   underneath is keyed by the wire's raw value, so every use here
   converts back at the boundary. *)
let absorb_undo app (delta : Undo_delta.t) =
  List.iter
    (fun (e : Undo_entry.t) ->
      let path = List.map key_to_wire e.path in
      let key = key_to_wire e.key in
      let instances = instances_of app e.collection in
      let instances =
        if List.exists (fun i -> i.path = path) instances then instances
        else instances @ [ { path; entries = [] } ]
      in
      Hashtbl.replace app.model e.collection
        (List.map
           (fun i ->
             if i.path <> path then i
             else
               match e.state with
               | Some state ->
                   if List.mem_assoc key i.entries then
                     {
                       i with
                       entries =
                         List.map
                           (fun (k, v) -> (k, if k = key then state else v))
                           i.entries;
                     }
                   else { i with entries = i.entries @ [ (key, state) ] }
               | None ->
                   { i with entries = List.filter (fun (k, _) -> k <> key) i.entries })
           instances))
    delta.entries;
  List.iter
    (fun (o : Undo_order.t) ->
      let path = List.map key_to_wire o.path in
      let keys = List.map key_to_wire o.keys in
      Hashtbl.replace app.model o.collection
        (List.map
           (fun i ->
             if i.path <> path then i
             else
               (* The payload's order first, then anything it does not
                  name: an entry the delta never mentions is one this
                  step did not touch. *)
               let named =
                 List.filter_map
                   (fun k ->
                     Option.map (fun v -> (k, v)) (List.assoc_opt k i.entries))
                   keys
               in
               let rest =
                 List.filter (fun (k, _) -> not (List.mem k keys)) i.entries
               in
               { i with entries = named @ rest })
           (instances_of app o.collection)))
    delta.orders

let dispatch_loop app =
  (* Claim the thread before the first occurrence: every build after
     this point must happen here. *)
  app_thread := Some (Thread.id (Thread.self ()));
  let rec loop () =
    (* Posted work first, then the ring, then park. Draining at the TOP
       is what makes a wake sufficient: whatever brought this thread
       back, it looks here before anywhere else. *)
    drain_posted app;
    match Kaya_runtime.poll_occurrence () with
    | None ->
        if Kaya_runtime.wait_occurrences () then loop () else () (* shutdown *)
    | Some (kind, id, keys, payload, clip, drop, tail, undo) ->
        (if
           kind = Kaya_wire.occ_kind_draw_requested
           || kind = Kaya_wire.occ_kind_tick
         then
           (* THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER HANDED
              ON (docs/canvas-plan.md §3.2.1): the guest declared a
              drawing as a function of size, so this draws it inside the
              transaction the BINDING opens. The size and a tick's time
              ride as the record's bare trailing values. *)
           (match (Hashtbl.find_opt app.canvas_draws id, tail) with
           | Some handler, Kaya_wire.F64 bw :: Kaya_wire.F64 bh :: rest ->
               let box = (bw, bh) in
               let time =
                 match rest with Kaya_wire.F64 t :: _ -> t | _ -> 0.0
               in
               dispatch app (fun () ->
                   let tx = the_tx () in
                   (* The assigned size is this canvas's viewbox from
                      here on, so a later plain [draw] uses it too. *)
                   Hashtbl.replace tx.app.canvas_viewboxes id box;
                   emit tx
                     (drawing_record id [] box (fun d -> handler d box time)))
           | _ -> ())
         else if kind = Kaya_wire.occ_kind_sort_requested then
           (match (payload, keys) with
           | Some (Kaya_wire.I64 column), [] ->
               (match Hashtbl.find_opt app.sort_handlers id with
               | Some handler ->
                   dispatch app (fun () -> handler (Int64.to_int column))
               | None -> ())
           | Some (Kaya_wire.I64 column), keys ->
               (match Hashtbl.find_opt app.node_sorts id with
               | Some handler ->
                   dispatch app (fun () -> handler keys (Int64.to_int column))
               | None -> ())
           | _ -> ())
         else if kind = Kaya_wire.occ_kind_text_edited then
           (* THE MIRROR IS FOLDED BEFORE THE HANDLER RUNS, so a handler
              reading [document] sees the edit it was told about
              (docs/rich-text-plan.md R1). The tail is source, start,
              stop, the inserted text, then four values per run. *)
           match tail with
           | Kaya_wire.I64 source :: Kaya_wire.I64 start :: Kaya_wire.I64 stop
             :: Kaya_wire.Str inserted :: values ->
               let e : Edit.t =
                 {
                   Edit.range =
                     decoded_span "text_edited" (Int64.to_int start)
                       (Int64.to_int stop);
                   inserted;
                   runs = runs_of_values values;
                   source = Some (edit_source_of_wire (Int64.to_int source));
                 }
               in
               (* A STAMPED COPY FOLDS INTO ITS ROW and a live widget
                  into the mirror, one fold either way
                  (docs/rich-text-plan.md §19). *)
               (match keys with
               | [] ->
                   absorb_edit app id e.range e.inserted e.runs;
                   (match Hashtbl.find_opt app.widget_edits id with
                   | Some handler -> dispatch app (fun () -> handler e)
                   | None -> ())
               | keys ->
                   fold_row_document app id (List.map key_of_wire keys) (fun doc ->
                       fold_edit doc e.range e.inserted e.runs);
                   (match Hashtbl.find_opt app.node_edits id with
                   | Some handler -> dispatch app (fun () -> handler keys e)
                   | None -> ()))
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_text_formatted then
           match tail with
           | Kaya_wire.I64 removed :: Kaya_wire.I64 start :: Kaya_wire.I64 stop
             :: Kaya_wire.Str name :: Kaya_wire.Str value :: _ ->
               let act : Format.t =
                 {
                   Format.range =
                     decoded_span "text_formatted" (Int64.to_int start)
                       (Int64.to_int stop);
                   name;
                   value = (if removed = 0L then Some value else None);
                 }
               in
               (match keys with
               | [] ->
                   absorb_format app id act.range act.name act.value;
                   (match Hashtbl.find_opt app.widget_formats id with
                   | Some handler -> dispatch app (fun () -> handler act)
                   | None -> ())
               | keys ->
                   fold_row_document app id (List.map key_of_wire keys) (fun doc ->
                       fold_format doc act.range act.name act.value);
                   (match Hashtbl.find_opt app.node_formats id with
                   | Some handler -> dispatch app (fun () -> handler keys act)
                   | None -> ()))
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_text_changed then
           match (payload, keys) with
           | Some (Kaya_wire.Str text), [] ->
               (match Hashtbl.find_opt app.widget_changes id with
               | Some handler -> dispatch app (fun () -> handler text)
               | None -> ())
           | Some (Kaya_wire.Str text), keys ->
               (match Hashtbl.find_opt app.node_changes id with
               | Some handler -> dispatch app (fun () -> handler keys text)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_toggled then
           match (payload, keys) with
           | Some (Kaya_wire.Bool checked), [] ->
               (match Hashtbl.find_opt app.widget_toggles id with
               | Some handler -> dispatch app (fun () -> handler checked)
               | None -> ())
           | Some (Kaya_wire.Bool checked), keys ->
               (match Hashtbl.find_opt app.node_toggles id with
               | Some handler -> dispatch app (fun () -> handler keys checked)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_value_changed then
           match (payload, keys) with
           | Some (Kaya_wire.F64 v), [] ->
               (match Hashtbl.find_opt app.widget_values id with
               | Some handler -> dispatch app (fun () -> handler v)
               | None -> ())
           | Some (Kaya_wire.F64 v), keys ->
               (match Hashtbl.find_opt app.node_values id with
               | Some handler -> dispatch app (fun () -> handler keys v)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_value_committed then
           match (payload, keys) with
           | Some (Kaya_wire.F64 v), [] ->
               (match Hashtbl.find_opt app.widget_commits id with
               | Some handler -> dispatch app (fun () -> handler v)
               | None -> ())
           | Some (Kaya_wire.F64 v), keys ->
               (match Hashtbl.find_opt app.node_commits id with
               | Some handler -> dispatch app (fun () -> handler keys v)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_date_changed then
           match (payload, keys) with
           | Some (Kaya_wire.I64 packed), [] ->
               (match Hashtbl.find_opt app.widget_dates id with
               | Some handler -> dispatch app (fun () -> handler packed)
               | None -> ())
           | Some (Kaya_wire.I64 packed), keys ->
               (match Hashtbl.find_opt app.node_dates id with
               | Some handler -> dispatch app (fun () -> handler keys packed)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_time_changed then
           match (payload, keys) with
           | Some (Kaya_wire.I64 packed), [] ->
               (match Hashtbl.find_opt app.widget_times id with
               | Some handler -> dispatch app (fun () -> handler packed)
               | None -> ())
           | Some (Kaya_wire.I64 packed), keys ->
               (match Hashtbl.find_opt app.node_times id with
               | Some handler -> dispatch app (fun () -> handler keys packed)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_close_requested then
           (match Hashtbl.find_opt app.close_requested id with
           | Some handler -> dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_window_closed then (
           (* One-shot: the window is gone; both registrations retire
              with it. *)
           Hashtbl.remove app.close_requested id;
           match Hashtbl.find_opt app.window_closed id with
           | Some handler ->
               Hashtbl.remove app.window_closed id;
               dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_entry_popped then (
           (* One-shot: the entry is gone; both registrations retire
              with it. *)
           Hashtbl.remove app.back_requested id;
           match Hashtbl.find_opt app.entry_popped id with
           | Some handler ->
               Hashtbl.remove app.entry_popped id;
               dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_back_requested then
           (match Hashtbl.find_opt app.back_requested id with
           | Some handler -> dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_sheet_dismissed then (
           (* One-shot: the sheet is gone; both registrations retire
              with it. *)
           Hashtbl.remove app.dismiss_requested id;
           match Hashtbl.find_opt app.sheet_dismissed id with
           | Some handler ->
               Hashtbl.remove app.sheet_dismissed id;
               dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_dismiss_requested then
           (match Hashtbl.find_opt app.dismiss_requested id with
           | Some handler -> dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_section_selected then
           (* NOT one-shot: sections never die, and the user can return any
              number of times (id is the section; the window rides as the
              payload). *)
           (match Hashtbl.find_opt app.section_selected id with
           | Some handler -> dispatch app handler
           | None -> ())
         else if kind = Kaya_wire.occ_kind_alert_result then
           (* One-shot: the registration retires with the result. *)
           (match (Hashtbl.find_opt app.alert_handlers id, payload) with
           | Some handler, Some (Kaya_wire.I64 c) ->
               Hashtbl.remove app.alert_handlers id;
               let picked = Alert_choice.of_wire (Int64.to_int c) in
               dispatch app (fun () -> handler picked)
           | _ -> ())
         else if kind = Kaya_wire.occ_kind_link_opened then
           (* id is the ROUTE the core matched (docs/app-links-plan.md
              §4), and NOT one-shot. The parser flattens the URL and the
              captured pairs into the values slot, so they are regrouped
              in twos after the URL. *)
           let rec regroup = function
             | Kaya_wire.Str name :: Kaya_wire.Str value :: rest ->
                 (name, value) :: regroup rest
             | _ -> []
           in
           (match keys with
           | Kaya_wire.Str url :: pairs -> link_opened app id url (regroup pairs)
           | _ -> ())
         else if kind = Kaya_wire.occ_kind_notification_result then
           (* The outcome rides the same u32 slot the choice does. *)
           notification_result app id
             (Notification_outcome.of_wire
                (match payload with
                | Some (Kaya_wire.I64 o) -> Int64.to_int o
                | _ -> 0))
         else if kind = Kaya_wire.occ_kind_file_dialog_result then
           (* One-shot like the alert, and the id retires with it. The
              parser flattens three values per file into the values
              slot (no single [value] can carry a list), so they are
              regrouped in threes here. EMPTY IS CANCEL. *)
           (match Hashtbl.find_opt app.file_dialog_handlers id with
           | Some handler ->
               let rec regroup = function
                 | Kaya_wire.I64 h :: Kaya_wire.Str name
                   :: Kaya_wire.Str local_path :: rest ->
                     { handle = h; name; local_path } :: regroup rest
                 | _ -> []
               in
               let files = regroup keys in
               Hashtbl.remove app.file_dialog_handlers id;
               dispatch app (fun () -> handler files)
           | None -> ())
         else if kind = Kaya_wire.occ_kind_clipboard_result then
           (* One-shot like the alert, and the request retires with it.
              EMPTY IS THE UNIVERSAL NO and arrives as None — denied,
              unfocused, absent and nothing-we-accept alike, because no
              platform says which. *)
           (match Hashtbl.find_opt app.clipboard_handlers id with
           | Some handler ->
               let answer = representation_of clip in
               Hashtbl.remove app.clipboard_handlers id;
               dispatch app (fun () -> handler answer)
           | None -> ())
         else if kind = Kaya_wire.occ_kind_pasted then
           (* A paste rides a click tag verbatim, so it arrives on the
              ordinary widget/node split — one record kind, the key path
              deciding. *)
           (match (representation_of clip, keys) with
           | None, _ -> ()
           | Some rep, [] ->
               (match Hashtbl.find_opt app.widget_pastes id with
               | Some handler -> dispatch app (fun () -> handler rep)
               | None -> ())
           | Some rep, keys ->
               (match Hashtbl.find_opt app.node_pastes id with
               | Some handler -> dispatch app (fun () -> handler keys rep)
               | None -> ()))
         else if kind = Kaya_wire.occ_kind_dropped then
           (* A drop rides the same tag with four more words
              (docs/dnd-plan.md D1), so it arrives on the ordinary
              widget/node split — a stamped copy's landing and a
              reorderable row's own drag_ended carry the copy's keys. *)
           (match drop with
           | None -> ()
           | Some d ->
               let answer =
                 {
                   point = (d.Kaya_wire.dv_x, d.Kaya_wire.dv_y);
                   operation = operation_of d.Kaya_wire.dv_operation;
                   anchor = List.map key_of_wire d.Kaya_wire.dv_anchor;
                   before = d.Kaya_wire.dv_before;
                   clip =
                     representation_of
                       (Some (d.Kaya_wire.dv_clip, d.Kaya_wire.dv_values));
                 }
               in
               if keys = [] then
                 match Hashtbl.find_opt app.widget_drops id with
                 | Some handler -> dispatch app (fun () -> handler answer)
                 | None -> ()
               else
                 match Hashtbl.find_opt app.node_drops id with
                 | Some handler -> dispatch app (fun () -> handler keys answer)
                 | None -> ())
         else if kind = Kaya_wire.occ_kind_drag_ended then
           (match payload with
           | Some (Kaya_wire.I64 mask) ->
               let answer = operation_of (Int64.to_int mask) in
               if keys = [] then (
                 match Hashtbl.find_opt app.drag_ended_handlers id with
                 | Some handler -> dispatch app (fun () -> handler answer)
                 | None -> ())
               else (
                 match Hashtbl.find_opt app.node_drag_ended id with
                 | Some handler -> dispatch app (fun () -> handler keys answer)
                 | None -> ())
           | _ -> ())
         else if
           kind = Kaya_wire.occ_kind_undone || kind = Kaya_wire.occ_kind_redone
         then
           (* ONE STEP CAME BACK, and this record is the whole of what
              the app hears: applying an inverse is programmatic, so the
              echo doctrine silences everything it did. NOT one-shot: a
              history is walked as often as the user likes. *)
           (match undo with
           | None -> ()
           | Some body ->
               let label, delta = decode_undo body in
               absorb_undo app delta;
               let table =
                 if kind = Kaya_wire.occ_kind_undone then app.undone_handlers
                 else app.redone_handlers
               in
               (match Hashtbl.find_opt table id with
               | Some handler -> dispatch app (fun () -> handler label delta)
               | None -> ()))
         else if kind = Kaya_wire.occ_kind_menu_activated then
           (* Menu occurrences key the menu-item tables — their own id
              space. Node-anchored context items carry the stamped copy's
              keys; toggles carry the state, radio groups the index. *)
           (match keys with
           | [] ->
               (match Hashtbl.find_opt app.menu_activated id with
               | Some handler -> dispatch app handler
               | None -> ())
           | keys ->
               (match Hashtbl.find_opt app.menu_activated_node id with
               | Some handler -> dispatch app (fun () -> handler keys)
               | None -> ()))
         else if kind = Kaya_wire.occ_kind_menu_toggled then
           (match (payload, keys) with
           | Some (Kaya_wire.Bool checked), [] ->
               (match Hashtbl.find_opt app.menu_toggled id with
               | Some handler -> dispatch app (fun () -> handler checked)
               | None -> ())
           | Some (Kaya_wire.Bool checked), keys ->
               (match Hashtbl.find_opt app.menu_toggled_node id with
               | Some handler -> dispatch app (fun () -> handler keys checked)
               | None -> ())
           | _ -> ())
         else if kind = Kaya_wire.occ_kind_menu_value_changed then
           (match (payload, keys) with
           | Some (Kaya_wire.F64 v), [] ->
               (match Hashtbl.find_opt app.menu_selected id with
               | Some handler ->
                   dispatch app (fun () -> handler (int_of_float v))
               | None -> ())
           | Some (Kaya_wire.F64 v), keys ->
               (match Hashtbl.find_opt app.menu_selected_node id with
               | Some handler ->
                   dispatch app (fun () -> handler keys (int_of_float v))
               | None -> ())
           | _ -> ())
         else
           match keys with
           | [] ->
               (match Hashtbl.find_opt app.widget_handlers id with
               | Some handler -> build app handler
               | None -> ())
           | keys ->
               (match Hashtbl.find_opt app.node_handlers id with
               | Some handler -> dispatch app (fun () -> handler keys)
               | None -> ()));
        loop ()
  in
  loop ()

(* Enter the core on the calling thread (must be the process main
   thread), dispatching occurrences on the app thread; returns the exit
   code. *)
let run app =
  let app_thread = Thread.create dispatch_loop app in
  let code = Kaya_runtime.run () in
  Thread.join app_thread;
  code
