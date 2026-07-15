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

type app = {
  mutable c_signal : int64;
  mutable c_widget : int64;
  mutable c_collection : int64;
  mutable c_node : int64;
  widget_handlers : (int64, tx -> unit) Hashtbl.t;
  node_handlers : (int64, tx -> Kaya_wire.value list -> unit) Hashtbl.t;
}

(* One transaction: everything queued inside build (or a handler)
   applies atomically when it returns. Records accumulate reversed. *)
and tx = { app : app; mutable records : string list }

let create () =
  {
    c_signal = 0L;
    c_widget = 0L;
    c_collection = 0L;
    c_node = 0L;
    widget_handlers = Hashtbl.create 8;
    node_handlers = Hashtbl.create 8;
  }

let emit tx record = tx.records <- record :: tx.records

(* Run [f] with a fresh transaction and submit it atomically. *)
let build app f =
  let tx = { app; records = [] } in
  let result = f tx in
  if tx.records <> [] then Kaya_runtime.submit (List.rev tx.records);
  result

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
  emit tx (Kaya_wire.tx_create_collection id);
  Collection id

let insert tx (Collection id) path key value =
  emit tx (Kaya_wire.tx_collection_insert id path key value)

let update tx (Collection id) path key value =
  emit tx (Kaya_wire.tx_collection_update id path key value)

let remove tx (Collection id) path key =
  emit tx (Kaya_wire.tx_collection_remove id path key)

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
  let result = body { tpl_tx = tx } in
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
    let result = body { tpl_tx = t.tpl_tx } in
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
