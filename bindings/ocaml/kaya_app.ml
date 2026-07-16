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
  entries : (Kaya_wire.value * Kaya_wire.value list) list;
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
  node_toggles : (int64, Kaya_wire.value list -> bool -> tx -> unit) Hashtbl.t;
  (* The collection is the model — the only copy: every mutation op
     edits it and queues the wire delta in the same call, so reads
     (items, count) are exactly the writes. [children] records the
     declared-inside-a-For edges the model purges along when a parent
     entry's copy is torn down. *)
  model : (int64, instance list) Hashtbl.t;
  children : (int64, int64 list) Hashtbl.t;
  mutable open_fors : int64 list;
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
    node_toggles = Hashtbl.create 8;
    model = Hashtbl.create 8;
    children = Hashtbl.create 8;
    open_fors = [];
    derived = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records
let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

let touch tx cid =
  if not (List.mem_assoc cid tx.journal) then
    tx.journal <- (cid, instances_of tx.app cid) :: tx.journal

(* One [value list] per entry: the record's wire fields (a scalar
   collection is the one-field case). *)
let model_set tx cid path key value =
  touch tx cid;
  let upsert i =
    if List.mem_assoc key i.entries then
      { i with entries = List.map (fun (k, v) -> (k, if k = key then value else v)) i.entries }
    else { i with entries = i.entries @ [ (key, value) ] }
  in
  let instances = instances_of tx.app cid in
  let instances =
    if List.exists (fun i -> i.path = path) instances then
      List.map (fun i -> if i.path = path then upsert i else i) instances
    else instances @ [ { path; entries = [ (key, value) ] } ]
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
let bind_text (Widget id) (Signal s) tx = emit tx (Kaya_wire.tx_bind_text id s)
let set_checked (Widget id) checked tx = emit tx (Kaya_wire.tx_set_checked id checked)
let bind_checked (Widget id) (Signal s) tx = emit tx (Kaya_wire.tx_bind_checked id s)

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

let button ?text ?on_click () tx =
  let w = widget Kaya_wire.kind_button tx in
  Option.iter (fun t -> set_text w t tx) text;
  (match on_click with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_handlers id handler
  | None -> ());
  w

let label ?text ?bind () tx =
  let w = widget Kaya_wire.kind_label tx in
  Option.iter (fun t -> set_text w t tx) text;
  Option.iter (fun s -> bind_text w s tx) bind;
  w

let entry ?on_change () tx =
  let w = widget Kaya_wire.kind_entry tx in
  (match on_change with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_changes id handler
  | None -> ());
  w

let checkbox ?text ?checked ?on_toggle () tx =
  let w = widget Kaya_wire.kind_checkbox tx in
  Option.iter (fun t -> set_text w t tx) text;
  Option.iter (fun c -> set_checked w c tx) checked;
  (match on_toggle with
  | Some handler ->
      let (Widget id) = w in
      Hashtbl.replace tx.app.widget_toggles id handler
  | None -> ());
  w

(* A container from its children: runs each child declaration (their
   records land first), then creates the container and parents them. *)
let container kind children tx =
  let handles = List.map (fun child -> child tx) children in
  let parent = widget kind tx in
  List.iter (fun child -> add_child parent child tx) handles;
  parent

let column children tx = container Kaya_wire.kind_column children tx
let row children tx = container Kaya_wire.kind_row children tx


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
  emit tx (Kaya_wire.tx_create_collection id [Kaya_wire.value_str]);
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
  model_set tx c.cid c.cpath key [ value ];
  emit tx (Kaya_wire.tx_collection_insert c.cid c.cpath key [ value ]);
  recompute_derived tx c.cid c.cpath

let update c key value tx =
  model_set tx c.cid c.cpath key [ value ];
  emit tx (Kaya_wire.tx_collection_update c.cid c.cpath key [ value ]);
  recompute_derived tx c.cid c.cpath

let remove c key tx =
  model_remove tx c.cid c.cpath key;
  emit tx (Kaya_wire.tx_collection_remove c.cid c.cpath key);
  recompute_derived tx c.cid c.cpath

(* The model: what this guest wrote, exactly — the fold of every patch
   so far (this transaction's included), in insertion order. *)
let items c tx =
  match List.find_opt (fun i -> i.path = c.cpath) (instances_of tx.app c.cid) with
  | Some i -> List.map (fun (k, vs) -> (k, List.hd vs)) i.entries
  | None -> []

let count c tx = List.length (items c tx)

(* Records: a first-class descriptor is the schema — the honest floor
   a future ppx deriver ([@@deriving kaya]) will generate. One
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
  emit tx (Kaya_wire.tx_create_collection id rt.rt_schema);
  { rc_handle = { cid = id; cpath = [] }; rc_type = rt }

let insert_record rc key value tx =
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key fields;
  emit tx (Kaya_wire.tx_collection_insert rc.rc_handle.cid rc.rc_handle.cpath key fields);
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

let update_record rc key value tx =
  let fields = rc.rc_type.rt_to_values value in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key fields;
  emit tx (Kaya_wire.tx_collection_update rc.rc_handle.cid rc.rc_handle.cpath key fields);
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* One field's delta: the rest of the record never travels; the
   model's copy updates the same slot. *)
let update_field rc key fd value tx =
  let wire = fd.fd_to_value value in
  let current =
    match
      List.find_opt
        (fun i -> i.path = rc.rc_handle.cpath)
        (instances_of tx.app rc.rc_handle.cid)
    with
    | Some i -> (
        match List.assoc_opt key i.entries with
        | Some vs -> vs
        | None -> invalid_arg "kaya: update of missing key")
    | None -> invalid_arg "kaya: update of missing instance"
  in
  let updated = List.mapi (fun i v -> if i = fd.fd_index then wire else v) current in
  model_set tx rc.rc_handle.cid rc.rc_handle.cpath key updated;
  emit tx
    (Kaya_wire.tx_collection_update_field rc.rc_handle.cid rc.rc_handle.cpath key
       fd.fd_index wire);
  recompute_derived tx rc.rc_handle.cid rc.rc_handle.cpath

(* The typed model: what this guest wrote, in insertion order. *)
let record_items rc tx =
  match
    List.find_opt (fun i -> i.path = rc.rc_handle.cpath) (instances_of tx.app rc.rc_handle.cid)
  with
  | Some i -> List.map (fun (k, vs) -> (k, rc.rc_type.rt_of_values vs)) i.entries
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
  let result = body { tpl_tx = tx } in
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

(* A For as a child: for_each whose body keeps no handles — the
   common case once handlers co-locate at their constructors. *)
let each c body tx = fst (for_each c body tx)

(* A When over a Bool signal: stamps on true, unstamps on false. *)
let when_ (Signal sid) body tx =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_when id sid);
  let result = body { tpl_tx = tx } in
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


  let add_child (Node parent) (Node child) t =
    emit t.tpl_tx (Kaya_wire.tx_add_child parent child)

  let collection t = collection t.tpl_tx

  let for_each c body t =
    assert_root c;
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_for id c.cid);
    t.tpl_tx.app.open_fors <- c.cid :: t.tpl_tx.app.open_fors;
    let result = body { tpl_tx = t.tpl_tx } in
    t.tpl_tx.app.open_fors <- List.tl t.tpl_tx.app.open_fors;
    emit t.tpl_tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  let when_ (Signal sid) body t =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_when id sid);
    let result = body { tpl_tx = t.tpl_tx } in
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
               | Some handler -> build app (handler text)
               | None -> ())
           | Some (Kaya_wire.Str text), keys ->
               (match Hashtbl.find_opt app.node_changes id with
               | Some handler -> build app (handler keys text)
               | None -> ())
           | _ -> ()
         else if kind = Kaya_wire.occ_kind_toggled then
           match (payload, keys) with
           | Some (Kaya_wire.Bool checked), [] ->
               (match Hashtbl.find_opt app.widget_toggles id with
               | Some handler -> build app (handler checked)
               | None -> ())
           | Some (Kaya_wire.Bool checked), keys ->
               (match Hashtbl.find_opt app.node_toggles id with
               | Some handler -> build app (handler keys checked)
               | None -> ())
           | _ -> ()
         else
           match keys with
           | [] ->
               (match Hashtbl.find_opt app.widget_handlers id with
               | Some handler -> build app handler
               | None -> ())
           | keys ->
               (match Hashtbl.find_opt app.node_handlers id with
               | Some handler -> build app (handler keys)
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
