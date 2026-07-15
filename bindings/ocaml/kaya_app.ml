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
  entries : (Kaya_wire.value * Kaya_wire.value) list;
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
}

(* One transaction: everything queued inside build (or a handler)
   applies atomically when it returns. Records accumulate reversed.
   The journal holds a snapshot per touched collection, taken on first
   touch, so an abandoned transaction abandons its model edits too. *)
and tx = {
  app : app;
  mutable records : string list;
  mutable journal : (int64 * instance list) list;
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
  }

let emit tx record = tx.records <- record :: tx.records
let instances_of app cid = Option.value ~default:[] (Hashtbl.find_opt app.model cid)

let touch tx cid =
  if not (List.mem_assoc cid tx.journal) then
    tx.journal <- (cid, instances_of tx.app cid) :: tx.journal

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

(* Run a declaration program with a fresh transaction and submit it
   atomically. A handler that raises abandons its records, and the
   model abandons the same writes before the exception continues. *)
let build app (program : 'a decl) =
  let tx = { app; records = []; journal = [] } in
  match program tx with
  | result ->
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
  emit tx (Kaya_wire.tx_create_collection id);
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
  model_set tx c.cid c.cpath key value;
  emit tx (Kaya_wire.tx_collection_insert c.cid c.cpath key value)

let update c key value tx =
  model_set tx c.cid c.cpath key value;
  emit tx (Kaya_wire.tx_collection_update c.cid c.cpath key value)

let remove c key tx =
  model_remove tx c.cid c.cpath key;
  emit tx (Kaya_wire.tx_collection_remove c.cid c.cpath key)

(* The model: what this guest wrote, exactly — the fold of every patch
   so far (this transaction's included), in insertion order. *)
let items c tx =
  match List.find_opt (fun i -> i.path = c.cpath) (instances_of tx.app c.cid) with
  | Some i -> i.entries
  | None -> []

let count c tx = List.length (items c tx)

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
