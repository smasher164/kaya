(* kaya's idiomatic surface for OCaml: the structural core.

   Three jobs, layered over the runtime (kaya_runtime.ml) and the
   generated wire vocabulary (kaya_wire.ml):

   - id allocation: signals, widgets, collections, and template nodes
     come from per-space counters behind distinct types, so no app
     hand-numbers the id spaces — and the compiler keeps blueprint
     nodes (node) from being used where live widgets (widget) belong;
   - template scoping: for_each and when_ take a (tpl -> 'a) whose body
     declares the blueprint, bracketing the records. OCaml has no
     overloading, so the template vocabulary lives in the Tpl submodule
     — the module path spells the zone the way the type family does in
     the Haskell binding;
   - declaration programs: a declaration is a value of type 'a decl
     (= tx -> 'a), composed with the let* / let+ / and+ binding
     operators — the reader spelling of Haskell's Build monad. No call
     threads tx by hand, [build] is the only way to run a program (so
     "declared outside a transaction" stays a type error), and a
     dropped declaration in statement position is a type error too
     (unit expected, tx -> unit found) — dropped patches are loud. The
     Tpl submodule carries its own operators over tpl, so a local open
     (Tpl.( ... )) switches zone and operators together;
   - occurrence dispatch: handlers register per button; the app loop
     routes each click, handing template-node handlers the stamped
     copy's key path. Handlers receive their transaction explicitly;
     it submits when the handler returns. *)

type signal = Signal of int64
type widget = Widget of int64
type node = Node of int64

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

type app = {
  mutable c_signal : int64;
  mutable c_widget : int64;
  mutable c_collection : int64;
  mutable c_node : int64;
  widget_handlers : (int64, tx -> unit) Hashtbl.t;
  node_handlers : (int64, Kaya_wire.value list -> tx -> unit) Hashtbl.t;
  widget_changes : (int64, string -> tx -> unit) Hashtbl.t;
  node_changes : (int64, Kaya_wire.value list -> string -> tx -> unit) Hashtbl.t;
  widget_toggles : (int64, bool -> tx -> unit) Hashtbl.t;
  widget_values : (int64, float -> tx -> unit) Hashtbl.t;
  (* Window lifecycle: one handler each, receiving the window id. *)
  close_requested : (int64, tx -> unit) Hashtbl.t;
  entry_popped : (int64, tx -> unit) Hashtbl.t;
  back_requested : (int64, tx -> unit) Hashtbl.t;
  section_selected : (int64, tx -> unit) Hashtbl.t;
  alert_handlers : (int64, int -> tx -> unit) Hashtbl.t;
  mutable next_alert : int64;
  window_closed : (int64, tx -> unit) Hashtbl.t;
  node_toggles : (int64, Kaya_wire.value list -> bool -> tx -> unit) Hashtbl.t;
  (* The collection is the model — the only copy: every mutation op
     edits it and queues the wire delta in the same call, so reads
     (items, count) are exactly the writes. [children] records the
     declared-inside-a-For edges the model purges along when a parent
     entry's copy is torn down. *)
  model : (int64, instance list) Hashtbl.t;
  children : (int64, int64 list) Hashtbl.t;
  mutable open_fors : int64 list;
  (* The record-time mirror-read guard's arming counter: >0 while any
     template body (a For body, a When body, a sum eliminator's arms)
     is being DECLARED. Distinct from open_fors (For-only, and keyed by
     collection): every template scope bumps this, When included. *)
  mutable tpl_depth : int;
  (* Signals recomputed from a collection after each of its mutations,
     written into the same transaction. *)
  derived : (int64, (tx -> unit) list) Hashtbl.t;
}

(* One transaction: everything queued inside build (or a handler)
   applies atomically when it returns. Records accumulate reversed.
   The journal holds a snapshot per touched collection, taken on first
   touch, so an abandoned transaction abandons its model edits too. *)
and tx = {
  app : app;
  mutable records : string list;
  mutable journal : (int64 * instance list) list;
  (* Deriveds registered in this transaction: promoted to the app
     registry on submit, abandoned with a rolled-back tx (their signals
     were never created). *)
  mutable pending_derived : (int64 * (tx -> unit)) list;
}

(* A declaration program: what [build] runs against one transaction.
   Every declaration below is one of these (tx comes last), so partial
   application is composition. *)
type 'a decl = tx -> 'a

let create () =
  {
    c_signal = 0L;
    c_widget = 0L;
    c_collection = 0L;
    c_node = 0L;
    widget_handlers = Hashtbl.create 8;
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
    window_closed = Hashtbl.create 8;
    node_toggles = Hashtbl.create 8;
    model = Hashtbl.create 8;
    children = Hashtbl.create 8;
    open_fors = [];
    tpl_depth = 0;
    derived = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records
let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

(* The record-time mirror-read guard: a template body records once and
   the core replays it — a model read inside one bakes this moment's
   data into every future stamp, silently dead. Live-zone, handler-tx,
   and build-tx reads stay legal. *)
let guard_mirror_read tx =
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
    | Some fns -> List.iter (fun f -> f tx) fns
    | None -> ());
    List.iter (fun (c, f) -> if c = cid then f tx) (List.rev tx.pending_derived)
  end

(* Run a declaration program with a fresh transaction and submit it
   atomically. A handler that raises abandons its records, and the
   model abandons the same writes before the exception continues. *)
let build app (program : 'a decl) =
  let tx = { app; records = []; journal = []; pending_derived = [] } in
  match program tx with
  | result ->
      List.iter
        (fun (cid, f) ->
          Hashtbl.replace app.derived cid
            (Option.value ~default:[] (Hashtbl.find_opt app.derived cid) @ [ f ]))
        (List.rev tx.pending_derived);
      if tx.records <> [] then Kaya_runtime.submit (List.rev tx.records);
      result
  | exception e ->
      List.iter (fun (cid, saved) -> Hashtbl.replace app.model cid saved) tx.journal;
      raise e

(* One handler dispatch: an exception crosses the build boundary
   (which restored the model and dropped the records), is logged, and
   the loop moves to the next occurrence -- the uniform dispatch
   discipline across every binding. *)
let dispatch app (program : unit decl) =
  try build app program
  with e ->
    Printf.eprintf "kaya: handler raised (transaction rolled back): %s\n%!"
      (Printexc.to_string e)

(* The binding operators over declaration programs. *)
let ( let* ) (m : 'a decl) (f : 'a -> 'b decl) : 'b decl = fun tx -> f (m tx) tx
let ( let+ ) (m : 'a decl) (f : 'a -> 'b) : 'b decl = fun tx -> f (m tx)

let ( and+ ) (ma : 'a decl) (mb : 'b decl) : ('a * 'b) decl =
 fun tx ->
  let a = ma tx in
  let b = mb tx in
  (a, b)

let return x : 'a decl = fun _tx -> x

(* Lift host code (counters, app-state reads) into a program: it runs
   when the program does — per transaction, in order — not when the
   program is built. *)
let io f : 'a decl = fun _tx -> f ()

let signal initial tx =
  tx.app.c_signal <- Int64.add tx.app.c_signal 1L;
  let id = tx.app.c_signal in
  emit tx (Kaya_wire.tx_create_signal id initial);
  Signal id

let write (Signal id) value tx = emit tx (Kaya_wire.tx_write_signal id value)

let widget kind tx =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_widget id kind);
  Widget id

let set_text (Widget id) text tx = emit tx (Kaya_wire.tx_set_text id text)

(* Set a widget's flex weight within its row/column: 0 is natural
   size, positive weights divide the container's leftover main-axis
   space in proportion (see Prop::Grow in the core). [set_grow] is the
   dynamic path; the declarative spelling is the [~grow] labeled
   argument every constructor takes. *)
let set_grow (Widget id) weight tx = emit tx (Kaya_wire.tx_set_grow id weight)

(* A container's inter-child gap (main axis, DIP; the normalized
   default is 8). Containers only — the scene rejects it anywhere
   else. [set_spacing] is the dynamic path; the declarative spelling
   is the [~spacing] labeled argument on the container. *)
let set_spacing (Widget id) gap tx = emit tx (Kaya_wire.tx_set_spacing id gap)

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

let set_align (Widget id) a tx = emit tx (Kaya_wire.tx_set_align id (align_wire a))
let bind_text (Widget id) (Signal s) tx = emit tx (Kaya_wire.tx_bind_text id s)
let set_checked (Widget id) checked tx = emit tx (Kaya_wire.tx_set_checked id checked)
let bind_checked (Widget id) (Signal s) tx = emit tx (Kaya_wire.tx_bind_checked id s)

(* An image's content: one registration copy of the encoded bytes into
   core-owned memory. The handle is consumed by the next submit from
   this guest, referenced or not — so every write re-registers — and
   the caller's bytes are free to drop the moment this returns. *)
let set_source (Widget id) data tx =
  emit tx (Kaya_wire.tx_set_source id (Kaya_runtime.register_blob data))

let bind_source (Widget id) (Signal s) tx =
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
let clear (Widget id) tx = emit tx (Kaya_wire.tx_widget_command id Kaya_wire.command_clear)

(* Give this widget the keyboard focus. *)
let focus (Widget id) tx = emit tx (Kaya_wire.tx_widget_command id Kaya_wire.command_focus)

let add_child (Widget parent) (Widget child) tx =
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

let button ?grow ?text ?on_click () tx =
  let w = widget Kaya_wire.kind_button tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  Option.iter (fun t -> set_text w t tx) text;
  (match on_click with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_handlers id handler
  | None -> ());
  w

(* A multi-line text editor: the entry's uncontrolled contract over
   the platform's real multi-line editor. *)
let textarea ?grow ?on_change () tx =
  let w = widget Kaya_wire.kind_textarea tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

let label ?grow ?text ?bind () tx =
  let w = widget Kaya_wire.kind_label tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  Option.iter (fun t -> set_text w t tx) text;
  Option.iter (fun s -> bind_text w s tx) bind;
  w

let entry ?grow ?on_change () tx =
  let w = widget Kaya_wire.kind_entry tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

(* A progress bar: display-only, like label and image. [~value] is
   the determinate fraction (0..=1); [~indeterminate:true] switches
   to the platform's activity mode. *)
let progress ?grow ?(value = 0.0) ?indeterminate () tx =
  let w = widget Kaya_wire.kind_progress tx in
  Option.iter (fun g -> set_grow w g tx) grow;
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
let slider ?grow ?(min = 0.0) ?(max = 1.0) ?(value = 0.0) ?bind ?on_change () tx =
  let w = widget Kaya_wire.kind_slider tx in
  Option.iter (fun g -> set_grow w g tx) grow;
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
let select ?grow ?(selected = 0) ?on_select options () tx =
  let w = widget Kaya_wire.kind_select tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  List.iter
    (fun option_text ->
      let o = widget Kaya_wire.kind_label tx in
      set_text o option_text tx;
      add_child w o tx)
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
let radio ?grow ?(selected = 0) ?on_select options () tx =
  let w = widget Kaya_wire.kind_radio tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  List.iter
    (fun option_text ->
      let o = widget Kaya_wire.kind_label tx in
      set_text o option_text tx;
      add_child w o tx)
    options;
  let (Widget id) = w in
  emit tx (Kaya_wire.tx_set_value id (float_of_int selected));
  (match on_select with
  | Some handler ->
      Hashtbl.replace tx.app.widget_values id
        (fun v -> handler (int_of_float v))
  | None -> ());
  w

let checkbox ?grow ?text ?checked ?on_toggle () tx =
  let w = widget Kaya_wire.kind_checkbox tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  Option.iter (fun t -> set_text w t tx) text;
  Option.iter (fun c -> set_checked w c tx) checked;
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
let image ?grow ?source ?bind () tx =
  let w = widget Kaya_wire.kind_image tx in
  Option.iter (fun g -> set_grow w g tx) grow;
  Option.iter (fun data -> set_source w data tx) source;
  Option.iter (fun s -> bind_source w s tx) bind;
  w

(* A container from its children: runs each child declaration (their
   records land first), then creates the container and parents them.
   Construction props are labeled optional arguments, the lablgtk
   idiom: [~grow] weights the container within ITS parent, [~spacing]
   sets its own inter-child gap. *)
let container ?grow ?spacing ?align kind children tx =
  let handles = List.map (fun child -> child tx) children in
  let parent = widget kind tx in
  Option.iter (fun g -> set_grow parent g tx) grow;
  Option.iter (fun s -> set_spacing parent s tx) spacing;
  Option.iter (fun a -> set_align parent a tx) align;
  List.iter (fun child -> add_child parent child tx) handles;
  parent

(* A grid from its children, laid out row-major into [~columns]
   columns — each column takes its NATURAL width, aligned across rows
   (the thing nested rows cannot express). [~spacing] is the
   inter-cell gap on both axes. The columns record lands BEFORE the
   add_childs (backends re-flow either way). *)
let grid ~columns ?grow ?spacing children tx =
  let handles = List.map (fun child -> child tx) children in
  let parent = widget Kaya_wire.kind_grid tx in
  let (Widget id) = parent in
  emit tx (Kaya_wire.tx_set_columns id (float_of_int columns));
  Option.iter (fun g -> set_grow parent g tx) grow;
  Option.iter (fun s -> set_spacing parent s tx) spacing;
  List.iter (fun child -> add_child parent child tx) handles;
  parent

(* A spacer: PURE SUGAR for an empty grown column — it consumes the
   leftover main-axis space between its siblings. *)
let spacer ?(grow = 1.0) () tx =
  let w = widget Kaya_wire.kind_column tx in
  set_grow w grow tx;
  w

let column ?grow ?spacing ?align children tx =
  container ?grow ?spacing ?align Kaya_wire.kind_column children tx

(* A vertical scroll viewport over EXACTLY ONE child (the signature
   says so; the scene enforces it too). Pass [~grow] so the enclosing
   track CONSTRAINS it — an unconstrained viewport hugs its content
   and nothing overflows. *)
let scroll ?grow child tx =
  container ?grow Kaya_wire.kind_scroll [ child ] tx

let row ?grow ?spacing ?align children tx =
  container ?grow ?spacing ?align Kaya_wire.kind_row children tx


let collection tx =
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

let insert c key value tx =
  model_set tx c.cid c.cpath key 0 [ value ];
  emit tx (Kaya_wire.tx_collection_insert c.cid c.cpath key 0 [ value ]);
  recompute_derived tx c.cid c.cpath

let update c key value tx =
  model_set tx c.cid c.cpath key 0 [ value ];
  emit tx (Kaya_wire.tx_collection_update c.cid c.cpath key 0 [ value ]);
  recompute_derived tx c.cid c.cpath

let remove c key tx =
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
let move_entry c key before tx =
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
let move_before c key anchor tx = move_entry c key (Some anchor) tx

(* Reposition an entry at the end of its collection. *)
let move_to_end c key tx = move_entry c key None tx

(* Reposition an entry at the front: sugar for move_before the current
   first key, lowering to the same wire op. *)
let move_to_front c key tx =
  match entry_keys tx c.cid c.cpath with
  | [] -> invalid_arg "kaya: move of missing key"
  | first :: _ -> move_entry c key (Some first) tx

(* Reposition an entry directly after another's: sugar for move_before
   the anchor's successor (move_to_end when the anchor is last),
   lowering to the same wire op. *)
let move_after c key anchor tx =
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
    | Some s -> move_entry c key (Some s) tx
    | None -> move_entry c key None tx
  end

(* The model: what this guest wrote, exactly — the fold of every patch
   so far (this transaction's included), in insertion order. *)
let items c tx =
  guard_mirror_read tx;
  match List.find_opt (fun i -> i.path = c.cpath) (instances_of tx.app c.cid) with
  | Some i -> List.map (fun (k, (_, vs)) -> (k, List.hd vs)) i.entries
  | None -> []

(* count reads through items, so the mirror-read guard fires there. *)
let count c tx = List.length (items c tx)

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
let collection_of rt tx =
  tx.app.c_collection <- Int64.add tx.app.c_collection 1L;
  let id = tx.app.c_collection in
  (match tx.app.open_fors with
  | parent :: _ ->
      Hashtbl.replace tx.app.children parent
        (Option.value ~default:[] (Hashtbl.find_opt tx.app.children parent) @ [ id ])
  | [] -> ());
  emit tx (Kaya_wire.tx_create_collection id [ rt.rt_schema ]);
  { rc_handle = { cid = id; cpath = [] }; rc_type = rt }

let insert_record rc key value tx =
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 fields;
  emit tx
    (Kaya_wire.tx_collection_insert rc.rc_handle.cid rc.rc_handle.cpath key 0
       (encode_fields rc.rc_type.rt_schema fields));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

let update_record rc key value tx =
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key 0 fields;
  emit tx
    (Kaya_wire.tx_collection_update rc.rc_handle.cid rc.rc_handle.cpath key 0
       (encode_fields rc.rc_type.rt_schema fields));
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* One field's delta: the rest of the record never travels; the
   model's copy updates the same slot. *)
let update_field rc key fd value tx =
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
let record_items rc tx =
  guard_mirror_read tx;
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
let derive rc compute tx =
  let s = signal (compute (record_items rc tx)) tx in
  tx.pending_derived <-
    (rc.rc_handle.cid, fun tx' -> write s (compute (record_items rc tx')) tx')
    :: tx.pending_derived;
  s

(* Mount into the default window; per-window targets arrive with the
   window vocabulary. *)
(* The primary surface's title: the title bar on the desktops, the
   switcher label on iOS, the task label on Android. *)
let window_title title tx = emit tx (Kaya_wire.tx_set_window_title 0L title)

(* Request the primary surface's content size in DIP — ADVISORY on
   every platform: honored where the window manager permits, recorded
   only where the system owns geometry. *)
let window_size width height tx =
  emit tx (Kaya_wire.tx_set_window_width 0L width);
  emit tx (Kaya_wire.tx_set_window_height 0L height)

(* Create an auxiliary window (capability-gated: phone hosts reject
   at the root); materializes hidden, [mount_in] presents. Labeled
   optional arguments are the OCaml spelling. *)
let create_window ?title ?width ?height ?veto_close ?on_close_requested
    ?on_closed id tx =
  emit tx (Kaya_wire.tx_create_window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_window_title id t)) title;
  Option.iter (fun w -> emit tx (Kaya_wire.tx_set_window_width id w)) width;
  Option.iter (fun h -> emit tx (Kaya_wire.tx_set_window_height id h)) height;
  Option.iter (fun v -> emit tx (Kaya_wire.tx_set_window_veto_close id v)) veto_close;
  (* The handlers ride the declaration (per-window — handlers scope
     to the thing that creates them): [~on_close_requested] fires per
     chrome close while veto_close is armed (answer with
     [destroy_window] to agree); [~on_closed] fires when the non-veto
     auxiliary is chrome-closed and retires with it. *)
  Option.iter
    (fun f -> Hashtbl.replace tx.app.close_requested id f)
    on_close_requested;
  Option.iter (fun f -> Hashtbl.replace tx.app.window_closed id f) on_closed

(* Close and forget an auxiliary window — also the veto grammar's
   confirmation and the reconciliation after a chrome close. *)
let destroy_window id tx = emit tx (Kaya_wire.tx_destroy_window id)

(* Mount a root into a specific window; mounting presents. *)
let mount_in window (Widget root) tx = emit tx (Kaya_wire.tx_mount window root)

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
    ?on_back_requested id tx =
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
let add_section ?(window = 0L) ?title ?on_selected id tx =
  emit tx (Kaya_wire.tx_add_section window id);
  Option.iter (fun t -> emit tx (Kaya_wire.tx_set_section_title id t)) title;
  Option.iter
    (fun f -> Hashtbl.replace tx.app.section_selected id f)
    on_selected

(* Select a section programmatically: configuration, never echoes
   [~on_selected] (the echo doctrine). *)
let select_section ?(window = 0L) id tx =
  emit tx (Kaya_wire.tx_select_section window id)

(* The window's ADVISORY presentation hint
   (Kaya_wire.sections_presentation_auto/bar/sidebar — the
   width/height precedent; the phones ignore it by physics). *)
let sections_presentation ?(window = 0L) hint tx =
  emit tx (Kaya_wire.tx_set_window_sections_presentation window hint)

(* Pop the window's top navigation entry and forget its tree — also
   the back-veto grammar's confirmation after [on_back_requested].
   Popping an empty stack is a scene error. *)
let pop_entry ?(window = 0L) () tx = emit tx (Kaya_wire.tx_pop_entry window)

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
    ?(actions = []) ~cancel ?on_result tx =
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
let alert_cancel = Kaya_wire.alert_choice_cancel



let mount (Widget root) tx = emit tx (Kaya_wire.tx_mount 0L root)

(* A template body: the same declaration vocabulary with template-node
   ids, plus element bindings. *)
type tpl = { tpl_tx : tx }

let alloc_node tx =
  tx.app.c_node <- Int64.add tx.app.c_node 1L;
  tx.app.c_node

(* A For over a collection: [body] declares the template; the For
   itself (a live container) is returned alongside the body's result. *)
let for_each c body tx =
  assert_root c;
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_for id c.cid);
  tx.app.open_fors <- c.cid :: tx.app.open_fors;
  let result = in_tpl_scope tx.app (fun () -> body { tpl_tx = tx }) in
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

(* A For as a child: for_each whose body keeps no handles — the
   common case once handlers co-locate at their constructors. *)
let each c body tx = fst (for_each c body tx)

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

let sum_of st tx =
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
let sum_insert sc key value tx =
  let variant = sc.sc_type.st_variant value in
  let fields = sc.sc_type.st_to_values value in
  model_set tx sc.sc_handle.cid sc.sc_handle.cpath key variant fields;
  emit tx
    (Kaya_wire.tx_collection_insert sc.sc_handle.cid sc.sc_handle.cpath key
       variant
       (encode_fields (List.nth sc.sc_type.st_schemas variant) fields));
  recompute_derived tx sc.sc_handle.cid sc.sc_handle.cpath

(* Update replaces a record wholesale; a different constructor than
   the entry's current one restamps its copy in place. *)
let sum_update sc key value tx =
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
let sum_items sc tx =
  guard_mirror_read tx;
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
let sum_get sc key tx =
  guard_mirror_read tx;
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
let sum_update_field sc key ~variant fd value tx =
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
let sum_derive sc compute tx =
  let s = signal (compute (sum_items sc tx)) tx in
  tx.pending_derived <-
    (sc.sc_handle.cid, fun tx' -> write s (compute (sum_items sc tx')) tx')
    :: tx.pending_derived;
  s

(* The eliminator's mechanism: (variant, arm) pairs in declaration
   order, each arm a Tpl program. Only the generated per-sum wrappers
   call this — their required labelled arguments are what makes
   totality a compile error. *)
let each_sum sc arms tx =
  assert_root sc.sc_handle;
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_for id sc.sc_handle.cid);
  tx.app.open_fors <- sc.sc_handle.cid :: tx.app.open_fors;
  in_tpl_scope tx.app (fun () ->
      List.iter
        (fun (variant, arm) ->
          emit tx (Kaya_wire.tx_variant_case variant);
          arm { tpl_tx = tx })
        arms);
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  Widget id

(* A When over a Bool signal: stamps on true, unstamps on false. *)
let when_ (Signal sid) body tx =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_when id sid);
  let result = in_tpl_scope tx.app (fun () -> body { tpl_tx = tx }) in
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

module Tpl = struct
  (* The same program shape over the template zone: 'a Tpl.decl
     (= tpl -> 'a), with its own binding operators — a local open
     (Tpl.( ... )) switches zone and operators together. *)
  type 'a decl = tpl -> 'a

  let ( let* ) (m : 'a decl) (f : 'a -> 'b decl) : 'b decl = fun t -> f (m t) t
  let ( let+ ) (m : 'a decl) (f : 'a -> 'b) : 'b decl = fun t -> f (m t)

  let ( and+ ) (ma : 'a decl) (mb : 'b decl) : ('a * 'b) decl =
   fun t ->
    let a = ma t in
    let b = mb t in
    (a, b)

  let return x : 'a decl = fun _t -> x

  let widget kind t =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_widget id kind);
    Node id

  let set_text (Node id) text t = emit t.tpl_tx (Kaya_wire.tx_set_text id text)

  (* Bind text to the element of the enclosing For, [level] Fors up
     (0 = nearest). *)
  let bind_text_element ?(level = 0) (Node id) t =
    emit t.tpl_tx (Kaya_wire.tx_bind_text_element ~level id)

  (* Bind a label's text to one field of the element; a (_, string)
     field only — the phantom pins it at compile time. *)
  let bind_text_field ?(level = 0) (Node id) (fd : (_, string) field) t =
    emit t.tpl_tx (Kaya_wire.tx_bind_text_element ~level ~field:fd.fd_index id)

  (* Bind a checkbox's state to one field of the element; a (_, bool)
     field only. *)
  let bind_checked_field ?(level = 0) (Node id) (fd : (_, bool) field) t =
    emit t.tpl_tx (Kaya_wire.tx_bind_checked_element ~level ~field:fd.fd_index id)

  (* Bind an image's source to one field of the element; a (_, bytes)
     field only — the phantom pins it at compile time. Per-entry
     content: the core stamps each copy with its entry's blob. *)
  let bind_source_field ?(level = 0) (Node id) (fd : (_, bytes) field) t =
    emit t.tpl_tx (Kaya_wire.tx_bind_source_element ~level ~field:fd.fd_index id)


  let add_child (Node parent) (Node child) t =
    emit t.tpl_tx (Kaya_wire.tx_add_child parent child)

  let collection t = collection t.tpl_tx

  let for_each c body t =
    assert_root c;
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_for id c.cid);
    t.tpl_tx.app.open_fors <- c.cid :: t.tpl_tx.app.open_fors;
    let result = in_tpl_scope t.tpl_tx.app (fun () -> body { tpl_tx = t.tpl_tx }) in
    t.tpl_tx.app.open_fors <- List.tl t.tpl_tx.app.open_fors;
    emit t.tpl_tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  let when_ (Signal sid) body t =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_when id sid);
    let result = in_tpl_scope t.tpl_tx.app (fun () -> body { tpl_tx = t.tpl_tx }) in
    emit t.tpl_tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  (* The construction sugar, template flavor: bindings take fields, and
     handlers receive the stamped copy's keys first. *)
  let button ?text ?on_click () t =
    let n = widget Kaya_wire.kind_button t in
    Option.iter (fun x -> set_text n x t) text;
    (match on_click with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace t.tpl_tx.app.node_handlers id handler
    | None -> ());
    n

  let label ?text ?bind_field ?(level = 0) () t =
    let n = widget Kaya_wire.kind_label t in
    Option.iter (fun x -> set_text n x t) text;
    Option.iter (fun fd -> bind_text_field ~level n fd t) bind_field;
    n

  let checkbox ?checked_field ?(level = 0) ?on_toggle () t =
    let n = widget Kaya_wire.kind_checkbox t in
    Option.iter (fun fd -> bind_checked_field ~level n fd t) checked_field;
    (match on_toggle with
    | Some handler ->
        let (Node id) = n in
        Hashtbl.replace t.tpl_tx.app.node_toggles id handler
    | None -> ());
    n

  (* The template image: [bind_field] takes a (_, bytes) field of the
     element — each stamped copy displays its own entry's bytes. *)
  let image ?bind_field ?(level = 0) () t =
    let n = widget Kaya_wire.kind_image t in
    Option.iter (fun fd -> bind_source_field ~level n fd t) bind_field;
    n

  let container kind children t =
    let handles = List.map (fun child -> child t) children in
    let parent = widget kind t in
    List.iter (fun child -> add_child parent child t) handles;
    parent

  let column children t = container Kaya_wire.kind_column children t
  let row children t = container Kaya_wire.kind_row children t
end

(* Register a click handler for a live widget: a unit decl, run as one
   transaction per click. *)
let on_click app (Widget id) (handler : unit decl) =
  Hashtbl.replace app.widget_handlers id handler

(* Register a click handler for a template node; it also receives the
   stamped copy's keys, outermost first. *)
let on_click_node app (Node id) (handler : Kaya_wire.value list -> unit decl) =
  Hashtbl.replace app.node_handlers id handler

(* Register a change handler for a live entry: the widget owns its text
   and reports each edit here; the app folds the text into its own
   state — there is no read-back, by doctrine. *)
let on_change app (Widget id) (handler : string -> unit decl) =
  Hashtbl.replace app.widget_changes id handler

(* Register a change handler for a template entry; it also receives the
   stamped copy's keys, outermost first. *)
let on_change_node app (Node id) (handler : Kaya_wire.value list -> string -> unit decl) =
  Hashtbl.replace app.node_changes id handler

(* Register a toggle handler for a live checkbox: the box owns its
   checked bit and reports each flip here; the app folds it into its
   own state. *)
let on_toggle app (Widget id) (handler : bool -> unit decl) =
  Hashtbl.replace app.widget_toggles id handler

(* Register a change handler for a live slider: the bar owns its
   position and reports each move with the new value — the entry's
   uncontrolled contract, with a float. *)
let on_value_changed app (Widget id) (handler : float -> unit decl) =
  Hashtbl.replace app.widget_values id handler

(* Register a toggle handler for a template checkbox; it also receives
   the stamped copy's keys, outermost first. *)
let on_toggle_node app (Node id) (handler : Kaya_wire.value list -> bool -> unit decl) =
  Hashtbl.replace app.node_toggles id handler

let dispatch_loop app =
  let rec loop () =
    match Kaya_runtime.next_occurrence () with
    | None -> () (* shutdown *)
    | Some (kind, id, keys, payload) ->
        (if kind = Kaya_wire.occ_kind_text_changed then
           match (payload, keys) with
           | Some (Kaya_wire.Str text), [] ->
               (match Hashtbl.find_opt app.widget_changes id with
               | Some handler -> dispatch app (handler text)
               | None -> ())
           | Some (Kaya_wire.Str text), keys ->
               (match Hashtbl.find_opt app.node_changes id with
               | Some handler -> dispatch app (handler keys text)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_toggled then
           match (payload, keys) with
           | Some (Kaya_wire.Bool checked), [] ->
               (match Hashtbl.find_opt app.widget_toggles id with
               | Some handler -> dispatch app (handler checked)
               | None -> ())
           | Some (Kaya_wire.Bool checked), keys ->
               (match Hashtbl.find_opt app.node_toggles id with
               | Some handler -> dispatch app (handler keys checked)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_value_changed then
           match (payload, keys) with
           | Some (Kaya_wire.F64 v), [] ->
               (match Hashtbl.find_opt app.widget_values id with
               | Some handler -> dispatch app (handler v)
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
               dispatch app (handler (Int64.to_int c))
           | _ -> ())
         else
           match keys with
           | [] ->
               (match Hashtbl.find_opt app.widget_handlers id with
               | Some handler -> build app handler
               | None -> ())
           | keys ->
               (match Hashtbl.find_opt app.node_handlers id with
               | Some handler -> dispatch app (handler keys)
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
