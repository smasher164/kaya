(* kaya's idiomatic surface for OCaml: the structural core, over the runtime
   (kaya_runtime.ml) and the generated wire vocabulary (kaya_wire.ml). THE
   TEMPLATE ZONE IS THE Tpl SUBMODULE. OCaml has no overloading, so the
   module path spells the zone. THE TRANSACTION IS AMBIENT: [build] (and
   each handler dispatch) sets it for its extent and every builder reads it,
   so plain [let] and [;] compose scenes. The price is that "declared
   outside a transaction" is a loud RUNTIME error rather than a type error
   (see [the_tx]). THE TRAILING-UNIT CONVENTION: every creator ends in [()].
   Apply it to realize a widget where you stand; OMIT it and the partial
   application is a pure [unit -> widget] thunk, which is the child form
   containers take in lists and realize left to right ([List.iter]'s
   specified order, so document order never rides on OCaml's unspecified
   list-literal evaluation order). *)

type signal = Signal of int64
type widget = Widget of int64
type node = Node of int64

(* WHAT THIS HOST CAN DO — see crates/kaya/src/app.rs for the canonical
   note, which every binding's copy of this surface shortens. *)
type capabilities = { aux_windows : bool }

(* This host's capabilities. Constant for the life of the process, so
   asking once and remembering is fine. *)
let capabilities () =
  let bits = Kaya_runtime.capability_bits () in
  { aux_windows = Int64.logand bits Kaya_runtime.cap_aux_windows <> 0L }

(* A live menu item: its OWN id space (the c_menu_item counter) behind its
   own constructor, so cross-use with widget or node handles is a type
   error. *)
type menu_item = MenuItem of int64

(* A context catalog built UNANCHORED ([context_catalog]) for a template
   node: menu items are live and shared across stamped copies, so the
   catalog is built in the live zone and [Tpl.context_menu] attaches it
   inside the template, where each activation carries the copy's key path. *)
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

(* One file the picker answered with: a handle to redeem, a display
   name, and [local_path] — a RE-OPENABLE NAME, empty unless
   re-opening it actually works, which measurement puts at the three
   desktops and neither phone (DESIGN.md, File dialogs). *)
type picked_file = { handle : int64; name : string; local_path : string }

(* AN ASSET — a file this app's own BUILD put where the running program
   can find it (docs/assets-plan.md). [asset "fonts/sora-wght.ttf"]
   opens one; the name is a relative path under a root the CORE
   resolves, and no guest reads an asset environment variable or carries
   a repo-relative default (tools/check-assets.sh).

   A MISS RAISES [Failure] carrying the core's sentence and nothing
   added, so an OCaml guest and a Java guest name the fault in the same
   words. EACH CALL READS: no cache, no watch, no reload. Release is
   explicit ([asset_close]) and automatic (a [Gc.finalise] per handle).

   In OCaml the byte value IS the reader — there is no in-memory-channel
   wrapper, which is the stated carve-out (DESIGN.md, Binding
   conventions). *)
type asset = Kaya_runtime.asset

let asset = Kaya_runtime.open_asset

(* Why [asset name] would raise — the sentence it would carry, handed
   over without raising. [""] means the name resolves. LINE 1 (name,
   rule, census) is the same on every platform and is the line a scene
   freezes; line 2 names the resolved place, which three platforms spell
   three ways. Authored by [asset_why_not] in
   crates/kaya/src/assets.rs. *)
let asset_miss_sentence = Kaya_runtime.asset_miss_sentence
let asset_bytes = Kaya_runtime.asset_bytes
let asset_close = Kaya_runtime.asset_close

(* One representation, arriving — the sum a copy is the record of.
   Bytes ride as [string], OCaml's own binary buffer. [Image] may be a
   RE-ENCODE of what was copied, so compare what the image IS, never the
   bytes it arrived in. *)
(* One collection entry's restored state, as the core states it. *)
type undo_entry = {
  ue_collection : int64;
  (* The instance path: one key per enclosing For, empty at top level. *)
  ue_path : Kaya_wire.value list;
  ue_key : Kaya_wire.value;
  ue_state : (int * Kaya_wire.value list) option;
}

(* One collection instance's restored key order — present only for the
   instances whose order the step changed, because position is the one
   thing per-entry statements cannot carry. *)
type undo_order = {
  uo_collection : int64;
  uo_path : Kaya_wire.value list;
  uo_keys : Kaya_wire.value list;
}

(* One text field's restored contents, and the FIELD'S OWN NAME beside
   it. [ut_path] EMPTY means [ut_id] is a live widget's id; a non-empty
   path means it is a TEMPLATE NODE's id and the path is the stamped
   copy's keys, outermost first. *)
type undo_text = {
  ut_id : int64;
  ut_path : Kaya_wire.value list;
  ut_text : string;
}

(* WHAT THE CORE PUT BACK, and a STATEMENT of it rather than a replay of
   ops: every run says what a thing now IS, so applying it twice is the same
   as applying it once. APPLYING AN INVERSE EMITS NOTHING ELSE (the echo
   doctrine), so this is the ONLY thing an app hears about the step. *)
type undo_delta = {
  ud_signals : (int64 * Kaya_wire.value) list;
  ud_texts : undo_text list;
  ud_entries : undo_entry list;
  ud_orders : undo_order list;
}

type representation =
  | Text of string
  | Html of string
  | Image of string
  | Files of picked_file list
  | Custom of string * string

type app = {
  (* Work handed over by other threads, waiting to run as transactions
     on the app thread. THE ONLY FIELD HERE TOUCHED FROM ANOTHER
     THREAD, and the only reason this record carries a mutex at all —
     everything else is app-thread-only by construction. *)
  post_lock : Mutex.t;
  mutable posted : (unit -> unit) list;
  mutable c_signal : int64;
  mutable c_widget : int64;
  mutable c_collection : int64;
  mutable c_node : int64;
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
     separate from every widget/node table ("two tables, always" — now
     N tables, still always). The node flavors receive the stamped
     copy's key path (the keys ARE the noun). *)
  menu_activated : (int64, unit -> unit) Hashtbl.t;
  menu_activated_node : (int64, Kaya_wire.value list -> unit) Hashtbl.t;
  menu_toggled : (int64, bool -> unit) Hashtbl.t;
  menu_toggled_node : (int64, Kaya_wire.value list -> bool -> unit) Hashtbl.t;
  menu_selected : (int64, int -> unit) Hashtbl.t;
  menu_selected_node : (int64, Kaya_wire.value list -> int -> unit) Hashtbl.t;
  node_handlers : (int64, Kaya_wire.value list -> unit) Hashtbl.t;
  widget_changes : (int64, string -> unit) Hashtbl.t;
  node_changes : (int64, Kaya_wire.value list -> string -> unit) Hashtbl.t;
  widget_toggles : (int64, bool -> unit) Hashtbl.t;
  widget_values : (int64, float -> unit) Hashtbl.t;
  (* Window lifecycle: one handler each, receiving the window id. *)
  close_requested : (int64, unit -> unit) Hashtbl.t;
  entry_popped : (int64, unit -> unit) Hashtbl.t;
  back_requested : (int64, unit -> unit) Hashtbl.t;
  section_selected : (int64, unit -> unit) Hashtbl.t;
  alert_handlers : (int64, int -> unit) Hashtbl.t;
  mutable next_alert : int64;
  file_dialog_handlers : (int64, picked_file list -> unit) Hashtbl.t;
  mutable next_file_dialog : int64;
  (* Clipboard reads share the alert's request/result grammar and so
     its table shape: one-shot, keyed by request id. *)
  clipboard_handlers : (int64, representation option -> unit) Hashtbl.t;
  mutable next_clipboard_read : int64;
  widget_pastes : (int64, representation -> unit) Hashtbl.t;
  node_pastes : (int64, Kaya_wire.value list -> representation -> unit) Hashtbl.t;
  window_closed : (int64, unit -> unit) Hashtbl.t;
  (* The history, per window and NOT one-shot: a history is walked as often
     as the user likes, so these outlive every step (the section_selected
     stance, not the alert's). *)
  undone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  redone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  node_toggles : (int64, Kaya_wire.value list -> bool -> unit) Hashtbl.t;
  (* A stamped slider's move and a stamped choice's pick, the node flavor of
     [widget_values]. *)
  node_values : (int64, Kaya_wire.value list -> float -> unit) Hashtbl.t;
  (* The collection is the model — the only copy: every mutation op edits it
     and queues the wire delta in the same call, so reads (items, count) are
     exactly the writes. *)
  model : (int64, instance list) Hashtbl.t;
  (* The minter's counters: the highest I64 key each collection
     INSTANCE has minted or absorbed, keyed by path the way [model] is
     (a path is a [value list], and a [value] carries a float, so it is
     compared structurally here exactly as instances are). Kept on the
     app and NOT in the transaction's rollback journal, on purpose —
     see [insert_fresh]: the journal restores the model, never the
     counter, so a key spent by an abandoned transaction stays spent. *)
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
}

(* One transaction: everything queued inside build (or a handler) applies
   atomically when it returns. *)
and tx = {
  app : app;
    mutable records : string list;
  (* The undo group's (window, label), kept OUT of [records] because it
     rides at the HEAD of the batch wherever [undoable] was called: a
     handler builds first and names the step once it knows what the step
     was, and the wire's head-of-batch rule must not turn that into a
     footgun. *)
  mutable undo_group : (int64 * string) option;
  mutable journal : (int64 * instance list) list;
  (* Deriveds registered in this transaction: promoted to the app
     registry on submit, abandoned with a rolled-back tx (their signals
     were never created). *)
  mutable pending_derived : (int64 * (unit -> unit)) list;
}

(* The ambient transaction: set for the extent of [build] (handler dispatch
   runs through build, so handlers get it too). Builders read it instead of
   threading a reader, so plain [let] and [;] compose scenes — the let*/decl
   reader retired with this (ratified 2026-07-22). *)
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
    c_node = 0L;
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
    widget_toggles = Hashtbl.create 8;
    widget_values = Hashtbl.create 8;
    close_requested = Hashtbl.create 8;
    entry_popped = Hashtbl.create 8;
    back_requested = Hashtbl.create 8;
    section_selected = Hashtbl.create 8;
    alert_handlers = Hashtbl.create 8;
    next_alert = 0L;
    file_dialog_handlers = Hashtbl.create 4;
    next_file_dialog = 0L;
    clipboard_handlers = Hashtbl.create 4;
    next_clipboard_read = 0L;
    widget_pastes = Hashtbl.create 4;
    node_pastes = Hashtbl.create 4;
    window_closed = Hashtbl.create 8;
    undone_handlers = Hashtbl.create 4;
    redone_handlers = Hashtbl.create 4;
    node_toggles = Hashtbl.create 8;
    node_values = Hashtbl.create 8;
    model = Hashtbl.create 8;
    fresh = Hashtbl.create 8;
    children = Hashtbl.create 8;
    open_fors = [];
    tpl_depth = 0;
    derived = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records

let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

(* One instance's fresh-key counter, made if this is the first anyone has
   asked. *)
let counter_of app cid path =
  let instances = Option.value ~default:[] (Hashtbl.find_opt app.fresh cid) in
  match List.assoc_opt path instances with
  | Some counter -> counter
  | None ->
      let counter = ref 0L in
      Hashtbl.replace app.fresh cid (instances @ [ (path, counter) ]);
      counter

(* The next fresh key for one instance: counter+1, and the counter keeps it. *)
let mint_key app cid path =
  let counter = counter_of app cid path in
  counter := Int64.add !counter 1L;
  !counter

(* An explicit key, shown to the minter on its way into the table. *)
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

(* Every derived signal rooted at this collection, recomputed and written
   into this transaction. *)
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
      (* The group marker leads the batch, whatever order the program
         wrote it in — the wire has no header for per-transaction
         metadata, so head-of-batch is the one position that cannot be
         ambiguous. *)
      let records =
        match tx.undo_group with
        | Some (window, label) ->
            Kaya_wire.tx_undo_group window (Kaya_wire.Str label)
            :: List.rev tx.records
        | None -> List.rev tx.records
      in
      if records <> [] then Kaya_runtime.submit records;
      result
  | exception e ->
      restore ();
      List.iter (fun (cid, saved) -> Hashtbl.replace app.model cid saved) tx.journal;
      raise e

(* One handler dispatch: an exception crosses the build boundary
   (which restored the model and dropped the records), is logged, and
   the loop moves to the next occurrence -- the uniform dispatch
   discipline across every binding. *)
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

let dispatch app (program : unit -> unit) =
  try build app program
  with e ->
    Printf.eprintf "kaya: handler raised (transaction rolled back): %s\n%!"
      (Printexc.to_string e)

(* Make this transaction ONE undoable step, under [label] (docs/undo-plan.md
   D2). CALLABLE ANYWHERE IN THE TRANSACTION and the marker still rides at
   the HEAD of the batch: the transaction is the unit, so where the call
   sits changes nothing. WHAT A GROUP MAY HOLD is the reactive half — signal
   writes and collection deltas. *)
let undoable ?(window = 0L) label =
  let tx = the_tx () in
  if tx.undo_group <> None then
    failwith "kaya: this transaction is already an undo group — one name per step";
  tx.undo_group <- Some (window, label)

let signal initial =
  let tx = the_tx () in
  tx.app.c_signal <- Int64.add tx.app.c_signal 1L;
  let id = tx.app.c_signal in
  emit tx (Kaya_wire.tx_create_signal id initial);
  Signal id

let write (Signal id) value = emit (the_tx ()) (Kaya_wire.tx_write_signal id value)

let widget kind =
  let tx = the_tx () in
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_widget id kind);
  Widget id

(* A widget's text: a button's caption, a label's line — and, on the
   uncontrolled text widgets, the "open a document into the editor"
   write. One write, after which the user owns the field again.

   A write that CHANGES a textarea's text DROPS whatever ranges were
   declared over it (see [highlight_ranges]) and spends the field's
   native undo history, which is why undo's D7 treats it as an episode
   boundary. *)
let set_text (Widget id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

(* Set a widget's flex weight within its row/column: 0 is natural size,
   positive weights divide the container's leftover main-axis space in
   proportion (see Prop::Grow in the core). *)
let set_grow (Widget id) weight = emit (the_tx ()) (Kaya_wire.tx_set_grow id weight)

(* A widget's accessibility IDENTIFIER: a stable authored key that assistive
   tooling and UI automation address it by, and which is NEVER spoken. *)
let set_a11y_id (Widget id) value = emit (the_tx ()) (Kaya_wire.tx_set_a11y_id id value)

(* What an assistive client SPEAKS for a widget. Universal, and deliberately
   separate from the identifier — an automation key is not a spoken name.
   Leave it unset to keep whatever the platform derives from the control's
   own content; setting it OVERRIDES that, so a button whose caption already
   reads well needs nothing here. *)
let set_a11y_label (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_label id value)

(* What ACTIVATING this widget does — the platforms' hint (Apple defines it
   as the result of performing an action; Android carries it as the click
   action's label). Write a VERB PHRASE. *)
let set_a11y_hint (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_hint id value)

(* The two universal props as they ride every constructor: applied
   together, in one place, so a new constructor cannot pick up [~grow]
   and quietly miss these. *)
let set_a11y ?a11y_id ?a11y_label w =
  Option.iter (fun v -> set_a11y_id w v) a11y_id;
  Option.iter (fun v -> set_a11y_label w v) a11y_label

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

(* SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
   never how it looks. [Destructive] and [Prominent] are an ACTION's
   emphasis — what pressing it does to the user's data, and which of a
   surface's actions is THE one — so they belong to a button and nothing
   else. [Heading] is a text hierarchy fact: the platform's own heading
   text style AND the trait assistive users skim a screen by, which is
   why it is a role and not a font size. *)
type role = Destructive | Prominent | Heading

let role_wire = function
  | Destructive -> Int64.of_int Kaya_wire.role_destructive
  | Prominent -> Int64.of_int Kaya_wire.role_prominent
  | Heading -> Int64.of_int Kaya_wire.role_heading

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
   "platform"; docs/styling-plan.md Slice 2b): one entry per backend
   roster row, closed like [role] and [symbol] above.

   AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS, and there is no
   [current]: OCaml cannot answer that question — [Sys.os_type] is "Unix"
   for macOS, Linux, iOS and Android alike. Every row travels to every
   backend and each LOWERING picks its own. *)
type platform = Mac | Ios | Linux | Windows | Android

let platform_wire = function
  | Mac -> Int64.of_int Kaya_wire.platform_mac
  | Ios -> Int64.of_int Kaya_wire.platform_ios
  | Linux -> Int64.of_int Kaya_wire.platform_linux
  | Windows -> Int64.of_int Kaya_wire.platform_windows
  | Android -> Int64.of_int Kaya_wire.platform_android

let bind_text (Widget id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_text id s)
let set_checked (Widget id) checked = emit (the_tx ()) (Kaya_wire.tx_set_checked id checked)
let bind_checked (Widget id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_checked id s)

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

let bind_source (Widget id) (Signal s) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_bind_source id s)

(* One-shot commands: momentary verbs into widget-owned state, riding the
   open transaction like any record — the insert and the clear beside it
   submit together or not at all. *)

(* Drop an entry's content now (the field stays authoritative). *)
let clear (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_clear)

(* Give this widget the keyboard focus. *)
let focus (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_focus)

(* --- Text ranges: the three primitives an editor cannot write itself -

   A RANGE IS A PAIR OF UTF-8 BYTE OFFSETS [(start, stop)] into the
   widget's current text, half-open. OCaml's [string] IS a byte sequence,
   so the offsets an app already has are the offsets kaya wants and this
   binding converts nothing. The offsets are [int], not [int64], because
   an offset is arithmetic the APP does with the stdlib.

   THE CORE VALIDATES AND REFUSES at one chokepoint before any of this
   reaches a platform ([start <= stop], inside the text, both endpoints
   on a code-point boundary). A malformed offset gets loud treatment
   because macOS ABORTS THE PROCESS on one (crates/kaya/src/spec.rs;
   docs/traps.md). An endpoint inside a grapheme cluster is NOT
   refused. *)

(* DECLARE the decorated ranges of a textarea, replacing whatever was
   declared before; [[]] is the clear. APP-OWNED AND NEVER TRACKED
   (docs/ranges-plan.md D2): the first edit of any kind DROPS the set, with
   nothing said, and the app re-declares from the fold [~on_change] already
   drives. *)
let highlight_ranges (Widget id) ranges =
  emit (the_tx ())
    (Kaya_wire.tx_highlight_ranges id (List.length ranges)
       (List.concat_map
          (fun (start, stop) ->
            [ Kaya_wire.I64 (Int64.of_int start); Kaya_wire.I64 (Int64.of_int stop) ])
          ranges))

(* Put the textarea's selection at one range; [(at, at)] is a caret.
   REFUSED WHILE THE USER IS COMPOSING through an input method, in every
   backend (D4), and the refusal is a NO-OP rather than an exception:
   composition state is on no kaya channel, so an app cannot avoid the
   race. Ask again after the next [~on_change]. *)
let select_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_select_range id (Int64.of_int start) (Int64.of_int stop))

(* Scroll the textarea so a range is inside the viewport. A PURE EFFECT: no
   state moves, the selection is untouched, and undo does not put the scroll
   back — undo restores state, not where you were looking. *)
let reveal_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_reveal_range id (Int64.of_int start) (Int64.of_int stop))

let add_child (Widget parent) (Widget child) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_child parent child)

(* --- Construction sugar: the tree reads as a tree ------------------- *)

let button ?grow ?a11y_id ?a11y_label ?a11y_hint ?role ?text ?on_click () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_button in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  (* [Destructive] or [Prominent]; a [Heading] button dies at the root. *)
  Option.iter (fun r -> set_role w r) role;
  Option.iter (fun t -> set_text w t) text;
  (match on_click with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_handlers id handler
  | None -> ());
  w

(* A multi-line text editor: the entry's uncontrolled contract over
   the platform's real multi-line editor. *)
let textarea ?grow ?a11y_id ?a11y_label ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_textarea in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

let label ?grow ?a11y_id ?a11y_label ?role ?text ?bind () =
  let w = widget Kaya_wire.kind_label in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  (* [Heading] is the label's role; the two button emphases die here. *)
  Option.iter (fun r -> set_role w r) role;
  Option.iter (fun t -> set_text w t) text;
  Option.iter (fun s -> bind_text w s) bind;
  w

let entry ?grow ?a11y_id ?a11y_label ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_entry in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

(* A progress bar: display-only, like label and image. [~value] is
   the determinate fraction (0..=1); [~indeterminate:true] switches
   to the platform's activity mode. *)
let progress ?grow ?a11y_id ?a11y_label ?(value = 0.0) ?indeterminate () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_progress in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_value id value);
  Option.iter (fun i -> emit tx (Kaya_wire.tx_set_indeterminate id i)) indeterminate;
  w

(* A slider over min..max at value. Uncontrolled, like the entry: the bar
   owns its position and reports each change to [on_change] (the new value
   as a float). *)
let slider ?grow ?a11y_id ?a11y_label ?(min = 0.0) ?(max = 1.0) ?(value = 0.0) ?bind
    ?on_change () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_slider in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_min id min);
  emit tx (Kaya_wire.tx_set_max id max);
  (match bind with
  | Some (Signal s) -> emit tx (Kaya_wire.tx_bind_value id s)
  | None -> emit tx (Kaya_wire.tx_set_value id value));
  (match on_change with
  | Some handler -> Hashtbl.replace tx.app.widget_values id handler
  | None -> ());
  w

(* A dropdown select over fixed [options] — each option becomes a
   label child (labels only, scene-checked) — at [~selected], the
   initial 0-based index (domain-checked at the root against the
   option count). Uncontrolled, like the slider: [~on_select]
   receives each USER pick's new 0-based index (programmatic writes
   never echo). *)
let select ?grow ?a11y_id ?a11y_label ?a11y_hint ?(selected = 0) ?on_select options () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_select in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
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
let radio ?grow ?a11y_id ?a11y_label ?a11y_hint ?(selected = 0) ?on_select options () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_radio in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
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

let checkbox ?grow ?a11y_id ?a11y_label ?a11y_hint ?text ?checked ?on_toggle () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_checkbox in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
  Option.iter (fun t -> set_text w t) text;
  Option.iter (fun c -> set_checked w c) checked;
  (match on_toggle with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_toggles id handler
  | None -> ());
  w

(* An image displaying encoded bytes (PNG, JPEG, ...): the toolkit decodes
   natively, and decode failure renders the placeholder, never a crash.
   [~source] ships the bytes and [~source_asset] the same slot with the
   picture NAMED rather than read (the bytes never enter the OCaml heap).
   The two are EXCLUSIVE — naming both is refused, [~font]/[~font_asset]'s
   rule verbatim. *)
let image ?grow ?a11y_id ?a11y_label ?source ?source_asset ?bind () =
  let w = widget Kaya_wire.kind_image in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
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

(* A container from its children. A child is a PARTIALLY APPLIED
   creator — every creator ends in [()], and omitting that unit
   leaves a pure [unit -> widget] thunk, so the child list literal
   only allocates closures (OCaml's unspecified literal evaluation
   order cannot reorder anything observable). The container realizes
   the thunks itself, left to right — [List.iter]'s specified order
   IS document order — attaching each result. The trailing unit is
   the convention's hinge: write [()] to realize a widget where you
   stand, omit it to hand the creator to a container. Construction
   props are labeled optional arguments, the lablgtk idiom: [~grow]
   weights the container within ITS parent, [~spacing] sets its own
   inter-child gap, [~inset] its own padding. *)
let container ?grow ?a11y_id ?a11y_label ?spacing ?align ?inset kind children () =
  let parent = widget kind in
  Option.iter (fun g -> set_grow parent g) grow;
  set_a11y ?a11y_id ?a11y_label parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun a -> set_align parent a) align;
  Option.iter (fun p -> set_inset parent p) inset;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A grid from its children, laid out row-major into [~columns]
   columns — each column takes its NATURAL width, aligned across rows
   (the thing nested rows cannot express). [~spacing] is the
   inter-cell gap on both axes. The columns record lands BEFORE the
   add_childs (backends re-flow either way). *)
let grid ~columns ?grow ?a11y_id ?a11y_label ?spacing ?inset children () =
  let tx = the_tx () in
  let parent = widget Kaya_wire.kind_grid in
  let (Widget id) = parent in
  emit tx (Kaya_wire.tx_set_columns id (float_of_int columns));
  Option.iter (fun g -> set_grow parent g) grow;
  set_a11y ?a11y_id ?a11y_label parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun p -> set_inset parent p) inset;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A spacer: PURE SUGAR for an empty grown column — it consumes the
   leftover main-axis space between its siblings. *)
let spacer ?(grow = 1.0) () =
  let w = widget Kaya_wire.kind_column in
  set_grow w grow;
  w

let column ?grow ?a11y_id ?a11y_label ?spacing ?align ?inset children =
  container ?grow ?a11y_id ?a11y_label ?spacing ?align ?inset Kaya_wire.kind_column
    children

(* A vertical scroll viewport over EXACTLY ONE child (the signature
   says so; the scene enforces it too). Pass [~grow] so the enclosing
   track CONSTRAINS it — an unconstrained viewport hugs its content
   and nothing overflows. *)
let scroll ?grow ?a11y_id ?a11y_label children =
  container ?grow ?a11y_id ?a11y_label Kaya_wire.kind_scroll children

let row ?grow ?a11y_id ?a11y_label ?spacing ?align ?inset children =
  container ?grow ?a11y_id ?a11y_label ?spacing ?align ?inset Kaya_wire.kind_row
    children

(* An existing widget as a child: [w field] wraps an already-realized
   handle in an inert thunk, so a widget created earlier (because
   handlers needed its handle first) slots into a child list — the
   container merely attaches it. *)
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
let at c key = { c with cpath = c.cpath @ [ key ] }

(* A For binds the collection itself — its template stamps per entry of
   every instance — so handing it an [at] handle is a bug. *)
let assert_root c =
  if c.cpath <> [] then
    invalid_arg "kaya: for_each binds the collection itself, not an instance — drop the at"

let insert c key value =
  let tx = the_tx () in
  (* ABSORPTION, on the one path every explicit key of a scalar
     collection travels: a numeric key at or above the minter's counter
     carries it up, so hand-chosen and minted keys share one space
     safely and in either order ([insert_fresh]'s contract). *)
  absorb_key tx.app c.cid c.cpath key;
  model_set tx c.cid c.cpath key 0 [ value ];
  emit tx (Kaya_wire.tx_collection_insert c.cid c.cpath key 0 [ value ]);
  recompute_derived tx c.cid c.cpath

(* Insert a value under a key the binding authors, and hand the key back
   — [let key = insert_fresh todos (Str draft)].

   ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key is
   [I64] and is counter+1. MIXING IS SAFE BY ABSORPTION: an explicit
   [insert] whose key is an [I64] at or above the counter carries it up.
   NO DECREMENT IS EXPRESSIBLE — a history walk never moves the counter,
   and an abandoned transaction does not move it back either (the
   rollback journal restores the model, not the counter). *)
let insert_fresh c value =
  let tx = the_tx () in
  let key = mint_key tx.app c.cid c.cpath in
  insert c (Kaya_wire.I64 key) value;
  key

let update c key value =
  let tx = the_tx () in
  model_set tx c.cid c.cpath key 0 [ value ];
  emit tx (Kaya_wire.tx_collection_update c.cid c.cpath key 0 [ value ]);
  recompute_derived tx c.cid c.cpath

let remove c key =
  let tx = the_tx () in
  model_remove tx c.cid c.cpath key;
  emit tx (Kaya_wire.tx_collection_remove c.cid c.cpath key);
  recompute_derived tx c.cid c.cpath

let entry_keys tx cid path =
  match List.find_opt (fun i -> i.path = path) (instances_of tx.app cid) with
  | Some i -> List.map fst i.entries
  | None -> []

(* The same checks the scene makes, made where the guest can see the stack:
   a missing key or anchor is a guest bug, never a fallback. *)
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

(* Reposition an entry before another's: order is collection data, so the
   model reorders and the wire carries the same keys-only delta. *)
let move_before c key anchor = move_entry c key (Some anchor)

(* Reposition an entry at the end of its collection. *)
let move_to_end c key = move_entry c key None

(* Reposition an entry at the front: sugar for move_before the current
   first key, lowering to the same wire op. *)
let move_to_front c key =
  let tx = the_tx () in
  match entry_keys tx c.cid c.cpath with
  | [] -> invalid_arg "kaya: move of missing key"
  | first :: _ -> move_entry c key (Some first)

(* Reposition an entry directly after another's: sugar for move_before
   the anchor's successor (move_to_end when the anchor is last),
   lowering to the same wire op. *)
let move_after c key anchor =
  let tx = the_tx () in
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
let items c =
  let tx = the_tx () in
  guard_mirror_read ();
  match List.find_opt (fun i -> i.path = c.cpath) (instances_of tx.app c.cid) with
  | Some i -> List.map (fun (k, (_, vs)) -> (k, List.hd vs)) i.entries
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

(* A blob field's MODEL value carries the guest's own bytes (as a
   binary Str — OCaml strings are byte sequences), so record_items
   reads back exactly what was written; the wire side registers a
   fresh copy with the core at encode time (see encode_field). *)
let blob_field index : ('a, bytes) field =
  { fd_index = index; fd_to_value = (fun d -> Kaya_wire.Str (Bytes.to_string d)) }

(* The model-to-wire crossing for one record field: scalars pass
   through; a blob field's model value (the guest's bytes) registers a
   fresh copy with the core here, at encode time — handles are
   single-submit, so insert, update, and update_field each re-register
   (one copy into core memory per write; the model keeps the guest's
   own bytes). *)
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

let insert_record rc key value =
  let tx = the_tx () in
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
  insert_record rc (Kaya_wire.I64 key) value;
  key

let update_record rc key value =
  let tx = the_tx () in
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 fields;
  emit tx
    (Kaya_wire.tx_collection_update rc.rc_handle.cid rc.rc_handle.cpath key 0
       (encode_fields rc.rc_type.rt_schema fields));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* One field's delta: the rest of the record never travels; the
   model's copy updates the same slot. *)
let update_field rc key fd value =
  let tx = the_tx () in
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
let record_items rc =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt (fun i -> i.path = rc.rc_handle.cpath) (instances_of tx.app rc.rc_handle.cid)
  with
  | Some i -> List.map (fun (k, (_, vs)) -> (k, rc.rc_type.rt_of_values vs)) i.entries
  | None -> []

(* A signal recomputed from this collection's entries after every mutation,
   written into the same transaction — the items-left label with no handler
   remembering to update it. *)
let derive rc compute =
  let tx = the_tx () in
  let s = signal (compute (record_items rc)) in
  tx.pending_derived <-
    (rc.rc_handle.cid, fun () -> write s (compute (record_items rc)))
    :: tx.pending_derived;
  s

(* REQUEST this app's brand accent (docs/styling-plan.md D1/D2): one
   sRGB hex — [brand_accent 0x3584E4] — is the whole call, and the core
   derives the rest. THE APP NEVER WRITES A FOREGROUND and never writes
   a contrast variant. [~light] and [~dark] are the per-appearance form;
   whatever they leave unstated comes from the seed.

   SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write and
   a late one. *)
let brand_accent ?light ?dark seed =
  let mask =
    (match light with Some _ -> 1 | None -> 0)
    lor match dark with Some _ -> 2 | None -> 0
  in
  emit (the_tx ())
    (Kaya_wire.tx_set_brand_accent seed mask
       (Option.value light ~default:0)
       (Option.value dark ~default:0))

(* REQUEST this app's brand typeface (docs/styling-plan.md Slice 2b):
   one family name — [brand_typeface "Georgia"] — is the whole call.
   THE FAMILY, NEVER THE SCALE. [~platforms] rows TRAVEL UNRESOLVED, so
   each backend picks its own; [~font] ships a font file's bytes and
   [~font_asset] the same slot with the font NAMED (the bytes never enter
   the OCaml heap). The two are EXCLUSIVE — naming both is refused.

   SET ONCE, BEFORE THE FIRST MOUNT. A FAMILY A PLATFORM DOES NOT HAVE
   leaves that platform's own typeface in place, deliberately and
   silently: each lowering gates on the family being PRESENT rather than
   letting the platform pick a stranger. *)
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
       (* THE FONT SLOT IS ALWAYS WRITTEN and the mask above is what
          says whether it means anything: an absent font rides as an
          empty Str, so the record's field count never varies with the
          payload (the accent mask's discipline, verbatim). *)
       (Option.value slot ~default:(Kaya_wire.Str "")))

(* DECLARE this app's identity (docs/app-identity-plan.md): the name it
   goes by and the picture that stands for it, as the bytes of one image
   file — [app_identity ~icon:mark "Aurora Notes"]. Send a PNG; each
   lowering converts. [~icon] LEFT OUT IS THE NAME-ONLY DECLARATION, and
   [~icon_asset] is the same slot with the mark NAMED rather than read;
   the two are exclusive.

   SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write, a
   late one and an empty name. THE BYTES ARE NEVER INSPECTED between here
   and the platform's own decoder. *)
let app_identity ?icon ?icon_asset name =
  let slot =
    match (icon, icon_asset) with
    | Some _, Some _ ->
      invalid_arg
        "kaya: app_identity takes ~icon or ~icon_asset, never both — there is \
         one icon slot on the wire"
    | Some bytes, None -> Some (Kaya_wire.Blob (Kaya_runtime.register_blob bytes))
    | None, Some a -> Some (Kaya_wire.Blob (Kaya_runtime.asset_blob a))
    | None, None -> None
  in
  emit (the_tx ())
    (Kaya_wire.tx_set_app_identity
       (match slot with Some _ -> 1 | None -> 0)
       (Kaya_wire.Str name)
       (* THE ICON SLOT IS ALWAYS WRITTEN and the mask above is what
          says whether it means anything: an absent icon rides as an
          empty Str, so the record's field count never varies with the
          payload (the brand mask's discipline, verbatim). *)
       (Option.value slot ~default:(Kaya_wire.Str "")))

(* Mount into the default window; per-window targets arrive with the
   window vocabulary. *)
(* Set a window's attributes in one construct — the attribute set is
   EXACTLY [create_window]'s (a window's attributes ride its window
   construct; the primary differs only in having no creation moment —
   the process owns it): [window ~title:"sections"
   ~sections_presentation:(Int64.of_int
   Kaya_wire.sections_presentation_bar) ()]. *)
let window ?title ?width ?height ?inset ?veto_close ?dirty ?panes
    ?sections_presentation
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus ?(id = 0L) () =
  let tx = the_tx () in
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_window_title id t)) title;
  Option.iter (fun w -> emit tx (Kaya_wire.tx_set_window_width id w)) width;
  Option.iter (fun h -> emit tx (Kaya_wire.tx_set_window_height id h)) height;
  (* [~inset] is the space kaya's own interpreters put around the mounted
     root, in layout units — LAYOUT, not appearance (docs/styling-plan.md
     D3), which is why it rides here beside the size and not in any styling
     vocabulary. *)
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_inset id v)) inset;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_veto_close id v)) veto_close;
  (* [~dirty] declares that this surface holds unsaved work; the backend
     spells its own platform's affordance (the dot in the close button on
     macOS, a leading [*] in the rendered caption on Windows, a bullet in
     the GTK header bar, nothing on the phones, which have none —
     docs/dirty-plan.md D2/D4). THE TITLE STRING IS NEVER TOUCHED: a
     marker composed into the app's own title is Qt's [*] template, the
     named rejection (D1). *)
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_dirty id v)) dirty;
  (* [~panes] is the CEILING on how many of this window's stack entries
     present side by side: 1 is the serial stack, 2 and 3 are columns on a
     window wide enough, the shallowest shed first as it narrows
     (docs/multicolumn-plan.md carries the ruling and the measured
     mechanics). There is deliberately no argument for WHICH entries show —
     the stack's order is the priority order — and the live count is the
     platform's own judgment where it has one. The root refuses 0 and
     anything above 3. *)
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_window_panes id (Int64.of_int v)))
    panes;
  Option.iter
    (fun p -> emit tx (Kaya_wire.tx_set_window_sections_presentation id p))
    sections_presentation;
  (* The handlers ride the declaration (per-window — handlers scope
     to the thing that creates them): [~on_close_requested] fires per
     chrome close while veto_close is armed (answer with
     [destroy_window] to agree); [~on_closed] fires when the non-veto
     auxiliary is chrome-closed and retires with it. *)
  Option.iter
    (fun f -> Hashtbl.replace tx.app.close_requested id f)
    on_close_requested;
  Option.iter (fun f -> Hashtbl.replace tx.app.window_closed id f) on_closed;
  (* The history handlers ride the window construct for the same reason
     the close ones do — a ledger is per window — and they are NOT
     one-shot: the user walks a history as often as they like, so these
     outlive every step. Each receives the step's label (empty for a
     typing episode) and the state the core put back; the collection
     mirror has already been reconciled from it when the handler runs.
     [~on_undone] hears every undo kaya ROUTED, which is every one it
     was asked for through the Undo role or the chord; an affordance
     kaya does not intercept (a platform context menu) moves the field's
     own stack and says nothing (docs/undo-plan.md A6). *)
  Option.iter (fun f -> Hashtbl.replace tx.app.undone_handlers id f) on_undone;
  Option.iter (fun f -> Hashtbl.replace tx.app.redone_handlers id f) on_redone;
  (* The menubar rides the window construct (the window-attribute
     unification rule): [~menus] realizes its thunks left to right — the
     curried-children convention, [w file] for a retained handle — and
     appends each top-level grouping node (menu or radio_group) to this
     window's command catalog. *)
  Option.iter
    (List.iter (fun th ->
         let (MenuItem m) = th () in
         emit tx (Kaya_wire.tx_menubar_append id m)))
    menus

(* Create an auxiliary window (capability-gated: phone hosts reject at the
   root); materializes hidden, [mount_in] presents. *)
let create_window ?title ?width ?height ?inset ?veto_close ?dirty ?panes
    ?sections_presentation
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_create_window id);
  (* [~dirty] rides the creation like every other window attribute: an
     auxiliary editor can be born with unsaved work, and the mark has to
     survive the surface not existing yet. *)
  window ?title ?width ?height ?inset ?veto_close ?dirty ?panes
    ?sections_presentation
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

(* Append a section to the window's section set (section ids are
   guest-allocated in the shared surface namespace); the set is
   append-only — sections have no destruction grammar, and every
   section's root is retained while covered (switching is SELECTION,
   not lifecycle). [mount_in] fills its pane:
   [add_section ~title:"Feed" ~on_selected:(fun tx -> …) 7L].
   [~on_selected] rides the add (per-section): fires each time the
   USER switches to it — post-fact and NOT one-shot; a programmatic
   [select_section] does not fire it (the echo doctrine). *)
let add_section ?(window = 0L) ?title ?symbol ?on_selected id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_section window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_section_title id t)) title;
  Option.iter
    (fun s -> emit tx (Kaya_wire.tx_set_section_symbol id (symbol_wire s)))
    symbol;
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

(* Request a modal alert (the request/result grammar); labeled arguments are
   the OCaml spelling: [show_alert ~title ~message ~actions:["Delete";
   "Archive"] ~cancel:"Keep" ~on_result:(fun choice tx -> ...) tx]. The
   result handler rides the REQUEST (the widget-handler precedent) and
   retires with its one answer — choice is an action index (0 or 1) or
   [alert_cancel], every platform-native dismissal. *)
let show_alert ?(window = 0L) ?(title = "") ?(message = "")
    ?(actions = []) ~cancel ?on_result () =
  let tx = the_tx () in
  if List.length actions > 2 then
    invalid_arg "kaya: an alert carries at most 2 actions (the platform floor)";
  if cancel = "" then
    invalid_arg "kaya: the cancel slot always exists and needs a name";
  let app = tx.app in
  app.next_alert <- Int64.add app.next_alert 1L;
  let id = app.next_alert in
  Option.iter (fun f -> Hashtbl.replace app.alert_handlers id f) on_result;
  let nth i = match List.nth_opt actions i with Some a -> a | None -> "" in
  emit tx
    (Kaya_wire.tx_show_alert window id (List.length actions)
       (Kaya_wire.Str title) (Kaya_wire.Str message)
       (Kaya_wire.Str (nth 0)) (Kaya_wire.Str (nth 1))
       (Kaya_wire.Str cancel));
  id

(* The alert_choice cancel sentinel, for handlers: the wire u32 0xFFFFFFFF
   as an OCaml int32 (-1l). *)

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

let pick ?(window = 0L) ?(filters = []) ~multiple ?on_result () =
  let tx = the_tx () in
  let app = tx.app in
  let id = next_dialog app in
  Option.iter (fun f -> Hashtbl.replace app.file_dialog_handlers id f) on_result;
  emit tx
    (Kaya_wire.tx_show_file_dialog window id
       (if multiple then 1 else 0)
       (filter_values filters));
  id

(* Ask the platform for files. THE PICK, NOT THE OPEN — the result carries
   handles you redeem later (DESIGN.md, File dialogs). [filters] is a list
   of (label, space-separated extensions), ADVISORY on every platform.
   [on_result] fires exactly once and retires with its answer; CANCEL IS THE
   EMPTY LIST. *)
let pick_files ?(window = 0L) ?(filters = []) ?on_result () =
  pick ~window ~filters ~multiple:true ?on_result ()

(* The single-file spelling. The floor always returns a LIST; this only
   asks the platform for one, so the handler receives zero or one. *)
let pick_file ?(window = 0L) ?(filters = []) ?on_result () =
  pick ~window ~filters ~multiple:false ?on_result ()

(* Ask the platform WHERE TO SAVE. The picker's twin on the same grammar
   and out of the same one-live-dialog slot (docs/save-plan.md D2).

   [suggested_name] is the name the dialog OPENS with; every platform
   TAKES it and none guarantees it, so read the name you GOT — or read
   the bytes instead. On macOS, with allowed content types set,
   NSSavePanel appends the first allowed extension to a name that has
   none (docs/deferred.md).

   [on_result] fires exactly once; CANCEL IS [None]. WHAT YOU GET BACK
   OPENS EMPTY on every platform (docs/save-plan.md D1): the handle opens
   with CREATE, so [file_mode_write] on a fresh destination succeeds and
   yields an empty file everywhere. *)
let save_file ?(window = 0L) ?(filters = []) ?on_result suggested_name =
  let tx = the_tx () in
  let app = tx.app in
  let id = next_dialog app in
  Option.iter
    (fun f ->
      Hashtbl.replace app.file_dialog_handlers id (fun files ->
          f (match files with [] -> None | destination :: _ -> Some destination)))
    on_result;
  emit tx
    (Kaya_wire.tx_show_save_dialog window id
       (Kaya_wire.Str suggested_name)
       (filter_values filters));
  id

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
let read_clipboard ?on_result accepting =
  let tx = the_tx () in
  let app = tx.app in
  app.next_clipboard_read <- Int64.add app.next_clipboard_read 1L;
  let id = app.next_clipboard_read in
  Option.iter (fun f -> Hashtbl.replace app.clipboard_handlers id f) on_result;
  emit tx (Kaya_wire.tx_read_clipboard id (Kaya_wire.Str (accept_list accepting)));
  id

(* Declare what a widget takes from a paste — the closed kinds by name
   ("text", "html", "image", "files") plus any custom format ids. It
   drives whether Paste is live while this widget is focused, filters
   what reaches the paste hook, and on Android IS the native
   registration. A widget that declares NOTHING gets the platform's own
   insertion, which is why a plain text editor writes none of this and
   has working cut, copy and paste. *)
let set_accepts (Widget id) kinds =
  emit (the_tx ()) (Kaya_wire.tx_set_accepts id (accept_list kinds))

let alert_cancel = Kaya_wire.alert_choice_cancel



let mount (Widget root) = emit (the_tx ()) (Kaya_wire.tx_mount 0L root)

(* --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

   The curried-children convention extends to items: creators end in
   [()], omitted unit is the child form, and a grouping creator's list
   holds bare partial applications the parent realizes left to right. The
   window construct's [~menus] is the bar anchor;
   [context_menu]/[context_catalog] are the noun anchors. *)

(* Create one item in the menu-item id space. Menu records are
   live-zone only: a template body records a blueprint, and items are
   live and shared across stamped copies — build the catalog outside
   ([context_catalog]) and attach it inside the template with
   [Tpl.context_menu]. *)
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

(* The shared optional-prop tail: [?enabled] a constant, [?bind_enabled]
   a Bool signal, [?icon] the blob channel and [?symbol] the SEMANTIC
   one. The two icon slots are different channels, not alternatives.
   Both live on the TAIL so every leaf and every grouping node gets them
   from one place. *)
let menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol () =
  let tx = the_tx () in
  Option.iter (fun e -> emit tx (Kaya_wire.tx_set_menu_enabled id e)) enabled;
  Option.iter
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_enabled id s))
    bind_enabled;
  Option.iter
    (fun data ->
      emit tx (Kaya_wire.tx_set_menu_icon id (Kaya_runtime.register_blob data)))
    icon;
  Option.iter
    (fun s -> emit tx (Kaya_wire.tx_set_menu_symbol id (symbol_wire s)))
    symbol

(* An action — a leaf command firing exactly one menu_activated occurrence
   (menu click OR its shortcut: ONE occurrence, one dispatch path;
   [~on_activate] rides the declaration and covers both).
   [~on_activate_node] is the template-node flavor: an item attached to a
   stamped copy reports the copy's key path, outermost first — the keys ARE
   the noun. *)
let item ?shortcut ?enabled ?bind_enabled ?icon ?symbol ?primary ?role
    ?on_activate ?on_activate_node ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_action (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  Option.iter (fun r -> emit tx (Kaya_wire.tx_set_menu_role id r)) role;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun p -> emit tx (Kaya_wire.tx_set_menu_primary id p)) primary;
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_activated id f) on_activate;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.menu_activated_node id f)
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
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_checked id s))
    bind_checked;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_toggled id f) on_toggle;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.menu_toggled_node id f)
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
   idiom, admissible wherever a menu grouping node is. The children
   are [option]s only (the closed grammar, root-checked); [~value] /
   [~bind_value] is the selected 0-based index, applied AFTER the
   options so the index has options to address (programmatic writes
   are quiet); [~on_select] receives each USER pick's new index, and
   [~on_select_node] the stamped keys first. *)
let radio_group ?value ?bind_value ?enabled ?bind_enabled ?icon ?symbol
    ?on_select ?on_select_node ~label options () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_radio_group (Some label) in
  realize_menu_children tx id options;
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_menu_value id (float_of_int v)))
    value;
  Option.iter
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_value id s))
    bind_value;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ?symbol ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_selected id f) on_select;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.menu_selected_node id f)
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
   template-node anchor (menu items are live and shared across stamped
   copies): [Tpl.context_menu] attaches it inside the template, and
   each activation carries the copy's key path. *)
let context_catalog children =
  {
    cc_roots = List.map (fun th -> let (MenuItem m) = th () in m) children;
    cc_attached = false;
  }

(* The dynamic tier for a RETAINED item — every mutable prop, each
   judged by the root against the item's kind and anchor, plus
   [menu_append], the reopening of a grouping node. Label and
   enablement writes never emit anything; programmatic checked/value
   writes are configuration and stay QUIET (the echo doctrine). *)
let set_menu_label (MenuItem id) text =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_label id text)

let bind_menu_label (MenuItem id) (Signal s) =
  emit (the_tx ()) (Kaya_wire.tx_bind_menu_label id s)

let set_menu_enabled (MenuItem id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_enabled id on)

let bind_menu_enabled (MenuItem id) (Signal s) =
  emit (the_tx ()) (Kaya_wire.tx_bind_menu_enabled id s)

let set_menu_checked (MenuItem id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_checked id on)

let bind_menu_checked (MenuItem id) (Signal s) =
  emit (the_tx ()) (Kaya_wire.tx_bind_menu_checked id s)

let set_menu_value (MenuItem id) index =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_value id (float_of_int index))

let bind_menu_value (MenuItem id) (Signal s) =
  emit (the_tx ()) (Kaya_wire.tx_bind_menu_value id s)

let set_menu_icon (MenuItem id) data =
  emit (the_tx ())
    (Kaya_wire.tx_set_menu_icon id (Kaya_runtime.register_blob data))

(* The SEMANTIC icon on a retained item ([symbol], the closed
   vocabulary) — [set_menu_icon]'s sibling, and the dynamic spelling of
   the constructors' [~symbol], exactly as [set_role] is the dynamic
   spelling of [~role]. *)
let set_menu_symbol (MenuItem id) s =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_symbol id (symbol_wire s))

(* The phone-bar promotion hint (actions only — root-checked).
   Flipping it recomputes the promoted set deterministically; INERT on
   desktops — not a toolbar grammar. *)
let set_menu_primary (MenuItem id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_primary id on)

(* The closed standard-command vocabulary (DESIGN.md, Menus): macOS
   places this one in the application menu, and every other host leaves
   the item where the app declared it. *)
(* A named vocabulary for the accept list's closed half. A MISTYPED BARE
   STRING IS SILENT: it becomes a custom format id no clipboard will ever
   offer, so Paste stays dead and the paste hook never fires, with
   nothing to see anywhere. *)
let accept_text = "text"
let accept_html = "html"
let accept_image = "image"
let accept_files = "files"

let role_settings = "settings"

(* The three clipboard commands. They lower to the platform's own, act on
   the FOCUSED widget, and work out their own enablement from what the
   clipboard offers and what that widget accepts. *)
let role_cut = "cut"
let role_copy = "copy"
let role_paste = "paste"

(* The two history commands. ONE Edit>Undo covers both tiers: it asks the
   focused text widget's own stack first and the window's ledger otherwise,
   and works out its own enablement from the same question, live at
   activation (docs/undo-plan.md D1, D6). *)
let role_undo = "undo"
let role_redo = "redo"

(* Declare a retained action a standard command (actions only — root-
   checked). *)
let set_menu_role (MenuItem id) name =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_role id name)

(* The shortcut of any LEAF command — an action, a toggle, or one
   option of a group (window-anchored only). Canonicalized
   by the binding's one parser (Kaya_wire.canonicalize_shortcut); the
   shortcut is another affordance of the same item — it fires the SAME
   menu_activated occurrence as a click. *)
let set_menu_shortcut (MenuItem id) spelling =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_shortcut id spelling)

(* Reopen a RETAINED grouping node and append more children — the
   append-at-any-time discipline: [menu_append file [ item ~label:"Publish"
   ~primary:true ~on_activate:h ]]. *)
let menu_append (MenuItem id) children =
  realize_menu_children (the_tx ()) id children

(* A template body: the same declaration vocabulary with template-node
   ids, plus element bindings. *)
type tpl = { tpl_tx : tx }

let alloc_node tx =
  tx.app.c_node <- Int64.add tx.app.c_node 1L;
  tx.app.c_node

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
   [for_each] returns. One title per column; the row template's root
   must be a row of exactly one cell per column, refused loudly
   otherwise. Re-call after sorting to move the indicator. *)
let columns (Widget id) titles sort =
  let tx = the_tx () in
  (* path_len 0: no key path, so the values are titles alone
     (docs/tables-plan.md, dynamic tables). *)
  emit tx
    (Kaya_wire.tx_set_column_headers id
       (Int32.to_int sort.sort_column land 0xFFFFFFFF)
       (Int32.to_int sort.sort_direction)
       (List.length titles) 0
       (List.map (fun t -> Kaya_wire.Str t) titles))

(* Re-declare ONE stamped copy's header bar — the per-copy sort arrows.
   [node] is the nested For's template node ([Tpl.for_each]'s first
   result) and [keys] the copy's key path outermost first, exactly as
   [on_sort_node] handed it over; an empty [keys] re-declares the
   template-wide bar for every copy. The core walls a keyed target whose
   template bar was never declared (docs/tables-plan.md). *)
let columns_at (Node id) keys titles sort =
  let tx = the_tx () in
  emit tx
    (Kaya_wire.tx_set_column_headers id
       (Int32.to_int sort.sort_column land 0xFFFFFFFF)
       (Int32.to_int sort.sort_direction)
       (List.length titles) (List.length keys)
       (keys @ List.map (fun t -> Kaya_wire.Str t) titles))

(* Sums: a variant type whose constructors carry inline records. *)
type 'a sum_type = {
  st_schemas : int list list;
  st_variant : 'a -> int;
  st_to_values : 'a -> Kaya_wire.value list;
  st_of_values : int -> Kaya_wire.value list -> 'a;
}

type 'a sum_collection = { sc_handle : collection; sc_type : 'a sum_type }

let sum_handle sc = sc.sc_handle

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
let sum_insert sc key value =
  let tx = the_tx () in
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

(* [insert_fresh] for a sum collection: the value's own constructor is still
   what is witnessed onto the wire; only the key comes from the binding. *)
let sum_insert_fresh sc value =
  let tx = the_tx () in
  let key = mint_key tx.app sc.sc_handle.cid sc.sc_handle.cpath in
  sum_insert sc (Kaya_wire.I64 key) value;
  key

(* Update replaces a record wholesale; a different constructor than
   the entry's current one restamps its copy in place. *)
let sum_update sc key value =
  let tx = the_tx () in
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
let sum_items sc =
  let tx = the_tx () in
  guard_mirror_read ();
  match
    List.find_opt
      (fun i -> i.path = sc.sc_handle.cpath)
      (instances_of tx.app sc.sc_handle.cid)
  with
  | Some i ->
      List.map (fun (k, (v, vs)) -> (k, sc.sc_type.st_of_values v vs)) i.entries
  | None -> []

(* The entry's current value — the scrutinee for the match that
   precedes a patch. *)
let sum_get sc key =
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
        (List.assoc_opt key i.entries)
  | None -> None

(* The witnessed field write, called by the generated per-constructor
   patches: the match that produced the write names the variant, and
   the model refuses a drifted entry — the guard is checked, not
   trusted. *)
let sum_update_field sc key ~variant fd value =
  let tx = the_tx () in
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
let sum_derive sc compute =
  let tx = the_tx () in
  let s = signal (compute (sum_items sc)) in
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
let when_ (Signal sid) body () =
  let tx = the_tx () in
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_when id sid);
  (* The body's result is its blueprint root, already recorded —
     discarded, so bodies END with the root and the partial
     application is a child. *)
  ignore (in_tpl_scope tx.app body);
  emit tx (Kaya_wire.tx_template_end ());
  Widget id

module Tpl = struct
  (* The template zone, direct style like the outer zone: the ambient
     transaction serves template bodies too (they only ever run inside
     [build]), so plain [let] and [;] compose blueprints — the tpl
     reader retired with the outer decl reader (2026-07-22). *)

  (* --- THE FLOOR, IN A MODULE THAT SAYS SO -------------------------
     Node allocation, the child link and one prop write per record: the
     tier every constructor below is sugar over, and the tier no example
     scene may spell (invariant 5).

     A MODULE AND NOT A NAME because the receiver's type is the whole
     difference between [set_text editor doc] (a live verb every binding
     must have) and [set_text n "add"] (the floor spelling of [~text]),
     and no pattern over a guest file sees a type. The qualifier is what
     a pattern CAN see: the floor says [Floor.] at every callsite
     (docs/tpl-props-plan.md F3). *)
  module Floor = struct
    let widget kind =
      let tx = the_tx () in
      let id = alloc_node tx in
      emit tx (Kaya_wire.tx_create_widget id kind);
      Node id

    (* --- The const setters ------------------------------------------
       A template node's props travel the wire exactly as a widget's do
       — only the id space differs — so these are the live setters with
       [Node] destructured instead of [Widget], and the constructor of
       the wrapper is what keeps a live setter off a blueprint and a
       template setter off a widget. *)

    let set_text (Node id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

    let set_checked (Node id) checked =
      emit (the_tx ()) (Kaya_wire.tx_set_checked id checked)

    let set_value (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_value id v)
    let set_min (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_min id v)
    let set_max (Node id) v = emit (the_tx ()) (Kaya_wire.tx_set_max id v)

    let set_indeterminate (Node id) on =
      emit (the_tx ()) (Kaya_wire.tx_set_indeterminate id on)

    let set_columns (Node id) n =
      emit (the_tx ()) (Kaya_wire.tx_set_columns id (float_of_int n))

    let set_source (Node id) data =
      emit (the_tx ()) (Kaya_wire.tx_set_source id (Kaya_runtime.register_blob data))

    let set_grow (Node id) weight = emit (the_tx ()) (Kaya_wire.tx_set_grow id weight)

    (* --- What a stamped copy MEANS, and how far it holds its children
       off its own edge -------------------------------------------------

       CONST ONLY, like [set_accepts]: what a copy means, and how far its
       prototype holds its children off its edge, are facts about the
       PROTOTYPE rather than about the row's data.

       NEITHER NEEDS A TYPE-LEVEL WALL HERE, because [node] is not typed
       by kind and the root judges the combination while the blueprint is
       recorded, before a single row stamps
       (crates/kaya/src/scene.rs). *)

    let set_role (Node id) r = emit (the_tx ()) (Kaya_wire.tx_set_role id (role_wire r))
    let set_inset (Node id) pad = emit (the_tx ()) (Kaya_wire.tx_set_inset id pad)

    (* --- What a stamped copy carries for assistive tech --------------
       Grouped by PROP rather than by source, because that is how they
       arrive: the three sources of ONE prop are the choice the
       constructor's caller makes.

       A DUPLICATE ID ACROSS COPIES IS LEGAL and often right: nothing in
       the core deduplicates a11y ids and the harness addresses by
       kind#index, never by id. *)

    let set_a11y_id (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_id id value)

    let bind_a11y_id (Node id) (Signal s) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_id id s)

    (* A (_, string) field only: Prop::A11yId is Str in the spec and
       the scene refuses a field whose schema column type differs from
       the prop's, so the phantom moves that abort to compile time —
       see [bind_value_field] for the same argument at length. *)
    let bind_a11y_id_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_id_element ~level ~field:fd.fd_index id)

    let set_a11y_label (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_label id value)

    let bind_a11y_label (Node id) (Signal s) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_label id s)

    (* THE SOURCE THIS SLICE EXISTS FOR: each stamped copy speaks its OWN
       row's name to assistive tech. *)
    let bind_a11y_label_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_label_element ~level ~field:fd.fd_index id)

    (* ACTIVATION KINDS ONLY — button, checkbox, select, radio. The
       restriction cannot be a type here: [node] is not typed by kind,
       because a container's children are one list and OCaml's lists are
       homogeneous. So the wall is the constructors, and a hint reaching
       a template label dies at DECLARE time in the root's own words. *)
    let set_a11y_hint (Node id) value =
      emit (the_tx ()) (Kaya_wire.tx_set_a11y_hint id value)

    let bind_a11y_hint (Node id) (Signal s) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_hint id s)

    let bind_a11y_hint_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_a11y_hint_element ~level ~field:fd.fd_index id)

    (* The two universal props as they ride every constructor here, applied
       together in one place so a new constructor cannot pick up [~grow]
       and quietly miss them.

       [~a11y_level] is how many Fors up the FIELD source sits and
       defaults to the constructor's own [~level]. ONE SHARED [~level]
       WOULD HAVE BEEN THE TRAP: [~bind_field:x ~level:1
       ~a11y_label_field:y] would have moved the label's source out one
       For as well, silently. *)
    let set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
        ?a11y_label_bind ?a11y_label_field ?(a11y_level = 0) n =
      Option.iter (fun v -> set_a11y_id n v) a11y_id;
      Option.iter (fun s -> bind_a11y_id n s) a11y_id_bind;
      Option.iter (fun fd -> bind_a11y_id_field ~level:a11y_level n fd) a11y_id_field;
      Option.iter (fun v -> set_a11y_label n v) a11y_label;
      Option.iter (fun s -> bind_a11y_label n s) a11y_label_bind;
      Option.iter (fun fd -> bind_a11y_label_field ~level:a11y_level n fd) a11y_label_field

    (* What a stamped copy takes from a paste — and the prop that lets a
       copy's paste hook fire at all. Every backend gates the paste
       occurrence on the focused widget's ACCEPT LIST and falls back to
       the platform's own insertion when it is empty, so without this
       [on_paste_node] would register a handler and wait forever
       (docs/tpl-props-plan.md §1). CONST ONLY: an accept list describes
       the PROTOTYPE. *)
    let set_accepts (Node id) kinds =
      emit (the_tx ()) (Kaya_wire.tx_set_accepts id (accept_list kinds))

    (* --- The signal leg ----------------------------------------------
       The zone's second addressable source, and the one that was
       missing here entirely: [Tpl] could take a constant or the row's
       own field and had no way to say "every copy follows this
       signal". A signal is app-wide, so every stamped copy reads the
       SAME value — that is the point of it, not a limitation: one
       download's fraction on every row's bar, one setting in every
       row's caption. The core carries it on the template path like any
       other prop value, checking the signal's current value against
       the prop at declaration (crates/kaya/src/scene.rs:3590) and
       re-registering each stamped copy in the binding table so a later
       [write] fans out to all of them
       (crates/kaya/src/scene.rs:4328). *)

    let bind_text (Node id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_text id s)

    let bind_checked (Node id) (Signal s) =
      emit (the_tx ()) (Kaya_wire.tx_bind_checked id s)

    let bind_value (Node id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_value id s)

    let bind_source (Node id) (Signal s) =
      emit (the_tx ()) (Kaya_wire.tx_bind_source id s)

    (* --- The element leg ---------------------------------------------
       The source only this zone has: the row's own data. [level] says
       how many Fors up the element sits (0 = nearest). *)

    (* Bind text to the element of the enclosing For, [level] Fors up
       (0 = nearest). *)
    let bind_text_element ?(level = 0) (Node id) =
      emit (the_tx ()) (Kaya_wire.tx_bind_text_element ~level id)

    (* Bind a label's text to one field of the element; a (_, string)
       field only — the phantom pins it at compile time. *)
    let bind_text_field ?(level = 0) (Node id) (fd : (_, string) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_text_element ~level ~field:fd.fd_index id)

    (* Bind a checkbox's state to one field of the element; a (_, bool)
       field only. *)
    let bind_checked_field ?(level = 0) (Node id) (fd : (_, bool) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_checked_element ~level ~field:fd.fd_index id)

    (* Bind a fraction, a slider position or a choice's selected index to
       one field of the element. A (_, float) field, and a choice's index is
       no exception: Prop::Value is F64 in the spec, and the scene refuses a
       field whose schema column type differs from the prop's
       (crates/kaya/src/scene.rs:3629), so an i64 field would typecheck here
       and abort at declaration. *)
    let bind_value_field ?(level = 0) (Node id) (fd : (_, float) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_value_element ~level ~field:fd.fd_index id)

    (* Bind an image's source to one field of the element; a (_, bytes)
       field only — the phantom pins it at compile time. *)
    let bind_source_field ?(level = 0) (Node id) (fd : (_, bytes) field) =
      emit (the_tx ()) (Kaya_wire.tx_bind_source_element ~level ~field:fd.fd_index id)

    let add_child (Node parent) (Node child) =
      emit (the_tx ()) (Kaya_wire.tx_add_child parent child)
  end

  let collection () = collection ()

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
     away, so the partial application is a [unit -> node] creator and
     slots into a child list like any constructor. The outer zone's
     [each] is the same one line over its own [for_each], and this zone
     went without it for two milestones — guests/ocaml/milestone2.ml
     apologised for the gap in a comment, and the workaround it named
     ([w item_list] over a For realized on a line of its own) is the
     shape a nested For had to take in every OCaml scene. Swift and C#
     have [each] in both zones; this is invariant 1, one line wide. *)
  let each c body () = fst (for_each c body ())

  (* Declare the header bar of a nested For — one bar per stamped copy
     from ONE declaration on the template node [for_each] just handed
     back. It goes on the NEXT LINE, inside the still-open parent scope:
     the nested For folds into that parent at its TemplateEnd and this
     op looks for it there, so a grandparent-scope target is not
     expressible (measured in slice 1, docs/tables-plan.md).
     [columns_at] moves one copy's arrows after a sort request. *)
  let columns (Node id) titles sort =
    let tx = the_tx () in
    (* path_len 0 against a TEMPLATE NODE: every copy's bar, stored on
       the site and applied at each stamp. *)
    emit tx
      (Kaya_wire.tx_set_column_headers id
         (Int32.to_int sort.sort_column land 0xFFFFFFFF)
         (Int32.to_int sort.sort_direction)
         (List.length titles) 0
         (List.map (fun t -> Kaya_wire.Str t) titles))

  let when_ (Signal sid) body () =
    let tx = the_tx () in
    let id = alloc_node tx in
    emit tx (Kaya_wire.tx_create_when id sid);
    let result = in_tpl_scope tx.app body in
    emit tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  (* --- The construction sugar, template flavor -------------------- *)

  let button ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?role ?text ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_click () =
    let n = Floor.widget Kaya_wire.kind_button in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_a11y_hint n v) a11y_hint;
    (* [Destructive] or [Prominent] — the stamped row's own delete
       button, which is what this prop reaching the zone is for; a
       [Heading] button dies at the root, as it does live. *)
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
        Hashtbl.replace (the_tx ()).app.node_handlers id handler
    | None -> ());
    n

  (* A multi-line editor per stamped copy: the entry's uncontrolled contract
     over the platform's real multi-line control. *)
  let textarea ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?accepts ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_textarea in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun kinds -> Floor.set_accepts n kinds) accepts;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_changes id handler
    | None -> ());
    n

  let label ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?role ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) () =
    let n = Floor.widget Kaya_wire.kind_label in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    (* [Heading] is the label's role — the platform's own heading text style
       AND the trait assistive users skim by, which is what makes a stamped
       section title readable as one. *)
    Option.iter (fun r -> Floor.set_role n r) role;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    n

  (* A single-line text field per stamped copy. UNCONTROLLED exactly as
     its live twin is: the copy owns its text, every edit arrives at
     [~on_change] with that copy's keys first, and the app folds it into
     its own state — there is no read-back, by doctrine. *)
  let entry ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?accepts ?text ?bind ?bind_field
      ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_entry in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun kinds -> Floor.set_accepts n kinds) accepts;
    Option.iter (fun x -> Floor.set_text n x) text;
    Option.iter (fun s -> Floor.bind_text n s) bind;
    Option.iter (fun fd -> Floor.bind_text_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_changes id handler
    | None -> ());
    n

  (* A progress bar per stamped copy: display-only, like label and image. *)
  let progress ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?value ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?indeterminate () =
    let n = Floor.widget Kaya_wire.kind_progress in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun v -> Floor.set_value n v) value;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    Option.iter (fun i -> Floor.set_indeterminate n i) indeterminate;
    n

  (* A slider per stamped copy, over [~min]..[~max] at a position from any
     of the three sources. *)
  let slider ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?(min = 0.0) ?(max = 1.0) ?value ?bind
      ?bind_field ?(level = 0) ?(a11y_level = level) ?on_change () =
    let n = Floor.widget Kaya_wire.kind_slider in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Floor.set_min n min;
    Floor.set_max n max;
    Option.iter (fun v -> Floor.set_value n v) value;
    Option.iter (fun s -> Floor.bind_value n s) bind;
    Option.iter (fun fd -> Floor.bind_value_field ~level n fd) bind_field;
    (match on_change with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_values id handler
    | None -> ());
    n

  (* A dropdown select per stamped copy, over fixed [options] — each
     option becomes a label child, exactly as in the live zone (labels
     only). The SELECTED INDEX is what varies per row and takes any of
     the three sources; [~bind_field] wants a (_, float) field, because
     Prop::Value is F64 (see [bind_value_field]). *)
  let select ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?selected ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_select options () =
    let n = Floor.widget Kaya_wire.kind_select in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
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
            handler keys (int_of_float v))
    | None -> ());
    n

  (* A radio group per stamped copy — the choice contract ([select]) in
     its inline presentation: same option children, same 0-based index
     from the same three sources, same pick handler. *)
  let radio ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?selected ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_select options () =
    let n = Floor.widget Kaya_wire.kind_radio in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
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
            handler keys (int_of_float v))
    | None -> ());
    n

  let checkbox ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_hint ?a11y_hint_bind
      ?a11y_hint_field ?checked ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) ?on_toggle () =
    let n = Floor.widget Kaya_wire.kind_checkbox in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
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
        Hashtbl.replace (the_tx ()).app.node_toggles id handler
    | None -> ());
    n

  (* An image per stamped copy: [~source] gives every copy the same
     encoded bytes (one registration copy into core memory, consumed by
     the next submit), [~bind] a Blob signal, [~bind_field] each row's
     own (_, bytes) field — the per-row picture that a list of anything
     with a thumbnail wants. *)
  let image ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?source ?bind ?bind_field ?(level = 0)
      ?(a11y_level = level) () =
    let n = Floor.widget Kaya_wire.kind_image in
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun data -> Floor.set_source n data) source;
    Option.iter (fun s -> Floor.bind_source n s) bind;
    Option.iter (fun fd -> Floor.bind_source_field ~level n fd) bind_field;
    n

  (* Containers, the outer-zone convention: children are partially
     applied creators ([unit -> node] thunks), realized left to
     right; [()] realizes, omitting it nominates a child. *)
  let container ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?(a11y_level = 0) ?inset kind children ()
      =
    let parent = Floor.widget kind in
    Option.iter (fun g -> Floor.set_grow parent g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level parent;
    (* Every stamped copy's own padding. [~spacing] and [~align] stay
       floor-only on template containers, in every binding alike — this
       one prop comes over because a stamped row with no margin is what
       the editor's find bar was. *)
    Option.iter (fun p -> Floor.set_inset parent p) inset;
    List.iter (fun child -> Floor.add_child parent (child ())) children;
    parent

  (* A grid per stamped copy, laid out row-major into [~columns]
     columns — each column takes its NATURAL width, aligned across rows
     (the thing nested rows cannot express). The column count describes
     the prototype, so it stays a required constant. The columns record
     lands BEFORE the add_childs, as in the live zone. *)
  let grid ~columns ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?(a11y_level = 0) ?inset children () =
    let n = Floor.widget Kaya_wire.kind_grid in
    Floor.set_columns n columns;
    Option.iter (fun g -> Floor.set_grow n g) grow;
    Floor.set_a11y ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ~a11y_level n;
    Option.iter (fun p -> Floor.set_inset n p) inset;
    List.iter (fun child -> Floor.add_child n (child ())) children;
    n

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
  let column ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level ?inset children =
    container ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level ?inset
      Kaya_wire.kind_column children

  (* A vertical scroll viewport per stamped copy, over EXACTLY ONE
     child. Pass [~grow] so the enclosing track CONSTRAINS it — an
     unconstrained viewport hugs its content and nothing overflows.
     CAUTION: the scene enforces the one-child rule on the live path
     only (crates/kaya/src/scene.rs:1860); the template declare arm does
     not check it yet, so a second child here is accepted in silence
     until that gap closes. *)
  let scroll ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level children =
    container ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level Kaya_wire.kind_scroll
      children

  (* [~inset] rides the two flex containers and the grid and stops
     there, exactly as it does live: the root admits the prop on Column,
     Row and Grid alone (crates/kaya/src/scene.rs:552), so [scroll]
     above forwards no inset and a viewport asking for one dies at
     declare time rather than reaching four backends. *)
  let row ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level ?inset children =
    container ?grow ?a11y_id ?a11y_id_bind ?a11y_id_field ?a11y_label
      ?a11y_label_bind ?a11y_label_field ?a11y_level ?inset Kaya_wire.kind_row
      children

  (* Attach a live-built context catalog ([context_catalog]) to a template
     node: every stamped copy shows the same catalog, and each activation
     carries that copy's key path — the keys ARE the noun (received by the
     [_node] handler flavors). *)
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
(* Register the table's header-click handler at its For — the handler
   receives the 0-based column of a sort REQUEST: nothing has changed
   on screen; reorder the collection by key and re-declare the header
   with [columns] (docs/tables-plan.md). *)
let on_sort app (Widget id) (handler : int -> unit) =
  Hashtbl.replace app.sort_handlers id handler

(* The same, at a NESTED For's template node: one registration answers
   every stamped copy, and the handler receives that copy's key path
   outermost first before the column — hand those same keys back to
   [columns_at] to move that copy's arrows alone. *)
let on_sort_node app (Node id)
    (handler : Kaya_wire.value list -> int -> unit) =
  Hashtbl.replace app.node_sorts id handler

let on_click app (Widget id) (handler : unit -> unit) =
  Hashtbl.replace app.widget_handlers id handler

(* Register a click handler for a template node; it also receives the
   stamped copy's keys, outermost first. *)
let on_click_node app (Node id) (handler : Kaya_wire.value list -> unit) =
  Hashtbl.replace app.node_handlers id handler

(* Register a change handler for a live entry: the widget owns its text
   and reports each edit here; the app folds the text into its own
   state — there is no read-back, by doctrine. *)
(* Take pasted content at a live widget. *)
let on_paste app (Widget id) (handler : representation -> unit) =
  Hashtbl.replace app.widget_pastes id handler

(* A paste onto a stamped copy: the handler also receives the copy's key
   path, outermost first. *)
let on_paste_node app (Node id)
    (handler : Kaya_wire.value list -> representation -> unit) =
  Hashtbl.replace app.node_pastes id handler

let on_change app (Widget id) (handler : string -> unit) =
  Hashtbl.replace app.widget_changes id handler

(* Register a change handler for a template entry; it also receives the
   stamped copy's keys, outermost first. *)
let on_change_node app (Node id) (handler : Kaya_wire.value list -> string -> unit) =
  Hashtbl.replace app.node_changes id handler

(* Register a toggle handler for a live checkbox: the box owns its
   checked bit and reports each flip here; the app folds it into its
   own state. *)
let on_toggle app (Widget id) (handler : bool -> unit) =
  Hashtbl.replace app.widget_toggles id handler

(* Register a change handler for a live slider: the bar owns its
   position and reports each move with the new value — the entry's
   uncontrolled contract, with a float. *)
let on_value_changed app (Widget id) (handler : float -> unit) =
  Hashtbl.replace app.widget_values id handler

(* Register a toggle handler for a template checkbox; it also receives
   the stamped copy's keys, outermost first. *)
let on_toggle_node app (Node id) (handler : Kaya_wire.value list -> bool -> unit) =
  Hashtbl.replace app.node_toggles id handler

(* Register a change handler for a template slider or choice widget; it also
   receives the stamped copy's keys, outermost first. *)
let on_value_changed_node app (Node id)
    (handler : Kaya_wire.value list -> float -> unit) =
  Hashtbl.replace app.node_values id handler

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
      signals (n - 1) ((id, value) :: acc)
  in
  let rec texts n acc =
    if n = 0 then List.rev acc
    else begin
      let start = !pos in
      (* size, id, path_len — then the path, then the text. [size]
         counts itself, exactly as the two group runs below do, and it
         is what the cursor is advanced by: the path is what NAMES a
         stamped copy's field, and the old fixed pair had nowhere to
         put it. *)
      let size = int () in
      let id = i64 () in
      let path = take_n (int ()) in
      let text =
        match take_n (start + size - !pos) with
        | [ Kaya_wire.Str s ] -> s
        | _ -> ""
      in
      texts (n - 1) ({ ut_id = id; ut_path = path; ut_text = text } :: acc)
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
        ({ ue_collection = collection; ue_path = path; ue_key = key; ue_state = state }
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
        ({ uo_collection = collection; uo_path = path; uo_keys = keys } :: acc)
    end
  in
  let ud_signals = signals n_signals [] in
  let ud_texts = texts n_texts [] in
  let ud_entries = entries n_entries [] in
  let ud_orders = orders n_orders [] in
  if !pos <> count then failwith "kaya: undo delta has trailing values";
  (label, { ud_signals; ud_texts; ud_entries; ud_orders })

(* Fold an undo's payload into the collection mirror. *)
let absorb_undo app delta =
  List.iter
    (fun e ->
      let instances = instances_of app e.ue_collection in
      let instances =
        if List.exists (fun i -> i.path = e.ue_path) instances then instances
        else instances @ [ { path = e.ue_path; entries = [] } ]
      in
      Hashtbl.replace app.model e.ue_collection
        (List.map
           (fun i ->
             if i.path <> e.ue_path then i
             else
               match e.ue_state with
               | Some state ->
                   if List.mem_assoc e.ue_key i.entries then
                     {
                       i with
                       entries =
                         List.map
                           (fun (k, v) -> (k, if k = e.ue_key then state else v))
                           i.entries;
                     }
                   else { i with entries = i.entries @ [ (e.ue_key, state) ] }
               | None ->
                   { i with entries = List.filter (fun (k, _) -> k <> e.ue_key) i.entries })
           instances))
    delta.ud_entries;
  List.iter
    (fun o ->
      Hashtbl.replace app.model o.uo_collection
        (List.map
           (fun i ->
             if i.path <> o.uo_path then i
             else
               (* The payload's order first, then anything it does not
                  name: the delta describes one instance's whole order,
                  and an entry it never mentions is one this step did
                  not touch. *)
               let named =
                 List.filter_map
                   (fun k ->
                     Option.map (fun v -> (k, v)) (List.assoc_opt k i.entries))
                   o.uo_keys
               in
               let rest =
                 List.filter (fun (k, _) -> not (List.mem k o.uo_keys)) i.entries
               in
               { i with entries = named @ rest })
           (instances_of app o.uo_collection)))
    delta.ud_orders

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
    | Some (kind, id, keys, payload, clip, undo) ->
        (if kind = Kaya_wire.occ_kind_sort_requested then
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
               dispatch app (fun () -> handler (Int64.to_int c))
           | _ -> ())
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
         else if
           kind = Kaya_wire.occ_kind_undone || kind = Kaya_wire.occ_kind_redone
         then
           (* ONE STEP CAME BACK, and this record is the whole of what
              the app hears: applying an inverse is programmatic, so the
              echo doctrine silences everything it did — no text_changed
              for the text it restored, no value_changed for the
              signals. NOT one-shot: a history is walked as often as the
              user likes. *)
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
              space, so neither widget nor node ids can collide with
              them. Node-anchored context items carry the stamped
              copy's keys (the keys ARE the noun); toggles carry the
              new state, radio groups the new 0-based index. *)
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
