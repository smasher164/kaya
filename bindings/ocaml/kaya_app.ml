(* kaya's idiomatic surface for OCaml: the structural core.

   Three jobs, layered over the runtime (kaya_runtime.ml) and the
   generated wire vocabulary (kaya_wire.ml):

   - id allocation: signals, widgets, collections, and template nodes
     come from per-space counters behind distinct types, so no app
     hand-numbers the id spaces — and the compiler keeps blueprint
     nodes (node) from being used where live widgets (widget) belong;
   - template scoping: for_each and when_ take a (unit -> 'a) whose
     body declares the blueprint, bracketing the records. OCaml has no
     overloading, so the template vocabulary lives in the Tpl submodule
     — the module path spells the zone the way the type family does in
     the Haskell binding;
   - direct-style declarations over the AMBIENT transaction: [build]
     (and each handler dispatch) sets the ambient tx for its extent,
     every builder reads it, and plain [let] and [;] compose scenes —
     ratified 2026-07-22, retiring the let*/decl reader. The price of
     direct style is that "declared outside a transaction" moves from
     a type error to a loud runtime error (see [the_tx]). The Tpl
     submodule still spells the template zone by module path;
   - the trailing-unit convention: every creator ends in [()]. Apply
     it to realize a widget where you stand ([let field = entry
     ~on_change:h ()]); omit it and the partial application is a pure
     [unit -> widget] thunk — the child form containers take in
     lists, realized left to right ([List.iter]'s specified order, so
     document order never rides on OCaml's unspecified list-literal
     evaluation order). [w] wraps an already-realized widget for a
     child slot;
   - occurrence dispatch: handlers register per button; the app loop
     routes each click, handing template-node handlers the stamped
     copy's key path. Handlers run inside their own transaction (the
     ambient tx is set for their extent); it submits when the handler
     returns. *)

type signal = Signal of int64
type widget = Widget of int64
type node = Node of int64

(* A live menu item: its OWN id space (the c_menu_item counter) behind
   its own constructor, so cross-use with widget or node handles is a
   type error. One command identity: exactly one parent or anchor,
   forever (append-only; nothing is removed in v1). The handle is
   durable — the dynamic tier (set_menu_label, menu_append, ...)
   reopens it in any later transaction. *)
type menu_item = MenuItem of int64

(* A context catalog built UNANCHORED ([context_catalog]) for a
   template node: menu items are live and shared across stamped
   copies, so the catalog is built in the live zone and
   [Tpl.context_menu] attaches it inside the template, where each
   activation carries the copy's key path. An item takes exactly one
   anchor — a second attach raises. *)
type context_catalog = { cc_roots : int64 list; mutable cc_attached : bool }

(* A collection instance handle: the collection plus the key path
   selecting one stamped copy's table. [collection] returns the root
   (empty-path, live-zone) handle; [at] steps into a copy, one key per
   enclosing For. Mutations and reads take the handle, so the target is
   spelled once. *)
type collection = { cid : int64; cpath : Kaya_wire.value list }

(* One instance of a collection: the table inside the stamped copy
   selected by [path] (the empty path for a live-zone collection).
   Entries keep insertion order, matching the core's rendering. *)
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

(* One representation, arriving — the sum a copy is the record of.
   OCaml has a real sum, so this is a variant and a match is the
   elimination.

   YOU OFFER MANY AND YOU RECEIVE ONE, and the two shapes say so: a
   record here would invite a guest to check five fields where four are
   structurally always empty.

   Bytes ride as [string], OCaml's own binary buffer. [Image] may be a
   RE-ENCODE of what was copied — the hosts convert freely between image
   types — so compare what the image IS, never the bytes it arrived in.
   [Files] is plural INSIDE one representation, the same nesting
   text/uri-list and CF_HDROP already have. *)
(* One collection entry's restored state, as the core states it.
   [ue_state] is None when the step this undoes had no such entry at
   all — "gone" is a state like any other, and the alternative (a
   present/absent flag beside a dummy record) makes every reader check
   two things. *)
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
   it — the identity-tag vocabulary [Node]-flavored occurrences already
   speak, one more time.

   [ut_path] EMPTY means [ut_id] is a live widget's id, the one the app
   holds. A non-empty path means it is a TEMPLATE NODE's id and the path
   is the stamped copy's keys, outermost first: a row's field has no id
   an app could hold, so (node, keys) is the only name it has. Same pair
   a click or an edit on that copy already arrives under. *)
type undo_text = {
  ut_id : int64;
  ut_path : Kaya_wire.value list;
  ut_text : string;
}

(* WHAT THE CORE PUT BACK, and a STATEMENT of it rather than a replay
   of ops: every run says what a thing now IS, so applying it twice is
   the same as applying it once.

   APPLYING AN INVERSE EMITS NOTHING ELSE (the echo doctrine), which is
   why this is fat: it is the ONLY thing an app hears about the step.
   [ud_texts] is the one nothing else could ever carry — restoring a
   typing episode is a programmatic write, so an app that folds
   text_changed into its own model learns of it here or not at all. The
   binding has already reconciled its collection mirror from
   [ud_entries] and [ud_orders] before a handler runs; signals and text
   are not mirrored by this binding (no read-back exists for either, by
   doctrine), so those two runs are the app's own business.

   THE TEXTS RUN IS CARRIED WHOLE and each of its entries NAMES its
   field ([undo_text]), because one step can restore several: a group
   that touched the draft and a row's note hands back both, and an app
   with two rows can only put a note in the right one because the path
   says which. *)
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
  (* The history, per window and NOT one-shot: a history is walked as
     often as the user likes, so these outlive every step (the
     section_selected stance, not the alert's). Each receives the
     group's label — empty for a typing episode, which kaya does not
     name — and the whole restored state. *)
  undone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  redone_handlers : (int64, string -> undo_delta -> unit) Hashtbl.t;
  node_toggles : (int64, Kaya_wire.value list -> bool -> unit) Hashtbl.t;
  (* The collection is the model — the only copy: every mutation op
     edits it and queues the wire delta in the same call, so reads
     (items, count) are exactly the writes. [children] records the
     declared-inside-a-For edges the model purges along when a parent
     entry's copy is torn down. *)
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
     template body (a For body, a When body, a sum eliminator's arms)
     is being DECLARED. Distinct from open_fors (For-only, and keyed by
     collection): every template scope bumps this, When included. *)
  mutable tpl_depth : int;
  (* Signals recomputed from a collection after each of its mutations,
     written into the same transaction. *)
  derived : (int64, (unit -> unit) list) Hashtbl.t;
}

(* One transaction: everything queued inside build (or a handler)
   applies atomically when it returns. Records accumulate reversed.
   The journal holds a snapshot per touched collection, taken on first
   touch, so an abandoned transaction abandons its model edits too. *)
and tx = {
  app : app;
    mutable records : string list;
  (* The undo group's (window, label), kept OUT of [records] because it
     rides at the HEAD of the batch wherever [undoable] was called: a
     handler builds first and names the step once it knows what the step
     was, and the wire's head-of-batch rule must not turn that into a
     footgun. Some twice is a guest bug ("one name per step"). *)
  mutable undo_group : (int64 * string) option;
  mutable journal : (int64 * instance list) list;
  (* Deriveds registered in this transaction: promoted to the app
     registry on submit, abandoned with a rolled-back tx (their signals
     were never created). *)
  mutable pending_derived : (int64 * (unit -> unit)) list;
}

(* The ambient transaction: set for the extent of [build] (handler
   dispatch runs through build, so handlers get it too). Builders
   read it instead of threading a reader, so plain [let] and [;]
   compose scenes — the let*/decl reader retired with this (ratified
   2026-07-22). A builder outside build fails loudly: the price of
   direct style is that this check moves from the type system to
   runtime. Single-threaded by the dispatch discipline. *)
let ambient_tx : tx option ref = ref None

(* The app thread's id, learned when the dispatch loop starts. None
   before then, which is the single-threaded construction phase. *)
let app_thread : int option ref = ref None

(* The OCaml spelling of a rule the handle bindings get from a stale-tx
   check. [ambient_tx] above is a GLOBAL ref, not thread-local, so a
   transaction opened on a background thread would stamp its records
   into the app thread's open transaction -- silently, and interleaved.
   Rust makes that a compile error (its Tx is !Send), Go, Java, C# and
   Swift raise on a transaction that has closed; OCaml has no handle to
   check, so it checks the thread, exactly as Python does.

   Reads and writes need no guard of their own: a signal write outside
   a transaction already fails with "no ambient transaction", which is
   what a background thread gets. *)
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
    model = Hashtbl.create 8;
    fresh = Hashtbl.create 8;
    children = Hashtbl.create 8;
    open_fors = [];
    tpl_depth = 0;
    derived = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records

let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

(* One instance's fresh-key counter, made if this is the first anyone
   has asked. Split out because both the mint and the absorb want the
   same lookup, and a [ref] in the slot means neither has to write the
   table back. *)
let counter_of app cid path =
  let instances = Option.value ~default:[] (Hashtbl.find_opt app.fresh cid) in
  match List.assoc_opt path instances with
  | Some counter -> counter
  | None ->
      let counter = ref 0L in
      Hashtbl.replace app.fresh cid (instances @ [ (path, counter) ]);
      counter

(* The next fresh key for one instance: counter+1, and the counter keeps
   it. Monotonic by construction — nothing else writes it downwards (see
   [insert_fresh]). *)
let mint_key app cid path =
  let counter = counter_of app cid path in
  counter := Int64.add !counter 1L;
  !counter

(* An explicit key, shown to the minter on its way into the table. A
   numeric key at or above the counter carries it up so the next mint
   clears it; anything else moves nothing, having no way to collide with
   an I64. *)
let absorb_key app cid path key =
  match key with
  | Kaya_wire.I64 n ->
      let counter = counter_of app cid path in
      if Int64.compare n !counter > 0 then counter := n
  | _ -> ()

(* The record-time mirror-read guard: a template body records once and
   the core replays it — a model read inside one bakes this moment's
   data into every future stamp, silently dead. Live-zone, handler-tx,
   and build-tx reads stay legal. *)
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

(* Every derived signal rooted at this collection, recomputed and
   written into this transaction. Deriveds hang off root handles, so
   nested-instance mutations cannot change their input. *)
let recompute_derived tx cid path =
  if path = [] then begin
    (match Hashtbl.find_opt tx.app.derived cid with
    | Some fns -> List.iter (fun f -> f ()) fns
    | None -> ());
    List.iter (fun (c, f) -> if c = cid then f ()) (List.rev tx.pending_derived)
  end

(* Run a scene program with a fresh ambient transaction and submit
   it atomically. A program that raises abandons its records, and the
   model abandons the same writes before the exception continues. *)
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
   function safe to call from another thread, and the answer to "how
   does background work reach the UI".

   [build app] is a transaction NOW on the calling thread; [post app] is
   the same transaction SOON on the app thread — so a background thread
   writes ordinary blocking OCaml and hands back only the result:

     ignore (Thread.create (fun () ->
       let data = slow_read () in
       Kaya_app.post app (fun () -> Kaya_app.set status data)) ())

   Signals are ids and are meant to be captured; that is how the posted
   thunk names what to write. A posted thunk runs in its OWN
   transaction, after whatever is running now, so posting from inside a
   handler queues for after and never nests. *)
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

(* Make this transaction ONE undoable step, under [label].

   THE UNIT OF UNDO IS A NAMED GROUP, not every transaction: handlers
   fire per-gesture transactions constantly and most of them are
   consequences rather than intents, and a per-keystroke editor would
   earn one step per character — the exact problem grouping exists to
   solve. So a group is opt-in, which is also what keeps a
   collaborative app free to own its own history (docs/undo-plan.md
   D2, D8).

   CALLABLE ANYWHERE IN THE TRANSACTION, and the marker still rides at
   the head (see [build]): a handler naturally acts first and names the
   step when it knows what the step was. The transaction is the unit —
   this marks the ambient one and does not bracket a region of it, so
   where the call sits changes nothing.

   WHAT A GROUP MAY HOLD is the reactive half — signal writes and
   collection deltas, whose inverse the core derives from state it
   already keeps. Focus is permitted and simply not restored. Anything
   else (a const property write, creating a widget, [clear], showing a
   dialog) fails at apply, naming the op: undo restores state, and
   state is signals plus collections. The app hears the result at
   [~on_undone].

   The window is a labelled optional because each window has its own
   history — Undo in one window has never meant "revert what happened
   in another" — and the primary is the default, as everywhere else. *)
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
   write. One write, after which the user owns the field again: it
   answers with its ordinary [text_changed] and the app's fold takes it
   from there, the same round trip a keystroke makes.

   A write that CHANGES the text of a textarea drops whatever ranges
   were declared over it (see [highlight_ranges]) and spends the field's
   native undo history, which is why undo's D7 treats it as an episode
   boundary. *)
let set_text (Widget id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

(* Set a widget's flex weight within its row/column: 0 is natural
   size, positive weights divide the container's leftover main-axis
   space in proportion (see Prop::Grow in the core). [set_grow] is the
   dynamic path; the declarative spelling is the [~grow] labeled
   argument every constructor takes. *)
let set_grow (Widget id) weight = emit (the_tx ()) (Kaya_wire.tx_set_grow id weight)

(* A widget's accessibility IDENTIFIER: a stable authored key that
   assistive tooling and UI automation address it by, and which is
   NEVER spoken. Universal — every kind carries one. [set_a11y_id] is
   the dynamic path; the declarative spelling is the [~a11y_id] labeled
   argument every constructor takes, like [~grow]. *)
let set_a11y_id (Widget id) value = emit (the_tx ()) (Kaya_wire.tx_set_a11y_id id value)

(* What an assistive client SPEAKS for a widget. Universal, and
   deliberately separate from the identifier — an automation key is not
   a spoken name. Leave it unset to keep whatever the platform derives
   from the control's own content; setting it OVERRIDES that, so a
   button whose caption already reads well needs nothing here.
   [set_a11y_label] is the dynamic path; [~a11y_label] is the
   declarative spelling. *)
let set_a11y_label (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_label id value)

(* What ACTIVATING this widget does — the platforms' hint (Apple
   defines it as the result of performing an action; Android carries it
   as the click action's label). Write a VERB PHRASE. Activation kinds
   only; the root rejects it elsewhere, which is why [~a11y_hint] rides
   button, checkbox, select and radio and not [set_a11y] below. *)
let set_a11y_hint (Widget id) value =
  emit (the_tx ()) (Kaya_wire.tx_set_a11y_hint id value)

(* The two universal props as they ride every constructor: applied
   together, in one place, so a new constructor cannot pick up [~grow]
   and quietly miss these. *)
let set_a11y ?a11y_id ?a11y_label w =
  Option.iter (fun v -> set_a11y_id w v) a11y_id;
  Option.iter (fun v -> set_a11y_label w v) a11y_label

(* A container's inter-child gap (main axis, DIP; the normalized
   default is 8). Containers only — the scene rejects it anywhere
   else. [set_spacing] is the dynamic path; the declarative spelling
   is the [~spacing] labeled argument on the container. *)
let set_spacing (Widget id) gap = emit (the_tx ()) (Kaya_wire.tx_set_spacing id gap)

(* A container's cross-axis child placement (the align spec enum; the
   normalized default is [Start]). Containers only; [Baseline] is
   rows-only — the scene rejects misuse at the root. [set_align] is
   the dynamic path; the declarative spelling is the [~align] labeled
   argument on the container. *)
type align = Start | Center | End | Stretch | Baseline

let align_wire = function
  | Start -> 0L
  | Center -> 1L
  | End -> 2L
  | Stretch -> 3L
  | Baseline -> 4L

let set_align (Widget id) a = emit (the_tx ()) (Kaya_wire.tx_set_align id (align_wire a))
let bind_text (Widget id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_text id s)
let set_checked (Widget id) checked = emit (the_tx ()) (Kaya_wire.tx_set_checked id checked)
let bind_checked (Widget id) (Signal s) = emit (the_tx ()) (Kaya_wire.tx_bind_checked id s)

(* An image's content: one registration copy of the encoded bytes into
   core-owned memory. The handle is consumed by the next submit from
   this guest, referenced or not — so every write re-registers — and
   the caller's bytes are free to drop the moment this returns. *)
let set_source (Widget id) data =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_set_source id (Kaya_runtime.register_blob data))

let bind_source (Widget id) (Signal s) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_bind_source id s)

(* One-shot commands: momentary verbs into widget-owned state, riding
   the open transaction like any record — the insert and the clear
   beside it submit together or not at all. Fire-and-forget: no model
   state, nothing to journal; the widget answers through its normal
   occurrence path (a clear arrives back as text_changed "" and the
   app's draft fold empties itself). Commands take a widget only — a
   node is a blueprint, and a blueprint has nothing to clear (the
   type-level arm of the scene's own template rejection). *)

(* Drop an entry's content now (the field stays authoritative). *)
let clear (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_clear)

(* Give this widget the keyboard focus. *)
let focus (Widget id) = emit (the_tx ()) (Kaya_wire.tx_widget_command id Kaya_wire.command_focus)

(* --- Text ranges: the three primitives an editor cannot write itself -

   A RANGE IS A PAIR OF UTF-8 BYTE OFFSETS [(start, stop)] into the
   widget's current text, half-open — Python's own [slice] pair, and the
   spec's field names. OCaml's [string] IS a byte sequence, so the
   offsets an app already has are the offsets kaya wants: [String.length],
   [String.index_from] and any literal search over the document count
   the same units the wire carries, and this binding converts nothing.
   (Four of the nine guest languages are byte-native like this; the
   other five convert once at their own edge — scratchpad/ranges-units.md
   §5.)

   THE OFFSETS ARE [int] AND NOT [int64] deliberately, unlike the ids
   these functions take: an id is an opaque handle the binding mints,
   while an offset is arithmetic the APP does with the stdlib, and the
   stdlib counts in [int]. A range surface in [int64] would put an
   [Int64.of_int] at every call site of a search loop.

   ONE PAIR TYPE FOR ALL THREE VERBS, so the value flows: the list a
   find handed [highlight_ranges] is the list [List.nth_opt] takes one
   out of for [select_range]. Labelled [~start]/[~stop] arguments were
   the alternative and would have needed the pair anyway (the set is a
   LIST), leaving two spellings for one datum.

   THE CORE VALIDATES AND REFUSES, at one chokepoint, before any of this
   reaches a platform: [start <= stop], [stop <= String.length text], and
   both endpoints on a code-point boundary. A malformed offset is an
   app-programming error of the same class as ill-formed text on the
   wire, and it gets the same loud treatment — the five platforms answer
   one in four different ways and macOS ABORTS THE PROCESS (an out-of-range
   NSTextStorage attribute is an NSRangeException, exit 134). An endpoint
   inside a grapheme cluster is NOT refused: the platforms disagree about
   what a grapheme is, so the range covers exactly the code points it
   names and a platform may widen what it paints. *)

(* DECLARE the decorated ranges of a textarea, replacing whatever was
   declared before; [[]] is the clear.

   APP-OWNED AND NEVER TRACKED (docs/ranges-plan.md D2). A declared set
   is bound to the text it was declared against: the first edit of any
   kind — a keystroke, a programmatic write, a native undo — DROPS it,
   with nothing said, and the app re-declares from the fold [~on_change]
   already drives. That is the uncontrolled contract the text itself
   has, and it is why kaya ships no range-adjustment machinery: tracking
   ranges across edits is editor-component work.

   kaya ships no search either. What to decorate is the app's question —
   a find engine, a find bar and a regex dialect belong to the text
   editor — and the five lines that answer it live in the guest:

     let hits = find_all !doc needle in
     highlight_ranges editor hits *)
let highlight_ranges (Widget id) ranges =
  emit (the_tx ())
    (Kaya_wire.tx_highlight_ranges id (List.length ranges)
       (List.concat_map
          (fun (start, stop) ->
            [ Kaya_wire.I64 (Int64.of_int start); Kaya_wire.I64 (Int64.of_int stop) ])
          ranges))

(* Put the textarea's selection at one range; [(at, at)] is a caret.

   REFUSED WHILE THE USER IS COMPOSING through an input method, in every
   backend (D4). Honouring it commits the marked text into the document
   and into the app's own model mid-word — measured on macOS — which is
   data loss shaped like a feature. The refusal is a NO-OP and not an
   exception: composition state is on no kaya channel and never will be,
   so the same call is honoured one millisecond and refused the next,
   and an app cannot avoid the race. Ask again after the next
   [~on_change], which is what the end of a composition announces. *)
let select_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_select_range id (Int64.of_int start) (Int64.of_int stop))

(* Scroll the textarea so a range is inside the viewport. A PURE
   EFFECT: no state moves, the selection is untouched, and undo does not
   put the scroll back — undo restores state, not where you were
   looking. How much context lands around the range is the platform's
   own scroll behaviour; the observable kaya fixes is containment. *)
let reveal_range (Widget id) (start, stop) =
  emit (the_tx ())
    (Kaya_wire.tx_reveal_range id (Int64.of_int start) (Int64.of_int stop))

let add_child (Widget parent) (Widget child) =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_child parent child)

(* --- Construction sugar: the tree reads as a tree -------------------

   Co-located constructors (props and handlers at the declaration
   site) and containers taking their children, so

     let* check = widget kind_checkbox in
     let* () = bind_checked_field check todo_done_ in
     ...
     let* row = widget kind_row in
     let* () = add_child row check in
     let* () = add_child row title in

   reads instead as

     let* r = row [ checkbox ~on_toggle (); label ~bind:status () ] in

   Everything lowers eagerly to the same records in the same order —
   children created first, then the container, then the add_childs.
   Sugar is syntax over the record calls, never a scene value the
   binding interprets later (the design's no-guest-AST rule); the
   explicit floor above stays for whoever wants one call ≈ one record. *)

let button ?grow ?a11y_id ?a11y_label ?a11y_hint ?text ?on_click () =
  let tx = the_tx () in
  let w = widget Kaya_wire.kind_button in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  Option.iter (fun v -> set_a11y_hint w v) a11y_hint;
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

let label ?grow ?a11y_id ?a11y_label ?text ?bind () =
  let w = widget Kaya_wire.kind_label in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
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

(* A slider over min..max at value. Uncontrolled, like the entry: the
   bar owns its position and reports each change to [on_change] (the
   new value as a float). [~bind] takes a float signal for the
   position instead of a constant — the programmatic write path
   ([write] fans out to the control; property writes never echo an
   occurrence, so a handler's own writes cannot loop back at it). *)
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

(* An image displaying encoded bytes (PNG, JPEG, ...): the toolkit
   decodes natively, and decode failure renders the placeholder, never
   a crash. [source] takes the encoded bytes — one registration copy
   into core memory; the handle is consumed by the next submit, and
   the guest's bytes are free to drop the moment the call returns.
   [bind] takes a Blob signal instead. Display-only, like a label. *)
let image ?grow ?a11y_id ?a11y_label ?source ?bind () =
  let w = widget Kaya_wire.kind_image in
  Option.iter (fun g -> set_grow w g) grow;
  set_a11y ?a11y_id ?a11y_label w;
  Option.iter (fun data -> set_source w data) source;
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
   inter-child gap. *)
let container ?grow ?a11y_id ?a11y_label ?spacing ?align kind children () =
  let parent = widget kind in
  Option.iter (fun g -> set_grow parent g) grow;
  set_a11y ?a11y_id ?a11y_label parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  Option.iter (fun a -> set_align parent a) align;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A grid from its children, laid out row-major into [~columns]
   columns — each column takes its NATURAL width, aligned across rows
   (the thing nested rows cannot express). [~spacing] is the
   inter-cell gap on both axes. The columns record lands BEFORE the
   add_childs (backends re-flow either way). *)
let grid ~columns ?grow ?a11y_id ?a11y_label ?spacing children () =
  let tx = the_tx () in
  let parent = widget Kaya_wire.kind_grid in
  let (Widget id) = parent in
  emit tx (Kaya_wire.tx_set_columns id (float_of_int columns));
  Option.iter (fun g -> set_grow parent g) grow;
  set_a11y ?a11y_id ?a11y_label parent;
  Option.iter (fun s -> set_spacing parent s) spacing;
  List.iter (fun child -> add_child parent (child ())) children;
  parent

(* A spacer: PURE SUGAR for an empty grown column — it consumes the
   leftover main-axis space between its siblings. *)
let spacer ?(grow = 1.0) () =
  let w = widget Kaya_wire.kind_column in
  set_grow w grow;
  w

let column ?grow ?a11y_id ?a11y_label ?spacing ?align children =
  container ?grow ?a11y_id ?a11y_label ?spacing ?align Kaya_wire.kind_column children

(* A vertical scroll viewport over EXACTLY ONE child (the signature
   says so; the scene enforces it too). Pass [~grow] so the enclosing
   track CONSTRAINS it — an unconstrained viewport hugs its content
   and nothing overflows. *)
let scroll ?grow ?a11y_id ?a11y_label children =
  container ?grow ?a11y_id ?a11y_label Kaya_wire.kind_scroll children

let row ?grow ?a11y_id ?a11y_label ?spacing ?align children =
  container ?grow ?a11y_id ?a11y_label ?spacing ?align Kaya_wire.kind_row children

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

(* Insert a value under a key the binding authors, and hand the key
   back — [let key = insert_fresh todos (Str draft)].

   FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain identity
   and guest-chosen (DESIGN.md, the update algebra), so anything that
   already HAS a name passes it to [insert] — today and always. This is
   the other case, and it is the common one in a form: the app has a
   title and nothing else, and the alternative is a hand-spelled counter
   beside the collection, which in OCaml is an [int ref] that outlives
   every handler that adds, and whose safety rests on a never-rewind
   rule nobody wrote down.

   ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key is
   [I64] and is counter+1. An instance is a table — the live-zone
   collection, or one stamped copy selected by [at] — and keys are
   unique within one, so that is what the counter is per.

   MIXING IS SAFE BY ABSORPTION: an explicit [insert] whose key is an
   [I64] at or above the counter carries it up, so a later mint clears
   every hand-chosen numeric key already in the table. A [Str] key
   cannot collide with an [I64] at all and moves nothing.

   NO DECREMENT IS EXPRESSIBLE, and that is the whole safety argument.
   Undo and redo replay captured keys inside the core and never re-enter
   this path ([absorb_undo] writes the mirror directly), so a history
   walk never moves the counter; an abandoned transaction does not move
   it back either — the rollback journal restores the model, not the
   counter, so a key can never be handed out twice. A fresh key is fresh
   forever.

   The result is meaningful even where a scene discards it: [ignore] is
   OCaml's spelling for "inserted for effect". *)
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

(* The same checks the scene makes, made where the guest can see the
   stack: a missing key or anchor is a guest bug, never a fallback.
   Moving an entry before itself is a no-op, and nothing travels. *)
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

(* Reposition an entry before another's: order is collection data, so
   the model reorders and the wire carries the same keys-only delta.
   Keys, never indices. *)
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

(* Records: a first-class descriptor is the schema — the honest floor
   a future ppx deriver ([@@deriving kaya_gen]) will generate. One
   descriptor drives the schema, the conversions, and the field tokens,
   so keeping them adjacent is the discipline; the deriver will delete
   even that. *)
type 'a record_type = {
  rt_schema : int list;
  rt_to_values : 'a -> Kaya_wire.value list;
  rt_of_values : Kaya_wire.value list -> 'a;
}

(* A typed projection: one field of a record type, by wire position.
   The phantom pins the OCaml type, so bind_checked_field rejects a
   (_, string) field at compile time. *)
type ('a, 'v) field = {
  fd_index : int;
  fd_to_value : 'v -> Kaya_wire.value;
}

let str_field index : ('a, string) field =
  { fd_index = index; fd_to_value = (fun s -> Kaya_wire.Str s) }

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

(* [insert_fresh] for a record collection: the binding authors the key
   and hands it back. Same contract, same counter — see [insert_fresh]
   for the whole of it. *)
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

(* A signal recomputed from this collection's entries after every
   mutation, written into the same transaction — the items-left label
   with no handler remembering to update it. The function is pure
   presentation: entries in, one value out; the core sees an ordinary
   signal. *)
let derive rc compute =
  let tx = the_tx () in
  let s = signal (compute (record_items rc)) in
  tx.pending_derived <-
    (rc.rc_handle.cid, fun () -> write s (compute (record_items rc)))
    :: tx.pending_derived;
  s

(* Mount into the default window; per-window targets arrive with the
   window vocabulary. *)
(* Set a window's attributes in one construct — the attribute set is
   EXACTLY [create_window]'s (a window's attributes ride its window
   construct; the primary differs only in having no creation moment —
   the process owns it): [window ~title:"sections"
   ~sections_presentation:(Int64.of_int
   Kaya_wire.sections_presentation_bar) ()]. *)
let window ?title ?width ?height ?veto_close ?dirty ?list_detail
    ?sections_presentation
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus ?(id = 0L) () =
  let tx = the_tx () in
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_window_title id t)) title;
  Option.iter (fun w -> emit tx (Kaya_wire.tx_set_window_width id w)) width;
  Option.iter (fun h -> emit tx (Kaya_wire.tx_set_window_height id h)) height;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_veto_close id v)) veto_close;
  (* [~dirty] declares that this surface holds unsaved work; the backend
     spells its own platform's affordance (the dot in the close button on
     macOS, a leading [*] in the rendered caption on Windows, a bullet in
     the GTK header bar, nothing on the phones, which have none —
     docs/dirty-plan.md D2/D4). THE TITLE STRING IS NEVER TOUCHED: a
     marker composed into the app's own title is Qt's [*] template, the
     named rejection (D1).

     It arms NOTHING (D3). The "unsaved changes, close anyway?" flow is
     [~veto_close] plus [show_alert], composed by the app, and the two
     props are orthogonal — either rides this construct without the
     other.

     Nothing infers it: writing the document's signal does not raise the
     mark, and saving does not lower it. Say both, in the one
     transaction the handler already is — [window ~dirty:true ()] is the
     OCaml spelling of setting it later, since a window attribute never
     lives as a loose function outside this construct. *)
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_dirty id v)) dirty;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_list_detail id v)) list_detail;
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
     unification rule): [~menus] realizes its thunks left to right —
     the curried-children convention, [w file] for a retained handle
     — and appends each top-level grouping node (menu or radio_group)
     to this window's command catalog. Append-only, at any time. *)
  Option.iter
    (List.iter (fun th ->
         let (MenuItem m) = th () in
         emit tx (Kaya_wire.tx_menubar_append id m)))
    menus

(* Create an auxiliary window (capability-gated: phone hosts reject
   at the root); materializes hidden, [mount_in] presents. Labeled
   optional arguments are the OCaml spelling — the same set [window]
   takes. *)
let create_window ?title ?width ?height ?veto_close ?dirty
    ?sections_presentation
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_create_window id);
  (* [~dirty] rides the creation like every other window attribute: an
     auxiliary editor can be born with unsaved work, and the mark has to
     survive the surface not existing yet. *)
  window ?title ?width ?height ?veto_close ?dirty ?sections_presentation
    ?on_close_requested ?on_closed ?on_undone ?on_redone ?menus ~id ()

(* Close and forget an auxiliary window — also the veto grammar's
   confirmation and the reconciliation after a chrome close. *)
let destroy_window id = emit (the_tx ()) (Kaya_wire.tx_destroy_window id)

(* Mount a root into a specific window; mounting presents. *)
let mount_in window (Widget root) = emit (the_tx ()) (Kaya_wire.tx_mount window root)

(* Push a navigation entry onto the primary surface's stack (entry
   ids are guest-allocated in the shared surface namespace, the
   [create_window] discipline); materializes covered, [mount_in]
   presents it. Labeled optional arguments are the OCaml spelling:
   [push_entry ~title:"detail" ~intercept_back:true 7L].

   The handlers ride the push (per-entry, the [show_alert]
   ~on_result precedent — no id inspection anywhere): [~on_popped]
   fires when the user's back affordance pops THIS entry natively
   (post-fact; a programmatic [pop_entry] does not fire it — its
   caller already knows) and retires with the one pop;
   [~on_back_requested] fires per back request while intercept_back
   is armed — nothing has popped; answer with [pop_entry] to
   agree. *)
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
let add_section ?(window = 0L) ?title ?on_selected id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_add_section window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_section_title id t)) title;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.section_selected id f)
    on_selected

(* Select a section programmatically: configuration, never echoes
   [~on_selected] (the echo doctrine). *)
let select_section ?(window = 0L) id =
  let tx = the_tx () in
  emit tx (Kaya_wire.tx_select_section window id)

(* Pop the window's top navigation entry and forget its tree — also
   the back-veto grammar's confirmation after [on_back_requested].
   Popping an empty stack is a scene error. *)
let pop_entry ?(window = 0L) () = emit (the_tx ()) (Kaya_wire.tx_pop_entry window)

(* Request a modal alert (the request/result grammar); labeled
   arguments are the OCaml spelling:
   [show_alert ~title ~message ~actions:["Delete"; "Archive"]
      ~cancel:"Keep" ~on_result:(fun choice tx -> ...) tx]. The
   result handler rides the REQUEST (the widget-handler precedent)
   and retires with its one answer — choice is an action index (0 or
   1) or [alert_cancel], every platform-native dismissal. Ids are
   binding-allocated; the call returns the id for the floor-minded.
   At most two actions (the platform floor); [~cancel] is required
   by the signature — the slot every platform-native dismissal (Esc,
   back, outside tap) resolves to, and no binding invents a default
   label. One alert may be live per process; show the next from the
   handler. *)
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

(* The alert_choice cancel sentinel, for handlers: the wire u32
   0xFFFFFFFF as an OCaml int32 (-1l). Deliberately not an index. *)

(* The filters encoding, written ONCE because two requests carry it:
   alternating label and space-separated extensions. The picker and the
   save dialog share the wire's shape, so they share the code that
   builds it — a second copy is how the two drift apart on the day one
   of them starts validating. *)
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

(* Ask the platform for files. THE PICK, NOT THE OPEN — the result
   carries handles you redeem later, so the name says [pick]
   (DESIGN.md, File dialogs).

   [filters] is a list of (label, space-separated extensions),
   ADVISORY on every platform: a default view rather than a guarantee,
   so the guest still validates what it got.

   [on_result] fires exactly once and retires with its answer. CANCEL
   IS THE EMPTY LIST, faithfully: no platform can confirm an empty
   selection. One dialog may be live per process; show the next from
   the handler. *)
let pick_files ?(window = 0L) ?(filters = []) ?on_result () =
  pick ~window ~filters ~multiple:true ?on_result ()

(* The single-file spelling. The floor always returns a LIST; this only
   asks the platform for one, so the handler receives zero or one. *)
let pick_file ?(window = 0L) ?(filters = []) ?on_result () =
  pick ~window ~filters ~multiple:false ?on_result ()

(* Ask the platform WHERE TO SAVE. The picker's twin, and deliberately
   the same grammar (docs/save-plan.md D2): the id comes from the same
   counter and so from the same one-live-dialog-per-process slot, the
   answer arrives as the picker's own result, and the registration
   retires with it.

   [suggested_name] is the name the dialog OPENS with, and it rides as a
   plain argument rather than an optional one — a save dialog with an
   empty name box is one the platform will not let the user complete.
   Every platform TAKES it and none guarantees it: the user renames it,
   and Android appends an extension matching the mime type at creation.
   So read the name you GOT — or, better, do not read a name at all and
   read the bytes.

   [filters] is the picker's advisory list, unchanged in meaning. Beware
   on macOS: with allowed content types set, NSSavePanel appends the
   first allowed extension to a name that has none.

   [on_result] fires exactly once with [Some destination] or [None].
   CANCEL IS [None], and the narrowing from the wire's list happens
   HERE, not in the guest: "exactly one locator or none" is a fact of
   the request — no platform's save dialog names two destinations — and
   a guest should not have to re-derive it from a list length.

   WHAT YOU GET BACK OPENS EMPTY, on every platform (docs/save-plan.md
   D1). A destination need not exist yet: macOS, GTK and Windows answer
   with a name for a file nobody has made, and macOS does not truncate
   even when the user picks Replace, while Android and iOS hand back a
   document that already exists. The core absorbs that — the handle
   opens with CREATE — so [file_mode_write] on a fresh destination
   succeeds and yields an empty file everywhere, and the guest writes
   against the one behaviour. It is NOT a fourth file mode: creation is
   a property of the destination the dialog promised, never of the
   caller's intent. *)
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

(* --- The clipboard (DESIGN.md, Clipboard) ---------------------------

   A clip is not a string: every host models it as ONE item available in
   several types, with the consumer taking the richest it understands.
   So COPY TAKES A RECORD — optional labelled arguments being how OCaml
   spells one, and what makes at-most-one-per-kind structural rather
   than a duplicate check — and the two answers are a SUM.

   kaya DERIVES NOTHING between representations. Whether list bullets
   survive html-to-text is the app's decision, and a bad
   auto-derivation degrades every paste into a plain field silently. *)

(* Join an accept list: the closed kinds by name plus any custom ids,
   space separated.

   A LIST AND NOT A MASK, because half the set is open-ended. A custom
   format that could be written and never accepted would be an escape
   hatch that only opens outward, and round-tripping an app's own data
   is the whole reason to have one. Ids reach every platform's registry
   verbatim, so they carry no spaces — which is what makes the join
   unambiguous, and what this refuses to let you break. *)
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
   representations as the call fills in.

   [files] takes picked-file handles: copying a file and picking one are
   the same currency, so a picked file goes straight on and the bytes
   never move through kaya. [custom] is the one plural field with names,
   since several app-defined formats are legitimate.

   The wire order is kaya's, not this call's — descending richness,
   which is preference order on every host that has one. *)
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

(* Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE,
   named for what it is rather than for pasting.

   A user's paste arrives at the widget's hook and costs nothing; this
   asks without a gesture, which the platforms have deliberately made
   expensive: iOS 16 PROMPTS when the content came from another app and
   blocks until the user answers, Android returns nothing unless the app
   has focus, and Wayland delivers no offer to an unfocused client.
   Reach for this to detect a URL or import from the clipboard, never to
   implement Paste — that is the Paste command, and it is free.

   [on_result] fires exactly once with [Some rep] or [None], and the
   registration retires with it — the alert's grammar. *)
let read_clipboard ?on_result accepting =
  let tx = the_tx () in
  let app = tx.app in
  app.next_clipboard_read <- Int64.add app.next_clipboard_read 1L;
  let id = app.next_clipboard_read in
  Option.iter (fun f -> Hashtbl.replace app.clipboard_handlers id f) on_result;
  emit tx (Kaya_wire.tx_read_clipboard id (Kaya_wire.Str (accept_list accepting)));
  id

(* Declare what a widget takes from a paste — the closed kinds by name
   ("text", "html", "image", "files") plus any custom format ids.

   ONE DECLARATION, THREE JOBS: it drives whether the Paste command is
   live while this widget is focused, it filters what can reach the
   paste hook, and on Android it IS the native registration
   (setOnReceiveContentListener takes the mime types on the view).
   Per-widget because whether Paste should be enabled is the
   INTERSECTION of what the clipboard offers and what the FOCUSED target
   takes.

   DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that declares
   nothing gets the platform's own insertion and reports it through the
   ordinary change path, which is why a plain text editor writes none of
   this and has working cut, copy and paste. *)
let set_accepts (Widget id) kinds =
  emit (the_tx ()) (Kaya_wire.tx_set_accepts id (accept_list kinds))

let alert_cancel = Kaya_wire.alert_choice_cancel



let mount (Widget root) = emit (the_tx ()) (Kaya_wire.tx_mount 0L root)

(* --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

   The curried-children convention extends to items: creators end in
   [()], omitted unit is the child form, and a grouping creator's list
   holds bare partial applications the parent realizes left to right —
   [menu ~label:"File" [ item ~label:"Save" ~shortcut:"primary+s"
   ~on_activate:h; ... ] ()]. The window construct's [~menus] is the
   bar anchor; [context_menu]/[context_catalog] are the noun anchors;
   the dynamic tier below ([set_menu_label], [menu_append], ...)
   reopens a retained handle in any later transaction — the
   append-at-any-time discipline. *)

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

(* The shared optional-prop tail: [?enabled] a constant,
   [?bind_enabled] a Bool signal (the labeled-optional family — one
   label per (prop, source) pair), [?icon] the blob channel. *)
let menu_prop_tail id ?enabled ?bind_enabled ?icon () =
  let tx = the_tx () in
  Option.iter (fun e -> emit tx (Kaya_wire.tx_set_menu_enabled id e)) enabled;
  Option.iter
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_enabled id s))
    bind_enabled;
  Option.iter
    (fun data ->
      emit tx (Kaya_wire.tx_set_menu_icon id (Kaya_runtime.register_blob data)))
    icon

(* An action — a leaf command firing exactly one menu_activated
   occurrence (menu click OR its shortcut: ONE occurrence, one
   dispatch path; [~on_activate] rides the declaration and covers
   both). [~on_activate_node] is the template-node flavor: an item
   attached to a stamped copy reports the copy's key path, outermost
   first — the keys ARE the noun. The shortcut is canonicalized by the
   binding's one parser; the root judges its anchor (window catalogs
   only). *)
let item ?shortcut ?enabled ?bind_enabled ?icon ?primary ?role ?on_activate
    ?on_activate_node ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_action (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  Option.iter (fun r -> emit tx (Kaya_wire.tx_set_menu_role id r)) role;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ();
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
let toggle ?checked ?bind_checked ?enabled ?bind_enabled ?icon ?shortcut
    ?on_toggle ?on_toggle_node ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_toggle (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  Option.iter (fun c -> emit tx (Kaya_wire.tx_set_menu_checked id c)) checked;
  Option.iter
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_checked id s))
    bind_checked;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_toggled id f) on_toggle;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.menu_toggled_node id f)
    on_toggle_node;
  MenuItem id

(* One labeled radio option, appended in declaration order — the order
   IS the index vocabulary the group's value selects over. *)
let option ?enabled ?bind_enabled ?icon ?shortcut ~label () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_radio_option (Some label) in
  Option.iter (fun s -> emit tx (Kaya_wire.tx_set_menu_shortcut id s)) shortcut;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ();
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
   [~menus], or nested as a bare partial application in a parent's
   child list (one nested grouping level is the cap, root-checked).
   Disabling a menu disables its subtree (the inherited-disabled
   contract). *)
let menu ?enabled ?bind_enabled ?icon ~label children () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_menu (Some label) in
  realize_menu_children tx id children;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ();
  MenuItem id

(* A radio group — the Choice contract with the platform's checkmark
   idiom, admissible wherever a menu grouping node is. The children
   are [option]s only (the closed grammar, root-checked); [~value] /
   [~bind_value] is the selected 0-based index, applied AFTER the
   options so the index has options to address (programmatic writes
   are quiet); [~on_select] receives each USER pick's new index, and
   [~on_select_node] the stamped keys first. *)
let radio_group ?value ?bind_value ?enabled ?bind_enabled ?icon ?on_select
    ?on_select_node ~label options () =
  let tx = the_tx () in
  let id = alloc_menu_item Kaya_wire.menu_kind_radio_group (Some label) in
  realize_menu_children tx id options;
  Option.iter
    (fun v -> emit tx (Kaya_wire.tx_set_menu_value id (float_of_int v)))
    value;
  Option.iter
    (fun (Signal s) -> emit tx (Kaya_wire.tx_bind_menu_value id s))
    bind_value;
  menu_prop_tail id ?enabled ?bind_enabled ?icon ();
  Option.iter (fun f -> Hashtbl.replace tx.app.menu_selected id f) on_select;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.menu_selected_node id f)
    on_select_node;
  MenuItem id

(* A context menu on a LIVE widget: the same item vocabulary scoped to
   a NOUN, with the platform's own gesture (right-click, long-press).
   Calling it again appends more roots. The editable text controls
   (entry, textarea) reject attachment at the root; context items take
   no shortcuts (root-checked — the anchor is decided here, after the
   items exist). *)
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

(* The phone-bar promotion hint (actions only — root-checked).
   Flipping it recomputes the promoted set deterministically; INERT on
   desktops — not a toolbar grammar. *)
let set_menu_primary (MenuItem id) on =
  emit (the_tx ()) (Kaya_wire.tx_set_menu_primary id on)

(* The closed standard-command vocabulary (DESIGN.md, Menus): macOS
   places this one in the application menu, and every other host leaves
   the item where the app declared it. *)
(* A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
   are. The accept list is open-ended — a custom format id is any
   app-chosen string — so the four closed kinds cannot be a mask; but
   they can be spelled once here instead of quoted at every call site.
   A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
   clipboard will ever offer, so Paste stays dead and the paste hook
   never fires, with nothing to see anywhere. A custom id has no
   constant by nature — the app that defines it names it. *)
let accept_text = "text"
let accept_html = "html"
let accept_image = "image"
let accept_files = "files"

let role_settings = "settings"

(* The three clipboard commands. They lower to the platform's own, act
   on the FOCUSED widget, and work out their own enablement from what
   the clipboard offers and what that widget accepts.

   GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
   widget knows what is selected, so an app cannot assemble the payload
   for "copy the selected text" out of the data layer. Copy of a
   selection is therefore necessarily a command, and Paste is its
   mirror. [copy] and [read_clipboard] are for overriding that default
   and for targets with no native behaviour. *)
let role_cut = "cut"
let role_copy = "copy"
let role_paste = "paste"

(* The two history commands. ONE Edit>Undo covers both tiers: it asks
   the focused text widget's own stack first and the window's ledger
   otherwise, and works out its own enablement from the same question,
   live at activation (docs/undo-plan.md D1, D6). An app declares the
   items and writes nothing else — a scene that wants a step in the
   ledger names it with [undoable]. *)
let role_undo = "undo"
let role_redo = "redo"

(* Declare a retained action a standard command (actions only —
   root-checked). Uniform declaration, per-host placement; a role never
   invents a chord. Const-only. *)
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
   append-at-any-time discipline:
   [menu_append file [ item ~label:"Publish" ~primary:true
   ~on_activate:h ]]. The root re-validates each appended subtree in
   the item's real anchor context (depth, shortcuts, duplicates). *)
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

(* Sums: a variant type whose constructors carry inline records. The
   descriptor is what [@@deriving kaya_gen] emits for such a type — one
   record shape per constructor, the discriminant, both conversions —
   and the generated per-sum eliminator (post_each ~note ~todo) calls
   [each_sum] with its arms; the labelled arguments are required, so
   totality is a compile error there, and the scene checks it again. *)
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

(* [insert_fresh] for a sum collection: the value's own constructor is
   still what is witnessed onto the wire; only the key comes from the
   binding. Same contract, same counter — see [insert_fresh]. *)
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

(* The eliminator's mechanism: (variant, arm) pairs in declaration
   order, each arm a Tpl program. Only the generated per-sum wrappers
   call this — their required labelled arguments are what makes
   totality a compile error. *)
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

  let widget kind =
    let tx = the_tx () in
    let id = alloc_node tx in
    emit tx (Kaya_wire.tx_create_widget id kind);
    Node id

  let set_text (Node id) text = emit (the_tx ()) (Kaya_wire.tx_set_text id text)

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

  (* Bind an image's source to one field of the element; a (_, bytes)
     field only — the phantom pins it at compile time. Per-entry
     content: the core stamps each copy with its entry's blob. *)
  let bind_source_field ?(level = 0) (Node id) (fd : (_, bytes) field) =
    emit (the_tx ()) (Kaya_wire.tx_bind_source_element ~level ~field:fd.fd_index id)

  let add_child (Node parent) (Node child) =
    emit (the_tx ()) (Kaya_wire.tx_add_child parent child)

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

  let when_ (Signal sid) body () =
    let tx = the_tx () in
    let id = alloc_node tx in
    emit tx (Kaya_wire.tx_create_when id sid);
    let result = in_tpl_scope tx.app body in
    emit tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  (* The construction sugar, template flavor: bindings take fields, and
     handlers receive the stamped copy's keys first. *)
  let button ?text ?on_click () =
    let n = widget Kaya_wire.kind_button in
    Option.iter (fun x -> set_text n x) text;
    (match on_click with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_handlers id handler
    | None -> ());
    n

  let label ?text ?bind_field ?(level = 0) () =
    let n = widget Kaya_wire.kind_label in
    Option.iter (fun x -> set_text n x) text;
    Option.iter (fun fd -> bind_text_field ~level n fd) bind_field;
    n

  let checkbox ?checked_field ?(level = 0) ?on_toggle () =
    let n = widget Kaya_wire.kind_checkbox in
    Option.iter (fun fd -> bind_checked_field ~level n fd) checked_field;
    (match on_toggle with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace (the_tx ()).app.node_toggles id handler
    | None -> ());
    n

  (* The template image: [bind_field] takes a (_, bytes) field of the
     element — each stamped copy displays its own entry's bytes. *)
  let image ?bind_field ?(level = 0) () =
    let n = widget Kaya_wire.kind_image in
    Option.iter (fun fd -> bind_source_field ~level n fd) bind_field;
    n

  (* Containers, the outer-zone convention: children are partially
     applied creators ([unit -> node] thunks), realized left to
     right; [()] realizes, omitting it nominates a child. *)
  let container kind children () =
    let parent = widget kind in
    List.iter (fun child -> add_child parent (child ())) children;
    parent

  let column children = container Kaya_wire.kind_column children
  let row children = container Kaya_wire.kind_row children

  (* Attach a live-built context catalog ([context_catalog]) to a
     template node: every stamped copy shows the same catalog, and
     each activation carries that copy's key path — the keys ARE the
     noun (received by the [_node] handler flavors). An item takes
     exactly one anchor, so a second attach of the same catalog
     raises here. *)
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
let on_click_node app (Node id) (handler : Kaya_wire.value list -> unit) =
  Hashtbl.replace app.node_handlers id handler

(* Register a change handler for a live entry: the widget owns its text
   and reports each edit here; the app folds the text into its own
   state — there is no read-back, by doctrine. *)
(* Take pasted content at a live widget.

   COSTS NOTHING ON ANY PLATFORM, unlike [read_clipboard]: a paste is a
   user gesture, so it is its own authorisation — iOS raises no prompt
   and the focus rules are satisfied by construction. Only fires for a
   widget that declared what it accepts. *)
let on_paste app (Widget id) (handler : representation -> unit) =
  Hashtbl.replace app.widget_pastes id handler

(* A paste onto a stamped copy: the handler also receives the copy's key
   path, outermost first. One record kind, the path deciding — exactly
   as a click on a stamped row is one record with a click on a live
   widget. *)
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

(* Run everything posted, each as its own transaction, in order.

   The batch is taken and the lock released BEFORE any of it runs, so a
   thunk that posts again lands in the NEXT batch. Holding the lock
   across the calls would let a self-posting thunk drain forever and
   starve the occurrence loop. *)
let drain_posted app =
  Mutex.lock app.post_lock;
  let batch = app.posted in
  app.posted <- [];
  Mutex.unlock app.post_lock;
  List.iter (fun program -> dispatch app program) batch

(* Turn the decoder's kind-and-values into the sum, or None.

   EMPTY IS THE UNIVERSAL NO: None covers a denied prompt on iOS, an
   unfocused reader on Android or Wayland, an empty clipboard, and
   content in no representation this read accepted. The guest is not
   told which, because the platforms deliberately do not say. *)
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

(* Cut one undone/redone body into the delta the app is handed.

   THE LAYOUT IS COUNTS-IN-THE-HEAD (wire::undo_body): the window, four
   u32 run lengths, the group's label, then ONE flat values tail those
   runs cut up — signals, texts, entries, orders, in that order. Each
   entry and order group is ARITY-FIRST, its own size leading it, so a
   reader needs no schema and a record with more fields cannot shift
   the group after it.

   The window is NOT read here: it arrives in the record's id slot like
   every other occurrence's identity, and reading the same fact twice is
   how two readers come to disagree.

   A body that does not add up is a broken ENCODER and not bad input,
   so it raises rather than handing an app half a step — the picker's
   read-in-threes rule. *)
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
     leaves the cursor where the next one starts. Each step is its own
     [let] because OCaml does not specify the order arguments of a pair
     are evaluated in, and these all read the same cursor. *)
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
      (* size, collection, flags, variant, path_len — then the path,
         the key, and the record's fields. [size] counts itself. *)
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

(* Fold an undo's payload into the collection mirror.

   THE ROLLBACK JOURNAL IN REVERSE: an abandoned transaction restores a
   snapshot because nothing was shipped, while an undo restores a delta
   because everything WAS — the core has already moved, and the mirror
   is what would otherwise be left behind. The payload is
   core-authoritative, so nothing here re-derives anything. Signals and
   text are not mirrored by this binding (no read-back exists for
   either, by doctrine), so those two runs go straight to the app.

   NO DERIVED RECOMPUTE HERE, AND THE ABSENCE IS THE DESIGN RATHER THAN
   AN OMISSION. A derived signal's write rode the SAME transaction as
   the mutation that caused it — [recompute_derived] runs the
   collection's computes inside whichever transaction the insert,
   update, remove or move was called in — so when that transaction
   carried an [undoable] name, the group banked the derived value in
   both of its directions and the core had already restored it before
   this function ran. The types say it too: recomputing wants a [tx],
   and this takes an [app].

   That is not an accident of the signature. This runs from the dispatch
   loop OUTSIDE any transaction, deliberately (the mirror is reconciled
   before the handler and outside its rollback), so a recompute here
   could not borrow the app's transaction — [the_tx ()] raises — and
   would have to open one of its own. It would then write a value the
   ledger never banked, in a transaction the app never asked for,
   landing between the core's restore and the app's [~on_undone].
   Agreeing with the banked value it is dead code hiding the mechanism;
   disagreeing — a compute reading anything beyond the entries, or a
   derive declared after that step was banked (docs/deferred.md's one
   residual) — it drifts the screen away from the ledger's record of the
   step, and the next walk through the history jumps back. *)
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
        (if kind = Kaya_wire.occ_kind_text_changed then
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
           (* NOT one-shot: sections never die, and the user can
              return any number of times (id is the section; the
              window rides as the payload). A programmatic
              select_section never lands here (the echo doctrine). *)
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
              deciding. Never empty: a paste that delivered nothing is
              not an occurrence. *)
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
              user likes.

              The mirror is reconciled BEFORE the handler and OUTSIDE
              its transaction, and both halves matter. Before, so
              [count] answers about the restored state. Outside, because
              a handler that raises rolls back ITS edits and not the
              core's — the core has already moved. *)
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
