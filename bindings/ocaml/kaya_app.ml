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
   - occurrence dispatch: handlers register per button; the app loop
     routes each click, handing template-node handlers the stamped
     copy's key path. Handlers receive their transaction explicitly;
     it submits when the handler returns. *)

type signal = Signal of int64
type widget = Widget of int64
type node = Node of int64
type collection = Collection of int64

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
  node_handlers : (int64, tx -> Kaya_wire.value list -> unit) Hashtbl.t;
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

let create () =
  {
    c_signal = 0L;
    c_widget = 0L;
    c_collection = 0L;
    c_node = 0L;
    widget_handlers = Hashtbl.create 8;
    node_handlers = Hashtbl.create 8;
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

(* Run [f] with a fresh transaction and submit it atomically. A handler
   that raises abandons its records, and the model abandons the same
   writes before the exception continues. *)
let build app f =
  let tx = { app; records = []; journal = [] } in
  match f tx with
  | result ->
      if tx.records <> [] then Kaya_runtime.submit (List.rev tx.records);
      result
  | exception e ->
      List.iter (fun (cid, saved) -> Hashtbl.replace app.model cid saved) tx.journal;
      raise e

let signal tx initial =
  tx.app.c_signal <- Int64.add tx.app.c_signal 1L;
  let id = tx.app.c_signal in
  emit tx (Kaya_wire.tx_create_signal id initial);
  Signal id

let write tx (Signal id) value = emit tx (Kaya_wire.tx_write_signal id value)

let widget tx kind =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_widget id kind);
  Widget id

let set_text tx (Widget id) text = emit tx (Kaya_wire.tx_set_text id text)
let bind_text tx (Widget id) (Signal s) = emit tx (Kaya_wire.tx_bind_text id s)

let add_child tx (Widget parent) (Widget child) =
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
  Collection id

let insert tx (Collection id) path key value =
  model_set tx id path key value;
  emit tx (Kaya_wire.tx_collection_insert id path key value)

let update tx (Collection id) path key value =
  model_set tx id path key value;
  emit tx (Kaya_wire.tx_collection_update id path key value)

let remove tx (Collection id) path key =
  model_remove tx id path key;
  emit tx (Kaya_wire.tx_collection_remove id path key)

(* The model: what this guest wrote, exactly — the fold of every patch
   so far (this transaction's included), in insertion order. *)
let items tx (Collection id) path =
  match List.find_opt (fun i -> i.path = path) (instances_of tx.app id) with
  | Some i -> i.entries
  | None -> []

let count tx c path = List.length (items tx c path)

(* Mount into the default window; per-window targets arrive with the
   window vocabulary. *)
let mount tx (Widget root) = emit tx (Kaya_wire.tx_mount 0L root)

(* A template body: the same declaration vocabulary with template-node
   ids, plus element bindings. *)
type tpl = { tpl_tx : tx }

let alloc_node tx =
  tx.app.c_node <- Int64.add tx.app.c_node 1L;
  tx.app.c_node

(* A For over a collection: [body] declares the template; the For
   itself (a live container) is returned. *)
let for_each tx (Collection cid) body =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_for id cid);
  tx.app.open_fors <- cid :: tx.app.open_fors;
  let result = body { tpl_tx = tx } in
  tx.app.open_fors <- List.tl tx.app.open_fors;
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

(* A When over a Bool signal: stamps on true, unstamps on false. *)
let when_ tx (Signal sid) body =
  tx.app.c_widget <- Int64.add tx.app.c_widget 1L;
  let id = tx.app.c_widget in
  emit tx (Kaya_wire.tx_create_when id sid);
  let result = body { tpl_tx = tx } in
  emit tx (Kaya_wire.tx_template_end ());
  (Widget id, result)

module Tpl = struct
  let widget t kind =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_widget id kind);
    Node id

  let set_text t (Node id) text = emit t.tpl_tx (Kaya_wire.tx_set_text id text)

  (* Bind text to the element of the enclosing For, [level] Fors up
     (0 = nearest). *)
  let bind_text_element ?(level = 0) t (Node id) =
    emit t.tpl_tx (Kaya_wire.tx_bind_text_element ~level id)

  let add_child t (Node parent) (Node child) =
    emit t.tpl_tx (Kaya_wire.tx_add_child parent child)

  let collection t = collection t.tpl_tx

  let for_each t (Collection cid) body =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_for id cid);
    t.tpl_tx.app.open_fors <- cid :: t.tpl_tx.app.open_fors;
    let result = body { tpl_tx = t.tpl_tx } in
    t.tpl_tx.app.open_fors <- List.tl t.tpl_tx.app.open_fors;
    emit t.tpl_tx (Kaya_wire.tx_template_end ());
    (Node id, result)

  let when_ t (Signal sid) body =
    let id = alloc_node t.tpl_tx in
    emit t.tpl_tx (Kaya_wire.tx_create_when id sid);
    let result = body { tpl_tx = t.tpl_tx } in
    emit t.tpl_tx (Kaya_wire.tx_template_end ());
    (Node id, result)
end

(* Register a click handler for a live widget. *)
let on_click app (Widget id) handler = Hashtbl.replace app.widget_handlers id handler

(* Register a click handler for a template node; it also receives the
   stamped copy's keys, outermost first. *)
let on_click_node app (Node id) handler = Hashtbl.replace app.node_handlers id handler

let dispatch_loop app =
  let rec loop () =
    match Kaya_runtime.next_click () with
    | None -> () (* shutdown *)
    | Some (id, []) ->
        (match Hashtbl.find_opt app.widget_handlers id with
        | Some handler -> build app handler
        | None -> ());
        loop ()
    | Some (id, keys) ->
        (match Hashtbl.find_opt app.node_handlers id with
        | Some handler -> build app (fun tx -> handler tx keys)
        | None -> ());
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
