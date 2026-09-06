// kaya's idiomatic surface for JavaScript and TypeScript: the structural
// core plus the tier-1 sugar, bindings/python/kaya/__init__.py's twin in
// plain-JS clothes (docs/js-plan.md §4 records the spellings).
//
// Dispatch runs on the app thread — the worker this module bootstraps
// (runtime.ts) — after the pump pulls from the ring.

import * as runtime from "./runtime.ts";
import * as wire from "./wire.ts";
import { BlobHandle, I64 } from "./wire.ts";

export { wire };

// THE MAIN THREAD IS SURRENDERED HERE, at import: the guest's module body
// runs only in the worker (runtime.ts, surrenderMainThread).
if (!runtime.IS_APP_THREAD) {
  runtime.surrenderMainThread();
}

// ------------------------------------------------------------- schema

/** The integer field token: an I64 on the wire, a number in JS, exact
 * to ±(2^53 − 1) (crates/kaya/src/spec.rs, MAX_SAFE_INTEGER). */
export const Int: unique symbol = Symbol("kaya.Int");
export type IntToken = typeof Int;
/** A civil date — the value a date picker carries and a `CivilDate` field
 * holds; an I64 in packed decimal on the wire (docs/datetime-plan.md D2). */
export type CivilDate = { readonly year: number; readonly month: number; readonly day: number };
/** A civil time: hour and minute, no seconds (D3). */
export type CivilTime = { readonly hour: number; readonly minute: number };
export const CivilDate: unique symbol = Symbol("kaya.CivilDate");
export const CivilTime: unique symbol = Symbol("kaya.CivilTime");
export type CivilDateToken = typeof CivilDate;
export type CivilTimeToken = typeof CivilTime;
export type Token = StringConstructor | BooleanConstructor | NumberConstructor | Uint8ArrayConstructor | IntToken | CivilDateToken | CivilTimeToken;
export type Schema = { readonly [name: string]: Token };
type FieldOf<T> = T extends StringConstructor
  ? string
  : T extends BooleanConstructor
    ? boolean
    : T extends NumberConstructor
      ? number
      : T extends Uint8ArrayConstructor
        ? Uint8Array
        : T extends IntToken
          ? number
          : T extends CivilDateToken
            ? CivilDate
            : T extends CivilTimeToken
              ? CivilTime
              : never;
/** A record's fields as a plain object — what `insert` takes and the
 * mirror holds. */
export type Fields<S extends Schema> = { -readonly [K in keyof S]: FieldOf<S[K]> };
/** The row tracer inside a For over a record collection: one FieldRef
 * per schema field, ready to bind. */
export type Row<S extends Schema> = { readonly [K in keyof S]: FieldRef };

/** A record type: callable and constructible from its fields, and the
 * schema itself (the wire-typed fields in declaration order). */
export interface RecordType<S extends Schema = Schema> {
  (fields: Fields<S>): Fields<S>;
  new (fields: Fields<S>): Fields<S>;
  readonly schema: S;
  readonly name: string;
  readonly prototype: Fields<S>;
}

function wireTag(token: Token, name: string): number {
  if (token === String) return wire.VALUE_STR;
  if (token === Boolean) return wire.VALUE_BOOL;
  if (token === Number) return wire.VALUE_F64;
  if (token === Uint8Array) return wire.VALUE_BLOB;
  if (token === Int) return wire.VALUE_I64;
  if (token === CivilDate || token === CivilTime) return wire.VALUE_I64;
  throw new TypeError(
    `kaya: field ${JSON.stringify(name)} has no wire type — a schema names String, Boolean, Number, kaya.Int, kaya.CivilDate, kaya.CivilTime or Uint8Array per field`,
  );
}

/** A civil date's components, refused BY NAME when they are not one — a
 * plain object cannot type this the way DateOnly or LocalDate does, so
 * the packing site is the wall (docs/datetime-plan.md D2). */
export function dateParts(what: string, v: unknown): [number, number, number] {
  const d = v as CivilDate;
  if (typeof v !== "object" || v === null || typeof d.year !== "number" || typeof d.month !== "number" || typeof d.day !== "number") {
    throw new TypeError(`kaya: ${what} is a civil date {year, month, day}, not ${runtime.describe(v)}`);
  }
  const { year, month, day } = d;
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) {
    throw new TypeError(`kaya: ${what} takes whole year, month and day, not ${year}-${month}-${day}`);
  }
  if (month < 1 || month > 12) throw new TypeError(`kaya: ${what} has month ${month}, which is not a month (1..12)`);
  if (day < 1 || day > daysInMonth(year, month)) {
    throw new TypeError(`kaya: ${what} has day ${day}, which ${year}-${String(month).padStart(2, "0")} does not have`);
  }
  return [year, month, day];
}

function daysInMonth(year: number, month: number): number {
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]!;
}

/** A civil time's hour and minute, refused by name when they are not one. */
export function timeParts(what: string, v: unknown): [number, number] {
  const t = v as CivilTime;
  if (typeof v !== "object" || v === null || typeof t.hour !== "number" || typeof t.minute !== "number") {
    throw new TypeError(`kaya: ${what} is a civil time {hour, minute}, not ${runtime.describe(v)}`);
  }
  const { hour, minute } = t;
  if (!Number.isInteger(hour) || !Number.isInteger(minute)) {
    throw new TypeError(`kaya: ${what} takes a whole hour and minute, not ${hour}:${minute}`);
  }
  if (hour < 0 || hour > 23) throw new TypeError(`kaya: ${what} has hour ${hour}, which is not an hour (0..23)`);
  if (minute < 0 || minute > 59) throw new TypeError(`kaya: ${what} has minute ${minute}, which is not a minute (0..59)`);
  return [hour, minute];
}

function civilDate(packed: number): CivilDate {
  const [year, month, day] = wire.unpack_date(packed);
  return { year, month, day };
}

function civilTime(packed: number): CivilTime {
  const [hour, minute] = wire.unpack_time(packed);
  return { hour, minute };
}

/** Declare a record type: the schema IS the type, and the result both
 * calls and constructs — `Todo({title, done})`, `new Todo({...})`,
 * `entry instanceof Todo` in a sum's handlers. */
export function record<S extends Schema>(schema: S, name = "Record"): RecordType<S> {
  for (const field of Object.keys(schema)) wireTag(schema[field]!, field);
  if (Object.keys(schema).length === 0) throw new TypeError(`kaya: ${name} has no wire-typed fields`);
  const ctor = function (this: unknown, fields: Fields<S>): Fields<S> {
    const out = Object.create(ctor.prototype) as Fields<S>;
    Object.assign(out, fields);
    return out;
  } as unknown as RecordType<S>;
  Object.defineProperty(ctor, "schema", { value: schema, enumerable: true });
  Object.defineProperty(ctor, "name", { value: name });
  return ctor;
}

// ---------------------------------------------------------------- state

let _app: App | null = null;
let _tx: Uint8Array[] | null = null;
const _parents: (number | null)[] = []; // the container stack; null marks a template body's floor
const _menuScopes: MenuScope[] = [];
const _forStack: number[] = [];
const _openTraces: ForTrace[] = [];
const _forCollections: Collection<unknown, unknown>[] = [];
let _tplDepth = 0; // 0 = live zone; >0 = declaring a blueprint
const _canvasViewboxes = new Map<number, [number, number]>();
let _pendingRoot: Handle | null = null;

function pendingRoot(): Handle | null {
  return _pendingRoot;
}
let _recording = false;
let _journal: Map<unknown, () => void> | null = null;
let _implicit = false; // the open _tx was opened by a mutation, not a scope

/** The JS spelling of the rule the other bindings get from types: a
 * transaction belongs to the app thread. Every worker gets its OWN copy
 * of this module, so a foreign thread has no `_tx` to stamp into — what
 * it has is no App at all, and this names the way out. */
function requireAppThread(): void {
  if (!runtime.IS_APP_THREAD || _app === null) {
    throw new Error(
      "kaya: a transaction belongs to the app thread — this thread is not the one kaya's " +
        "App was created on. To mutate from elsewhere use app.post(fn) on the app thread, " +
        "which runs fn as a transaction over there (a worker reaches it through postMessage).",
    );
  }
}

function records(): Uint8Array[] {
  if (_tx === null) openImplicit();
  return _tx!;
}

/** THE IMPLICIT TRANSACTION (docs/js-plan.md §4): a mutation with no
 * transaction open opens one and a microtask commits it — one
 * continuation, one atomic batch. Declarations never open one, and a
 * top-level scope opened while one is pending commits it first. THE
 * RESIDUE: nothing sees a continuation throw, so writes before the throw
 * stand. */
function openImplicit(): void {
  requireAppThread();
  _tx = [];
  _journal = new Map();
  _implicit = true;
  queueMicrotask(commitImplicit);
}

function commitImplicit(): void {
  if (_tx === null || !_implicit) return;
  const recs = _tx;
  _tx = null;
  _journal = null;
  _implicit = false;
  if (recs.length > 0) runtime.submit(recs);
}

function journalOnce(key: unknown, restore: () => void): void {
  if (_journal !== null && !_journal.has(key)) _journal.set(key, restore);
}

/** journalOnce for the one restore whose SNAPSHOT costs O(model): taken
 * once per transaction, never per mutation (docs/deferred.md, "the
 * Python binding's insert is quadratic"). */
function journalInstances(coll: Collection<unknown, unknown>): void {
  if (_journal === null || _journal.has(coll)) return;
  const old = new Map<string, Map<unknown, unknown>>();
  for (const [path, entries] of coll._instances) old.set(path, new Map(entries));
  _journal.set(coll, () => {
    coll._instances.clear();
    for (const [path, entries] of old) coll._instances.set(path, entries);
  });
}

function guardTracerEscape(): void {
  if (!(_recording || _tplDepth > 0)) {
    throw new Error(
      "kaya: element tracers exist at record time only — a handler receives the stamped " +
        "copy's keys and reads the model (get()/items()), never the tracer",
    );
  }
}

function autoParent(childId: number): void {
  const top = _parents[_parents.length - 1];
  if (_parents.length > 0 && top !== null && top !== undefined) {
    records().push(wire.tx_add_child(top, childId));
  }
}

function guardMirrorRead(what: string): void {
  if (_recording || _tplDepth > 0) {
    throw new Error(
      `kaya: ${what} reads a mirror snapshot, which would freeze this branch at record time — ` +
        "bind the signal (or use kaya.when / kaya.forEach) in templates; read mirrors in handlers",
    );
  }
}

function textValue(what: string, text: unknown): string {
  if (typeof text !== "string") {
    throw new TypeError(
      `kaya: ${what} takes a string, not ${runtime.describe(text)} — encoded image bytes belong on kaya.image(bytes)`,
    );
  }
  return text;
}

/** One text range, normalized to the [start, stop] pair the wire
 * carries: UTF-8 BYTE offsets, non-negative, integers. Everything else
 * malformed is the core's to refuse with the text in hand. */
function textRange(what: string, span: unknown): [number, number] {
  if (!Array.isArray(span) || span.length !== 2) {
    throw new TypeError(
      `kaya: ${what} takes a text range — a [start, stop] pair of UTF-8 byte offsets — not ${runtime.describe(span)}`,
    );
  }
  const [start, stop] = span as [unknown, unknown];
  for (const [name, offset] of [
    ["start", start],
    ["stop", stop],
  ] as const) {
    if (typeof offset !== "number" || !Number.isInteger(offset)) {
      throw new TypeError(`kaya: ${what}: a range's ${name} is a UTF-8 byte offset (integer), not ${runtime.describe(offset)}`);
    }
    if (offset < 0) {
      throw new RangeError(
        `kaya: ${what}: a range's ${name} is ${offset} — offsets count from the start of the text and kaya has no end-relative spelling (indexOf answers -1 for no match; test for it)`,
      );
    }
  }
  return [start as number, stop as number];
}

/** A key on the wire: an integer number rides as an I64, anything else
 * as itself (docs/js-plan.md §4). */
function keyValue(key: unknown): wire.WireValue {
  if (typeof key === "number" && Number.isInteger(key)) return new I64(key);
  if (typeof key === "number" || typeof key === "string" || typeof key === "boolean") return key;
  throw new TypeError(`kaya: a key is a string or a number, not ${runtime.describe(key)}`);
}

function keyPath(path: readonly unknown[]): wire.WireValue[] {
  return path.map(keyValue);
}

/** A signal's value on the wire: a number is an F64 — no prop takes an
 * I64, and every integer derivation is computed here (docs/js-plan.md §4). */
function signalValue(what: string, v: unknown): wire.WireValue {
  if (typeof v === "number" || typeof v === "string" || typeof v === "boolean") return v;
  if (typeof v === "object" && v !== null && "year" in v) return new wire.I64(wire.pack_date(...dateParts(what, v)));
  if (typeof v === "object" && v !== null && "hour" in v) return new wire.I64(wire.pack_time(...timeParts(what, v)));
  throw new TypeError(`kaya: ${what} takes a string, a number, a boolean, a civil date or a civil time, not ${runtime.describe(v)}`);
}

/** A co-located handler. The parameters are open because the arity
 * varies by zone: a template copy's keys come FIRST, then the payload —
 * onToggle(checked) live, onToggle(key, checked) in a row. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Handler = (...args: any[]) => void;

// -------------------------------------------------------------- signals

export class Signal<T = unknown> {
  readonly id: number;
  /** @internal */ _mirror: T;
  /** @internal */ _dependents: Derived<unknown, unknown>[] = [];

  /** @internal */
  constructor(id: number, initial: T) {
    this.id = id;
    this._mirror = initial;
  }

  set(value: T): void {
    const old = this._mirror;
    journalOnce(this, () => {
      this._mirror = old;
    });
    records().push(wire.tx_write_signal(this.id, signalValue("a signal write", value)));
    this._mirror = value;
    for (const derived of this._dependents) derived._recompute();
  }

  // No read method, deliberately: signals are a render pipe, not a
  // state bus. The internal mirror feeds derivations and skips no-op
  // derived writes.

  /** @internal */
  _derive<U>(compute: (v: T) => U): Signal<U> {
    const derived = new Derived<T, U>(app()._next("signal"), this, compute);
    app()._signals.set(derived.id, derived as Signal<unknown>);
    records().push(wire.tx_create_signal(derived.id, signalValue("a derived signal", derived._mirror)));
    this._dependents.push(derived as Derived<unknown, unknown>);
    return derived;
  }

  /** A derived boolean signal: this value === other. */
  eq(other: T): Signal<boolean> {
    return this._derive((v) => v === other);
  }
  ne(other: T): Signal<boolean> {
    return this._derive((v) => v !== other);
  }
  lt(other: T): Signal<boolean> {
    return this._derive((v) => (v as number) < (other as number));
  }
  gt(other: T): Signal<boolean> {
    return this._derive((v) => (v as number) > (other as number));
  }
  le(other: T): Signal<boolean> {
    return this._derive((v) => (v as number) <= (other as number));
  }
  ge(other: T): Signal<boolean> {
    return this._derive((v) => (v as number) >= (other as number));
  }
  /** A derived string signal: `count.fmt((n) => `${n} items`)`. */
  fmt(format: (v: T) => string): Signal<string> {
    return this._derive(format);
  }
}

/** Binding-maintained: recomputed when the source is written, the write
 * batched into the same transaction. The core sees an ordinary signal. */
class Derived<T, U> extends Signal<U> {
  private readonly _source: Signal<T>;
  private readonly _compute: (v: T) => U;

  constructor(id: number, source: Signal<T>, compute: (v: T) => U) {
    super(id, compute(source._mirror));
    this._source = source;
    this._compute = compute;
  }

  override set(_value: U): void {
    throw new Error("kaya: derived signals are written by their source");
  }

  /** @internal */
  _recompute(): void {
    const next = this._compute(this._source._mirror);
    if (next !== this._mirror) {
      const old = this._mirror;
      journalOnce(this, () => {
        this._mirror = old;
      });
      records().push(wire.tx_write_signal(this.id, signalValue("a derived signal", next)));
      this._mirror = next;
      for (const derived of this._dependents) derived._recompute();
    }
  }
}

/** A derived string over ANY number of signals, from a template literal:
 * kaya.fmt`${count} items left` (docs/js-plan.md §4). A signal
 * interpolates as its current value and the string is recomputed
 * binding-side whenever any of them moves. */
export function fmt(strings: TemplateStringsArray, ...parts: readonly unknown[]): Signal<string> {
  if (!Array.isArray(strings) || !("raw" in strings)) {
    throw new TypeError("kaya: fmt is a template tag — kaya.fmt`${signal} text`; Signal.fmt((v) => ...) is the function form");
  }
  const sources: Signal<unknown>[] = [];
  for (const part of parts) {
    if (part instanceof Signal) sources.push(part);
    else if (part instanceof Element || part instanceof FieldRef || part instanceof CaseElement) {
      throw new TypeError("kaya: fmt interpolates signals and constants; a row's field is bound with { bind: field }, not formatted");
    }
  }
  const compute = (): string => {
    let out = strings[0] ?? "";
    parts.forEach((part, i) => {
      out += String(part instanceof Signal ? part._mirror : part) + (strings[i + 1] ?? "");
    });
    return out;
  };
  const derived = new TemplateDerived(app()._next("signal"), sources, compute);
  app()._signals.set(derived.id, derived as Signal<unknown>);
  records().push(wire.tx_create_signal(derived.id, signalValue("a formatted signal", derived._mirror)));
  for (const source of sources) source._dependents.push(derived as unknown as Derived<unknown, unknown>);
  return derived;
}

class TemplateDerived extends Signal<string> {
  private readonly _compute: () => string;

  constructor(id: number, _sources: readonly Signal<unknown>[], compute: () => string) {
    super(id, compute());
    this._compute = compute;
  }

  override set(_value: string): void {
    throw new Error("kaya: a formatted signal is written by the signals it interpolates");
  }

  _recompute(): void {
    const next = this._compute();
    if (next !== this._mirror) {
      const old = this._mirror;
      journalOnce(this, () => {
        this._mirror = old;
      });
      records().push(wire.tx_write_signal(this.id, signalValue("a formatted signal", next)));
      this._mirror = next;
      for (const derived of this._dependents) derived._recompute();
    }
  }
}

class CollectionDerived<E, U> extends Signal<U> {
  private readonly _coll: BoundCollection<E, unknown>;
  private readonly _compute: (entries: Map<Key, E>) => U;

  constructor(id: number, coll: BoundCollection<E, unknown>, compute: (entries: Map<Key, E>) => U) {
    super(id, compute(new Map(coll._mirror())));
    this._coll = coll;
    this._compute = compute;
  }

  override set(_value: U): void {
    throw new Error("kaya: derived signals are written by their source");
  }

  /** @internal */
  _recompute(): void {
    const next = this._compute(new Map(this._coll._mirror()));
    if (next !== this._mirror) {
      const old = this._mirror;
      journalOnce(this, () => {
        this._mirror = old;
      });
      records().push(wire.tx_write_signal(this.id, signalValue("a derived signal", next)));
      this._mirror = next;
      for (const derived of this._dependents) derived._recompute();
    }
  }
}

/** A bindable source for a text prop: a constant, a Signal, the enclosing
 * For's element, or one of its fields. */
export type Bindable = Signal<unknown> | Element | FieldRef;

/** One prop write from whichever source the guest handed over. The
 * source arms come first and the constant arm last (Python's ordering,
 * for its reason: the constant arm coerces). */
function propSource(
  what: string,
  handle: Handle,
  value: unknown,
  constFn: (id: number, v: string) => Uint8Array,
  signalFn: (id: number, sig: number) => Uint8Array,
  elementFn: (id: number, level: number, field?: number) => Uint8Array,
): Uint8Array {
  if (value instanceof Signal) return signalFn(handle.id, value.id);
  if (value instanceof FieldRef) return elementFn(handle.id, value._level(), value._index);
  if (value instanceof Element) return elementFn(handle.id, value._level());
  if (value instanceof CaseElement) {
    throw new TypeError(
      `kaya: ${what} takes a string, a Signal or one of the row's fields (row.title), not a case element — inside a case arm project the field: .a11yLabel(note.text)`,
    );
  }
  return constFn(handle.id, textValue(what, value));
}

// -------------------------------------------------------------- handles

/** What carries props: a live widget, or a template node. One handle
 * type serves both zones because the transaction is ambient; which
 * sources are reachable differs by zone, not the call. */
export class Handle {
  readonly id: number;

  /** @internal */
  constructor(id: number) {
    this.id = id;
  }

  /** The accessibility IDENTIFIER: a stable authored key automation
   * addresses it by, never spoken. In a template take it from the row
   * (`row.slug`): the copies of one node share a node id. Chains. */
  a11yId(ident: Bindable | string): this {
    records().push(propSource("a11yId", this, ident, wire.tx_set_a11y_id, wire.tx_bind_a11y_id, wire.tx_bind_a11y_id_element));
    return this;
  }

  /** What ACTIVATING this widget does, as a verb phrase. Activation
   * kinds only; the root rejects it elsewhere. Chains. */
  a11yHint(hint: Bindable | string): this {
    records().push(propSource("a11yHint", this, hint, wire.tx_set_a11y_hint, wire.tx_bind_a11y_hint, wire.tx_bind_a11y_hint_element));
    return this;
  }

  /** The accessibility LABEL: what an assistive client speaks. The row's
   * own field is the case this exists for. Chains. */
  a11yLabel(label: Bindable | string): this {
    records().push(propSource("a11yLabel", this, label, wire.tx_set_a11y_label, wire.tx_bind_a11y_label, wire.tx_bind_a11y_label_element));
    return this;
  }

  /** HELP TEXT: one short sentence saying what this control is or does.
   * The platform picks the surface — a tooltip on the desktops, nothing
   * visible on the iPhone — and hands it to the assistive reader
   * (docs/tooltip-plan.md T1/T2). An authored `a11yHint` wins the hint
   * slot. Chains. */
  help(text: Bindable | string): this {
    records().push(propSource("help", this, text, wire.tx_set_help, wire.tx_bind_help, wire.tx_bind_help_element));
    return this;
  }

  /** Whether this widget spans its container's cross axis — a column's
   * width, a row's height — whatever the container's `align`
   * (docs/layout-knobs-plan.md §1). Unset, the kind's own default holds.
   * Chains. */
  fill(on: boolean): this {
    records().push(wire.tx_set_fill(this.id, Boolean(on)));
    return this;
  }

  /** THE GRID THAT FITS (docs/layout-knobs-plan.md §3): as many columns
   * as fit this grid's width at `minWidth` DIP each, sharing the extra.
   * An explicit `columnsWhen` still wins while its class holds. Chains. */
  columnsAuto(minWidth: number): this {
    records().push(wire.tx_set_columns(this.id, 0));
    records().push(wire.tx_set_min_column_width(this.id, Number(minWidth)));
    return this;
  }

  /** A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): children keep their
   * natural size and move onto the next line when the row runs out of
   * width, leading-aligned, the row's `spacing` on both axes. No child of
   * a wrapping row may grow. Chains. */
  wrap(on: boolean): this {
    records().push(wire.tx_set_wrap(this.id, Boolean(on)));
    return this;
  }

  /** Declare what this widget takes from a paste — the closed kinds by
   * name plus any custom format ids. Constant in a template: an accept
   * list describes the prototype, not the row. Chains. */
  accepts(...kinds: string[]): this {
    for (const kind of kinds as readonly unknown[]) {
      if (kind instanceof Signal || kind instanceof Element || kind instanceof CaseElement || kind instanceof FieldRef) {
        throw new TypeError(
          `kaya: accepts takes constant kinds, not ${runtime.describe(kind)} — an accept list describes the control and not the row; rows that take different things are different variants, one cases.case(...) arm each`,
        );
      }
    }
    records().push(wire.tx_set_accepts(this.id, acceptList(kinds)));
    return this;
  }

  /** Declare what this widget MEANS — never how it looks
   * (docs/styling-plan.md D4): kaya.Role.HEADING or its name. Chains. */
  role(role: RoleValue | RoleName): this {
    records().push(wire.tx_set_role(this.id, roleValue(role)));
    return this;
  }

  /** Take pasted content here: fn(clip), or fn(...keys, clip) for a
   * stamped copy. Only fires for a widget that declared what it
   * `accepts`. Chains. */
  onPaste(fn: Handler): this {
    app()._register(this, wire.OCC_PASTED, fn);
    return this;
  }

  /** DECLARE what this widget hands over when dragged: a clip in the
   * shapes `copy` takes, plus the operations it allows. App-updated
   * state — re-declare when the payload changes, and declaring NOTHING
   * withdraws it, which is how a same-app move removes its source
   * (docs/dnd-plan.md D1, D2). Chains. */
  draggable(opts: DraggableOptions = {}): this {
    return this._draggable([], opts);
  }

  /** ONE stamped copy's drag declaration (docs/dnd-plan.md §4): the
   * copy's keys, outermost first, then the payload `draggable` takes.
   * The per-row payload an app declares after the row's insert; it
   * overrides the template's own for that copy and follows it through a
   * re-stamp. Chains. */
  draggableAt(keys: Key[], opts: DraggableOptions = {}): this {
    templateZoneOnly(this, "draggableAt");
    return this._draggable(keys, opts);
  }

  private _draggable(keys: Key[], opts: DraggableOptions): this {
    const reps: wire.WireValue[] = [];
    let present = 0;
    let bound = 0;
    const custom = Object.entries(opts.custom ?? {});
    const files = [...(opts.files ?? [])];
    // Append one representation, bound or constant, and say which it
    // was — the slot IS its index in `reps`.
    const slot = (what: string, value: unknown): boolean => {
      const ref = dragSlot(this, keys, what, value);
      if (ref === null) return false;
      bound |= 1 << reps.length;
      reps.push(ref);
      return true;
    };
    for (const [ident, data] of custom) {
      acceptList([ident]);
      reps.push(ident);
      if (!slot("custom bytes", data)) reps.push(new BlobHandle(runtime.registerBlob(data as Uint8Array)));
    }
    for (const picked of files) reps.push(new I64(typeof picked === "number" ? picked : picked.handle));
    if (opts.image !== undefined) {
      present |= wire.CLIP_IMAGE;
      if (!slot("image", opts.image)) reps.push(new BlobHandle(runtime.registerBlob(opts.image as Uint8Array)));
    }
    if (opts.html !== undefined) {
      present |= wire.CLIP_HTML;
      if (!slot("html", opts.html)) reps.push(String(opts.html));
    }
    if (opts.text !== undefined) {
      present |= wire.CLIP_TEXT;
      if (!slot("text", opts.text)) reps.push(String(opts.text));
    }
    const empty = present === 0 && files.length === 0 && custom.length === 0;
    const mask = empty ? 0 : operationMask(opts.operations ?? [OP_COPY]);
    records().push(wire.tx_set_drag_source(this.id, present, files.length, custom.length, mask, keys.length, bound, [...keyPath(keys), ...reps]));
    return this;
  }

  /** DECLARE that this widget receives drops, performing these
   * operations; naming NONE withdraws the declaration. WHAT it takes is
   * its `accepts` list, which must be declared first — a destination has
   * one vocabulary, not two (docs/dnd-plan.md D1). Chains. */
  dropTarget(...operations: string[]): this {
    records().push(wire.tx_set_drop_target(this.id, operationMask(operations), 0, []));
    return this;
  }

  /** ONE stamped copy's drop declaration, `draggableAt`'s twin; the
   * copy's accept list is the template's `accepts`. Chains. */
  dropTargetAt(keys: Key[], ...operations: string[]): this {
    templateZoneOnly(this, "dropTargetAt");
    records().push(wire.tx_set_drop_target(this.id, operationMask(operations), keys.length, keyPath(keys)));
    return this;
  }

  /** Take dropped content here: fn(dropped), the `Dropped` of
   * docs/dnd-plan.md D1. Only fires for a widget that declared
   * `dropTarget` over an `accepts` list, or for a reorderable For's
   * container (D8). Chains. */
  onDrop(fn: Handler): this {
    app()._register(this, wire.OCC_DROPPED, fn);
    return this;
  }

  /** A drag that began here has ended: fn(operation), OP_COPY, OP_MOVE
   * or null for cancelled or refused. Chains. */
  onDragEnded(fn: Handler): this {
    app()._register(this, wire.OCC_DRAG_ENDED, fn);
    return this;
  }

  /** DECLARE the whole drawing on a canvas, replacing whatever was
   * declared before: `chart.draw((d) => {...})`. On a template node the
   * leading keys select ONE stamped copy; with none the drawing every
   * copy is born with (docs/canvas-plan.md §2.1, §3.1). */
  draw(...args: [...Key[], (d: Draw) => void]): void {
    const body = args[args.length - 1];
    if (typeof body !== "function") throw new TypeError("kaya: draw takes its body last: chart.draw((d) => {...})");
    const keys = args.slice(0, -1) as Key[];
    const viewbox = _canvasViewboxes.get(this.id);
    if (viewbox === undefined) {
      throw new Error(
        `kaya: draw() on widget ${this.id} — that is not a canvas this app declared; a drawing is a declaration against the canvas it draws on (docs/canvas-plan.md §2.1)`,
      );
    }
    const d = new Draw(viewbox);
    body(d);
    const [w, h] = d.viewbox;
    const ops = d._ops;
    records().push(wire.tx_set_drawing(this.id, w, h, ops.length, keys.length, [...keyPath(keys), ...ops]));
  }
}

/** A widget handle: a LIVE widget, or a TEMPLATE NODE whose copies'
 * clicks and pastes arrive with the copy's key path. One class for both,
 * `isNode` saying which; the one-shot commands and dynamic prop setters
 * refuse a node, whose declarative spelling is the constructor option. */
export class Widget extends Handle {
  /** True for a template node: declared inside a For or When body. */
  readonly isNode: boolean;

  /** @internal */
  constructor(id: number, isNode: boolean) {
    super(id);
    this.isNode = isNode;
  }

  private _live(what: string): void {
    if (this.isNode) {
      throw new Error(`kaya: ${what} on a template node — a blueprint is declared once and never mutated; the declarative spelling is the constructor option, and a copy's momentary state has no command surface`);
    }
  }

  /** Drop an entry's content now (the field stays authoritative). */
  clear(): void {
    this._live("clear()");
    records().push(wire.tx_widget_command(this.id, wire.COMMAND_CLEAR));
  }

  /** Give this widget the keyboard focus. */
  focus(): void {
    this._live("focus()");
    records().push(wire.tx_widget_command(this.id, wire.COMMAND_FOCUS));
  }

  /** Put text into a text widget programmatically: ONE write, after
   * which the user owns the text again. Drops declared ranges and the
   * field's native undo history. Chains. */
  setText(text: string): this {
    this._live("setText()");
    records().push(wire.tx_set_text(this.id, textValue("setText", text)));
    return this;
  }

  /** DECLARE this textarea's decorated ranges (UTF-8 BYTE offsets —
   * search the bytes, `Buffer.indexOf`, and the offsets are kaya's by
   * construction), replacing whatever was declared before; an empty set
   * is the clear. */
  highlightRanges(ranges: readonly (readonly [number, number])[]): this {
    this._live("highlightRanges()");
    const flat: wire.WireValue[] = [];
    for (const span of ranges) {
      const [start, stop] = textRange("highlightRanges", span);
      flat.push(new I64(start), new I64(stop));
    }
    records().push(wire.tx_highlight_ranges(this.id, flat.length / 2, flat));
    return this;
  }

  /** Put this textarea's selection at one range (an empty range is a
   * caret). Refused while the user is composing, in every backend. */
  selectRange(span: readonly [number, number]): this {
    this._live("selectRange()");
    const [start, stop] = textRange("selectRange", span);
    records().push(wire.tx_select_range(this.id, start, stop));
    return this;
  }

  /** Scroll this textarea so a range is inside the viewport. */
  revealRange(span: readonly [number, number]): this {
    this._live("revealRange()");
    const [start, stop] = textRange("revealRange", span);
    records().push(wire.tx_reveal_range(this.id, start, stop));
    return this;
  }

  /** This widget's flex weight within its row/column (the dynamic path;
   * the constructor's `grow` is the declarative one). */
  grow(weight: number): this {
    this._live("grow()");
    records().push(wire.tx_set_grow(this.id, Number(weight)));
    return this;
  }

  /** This container's cross-axis child placement (kaya.Align or its
   * name). Containers only; baseline is rows-only. */
  align(mode: AlignValue | AlignName): this {
    this._live("align()");
    records().push(wire.tx_set_align(this.id, alignValue(mode)));
    return this;
  }

  /** This container's arrangement direction (kaya.Axis or its name) —
   * the user-driven orientation toggle (docs/adaptive-layout-plan.md
   * D2). Row/column only. */
  axis(mode: AxisValue | AxisName): this {
    this._live("axis()");
    records().push(wire.tx_set_axis(this.id, axisValue(mode)));
    return this;
  }

  /** This container's inter-child gap (main axis, DIP; default 8). */
  spacing(gap: number): this {
    this._live("spacing()");
    records().push(wire.tx_set_spacing(this.id, Number(gap)));
    return this;
  }

  /** This container's own padding, uniform on all four sides. Live-only:
   * a blueprint is declared once, and a template's inset is the
   * constructor option. */
  inset(pad: number): this {
    this._live("inset()");
    records().push(wire.tx_set_inset(this.id, Number(pad)));
    return this;
  }

  /** The context anchor. LIVE: the body declares the command vocabulary
   * scoped to this NOUN (no shortcuts here). TEMPLATE NODE: attach a
   * live-zone-built catalog, each activation carrying that copy's key
   * path; an item takes exactly ONE anchor. */
  contextMenu(bodyOrCatalog: (() => void) | ContextCatalog): this {
    if (bodyOrCatalog instanceof ContextCatalog) {
      if (!this.isNode) {
        throw new TypeError("kaya: a live widget's context menu is declared in place — widget.contextMenu(() => {...}); a catalog attaches to a template node");
      }
      if (bodyOrCatalog._attached) throw new Error("kaya: a context catalog takes exactly one anchor");
      bodyOrCatalog._attached = true;
      bodyOrCatalog._owner = _forCollections[_forCollections.length - 1] ?? null;
      for (const root of bodyOrCatalog._roots) records().push(wire.tx_context_attach_node(this.id, root));
      return this;
    }
    if (this.isNode) {
      throw new TypeError("kaya: a template node's context menu is a catalog built in the live zone (kaya.contextCatalog) and attached with node.contextMenu(catalog)");
    }
    new MenuScope(["widget", this.id], false).run(bodyOrCatalog);
    return this;
  }
}

/** The element of an enclosing For over a SCALAR collection: the value
 * itself, bindable wherever a text source goes. A record collection's
 * row is a Row<S> of FieldRefs instead. */
export class Element {
  /** @internal */ readonly _forIndex: number;
  /** @internal */ readonly _coll: Collection<unknown, unknown>;

  /** @internal */
  constructor(forIndex: number, coll: Collection<unknown, unknown>) {
    this._forIndex = forIndex;
    this._coll = coll;
  }

  /** @internal */
  _level(): number {
    return _forStack.length - 1 - this._forIndex;
  }
}

/** One field of an element: index plus level, ready to bind. */
export class FieldRef {
  /** @internal */ readonly _element: Element | CaseElement;
  /** @internal */ readonly _index: number;
  /** @internal The schema token: a CivilDate field and an Int one share
   * the I64 tag, so nothing below this can tell them apart. */
  readonly _token: Token | null;

  /** @internal */
  constructor(element: Element | CaseElement, index: number, token: Token | null = null) {
    this._element = element;
    this._index = index;
    this._token = token;
  }

  /** @internal */
  _level(): number {
    return this._element._level();
  }
}

/** The row tracer for a record collection: an Element carrying one
 * FieldRef getter per schema field. */
function rowTracer(forIndex: number, coll: Collection<unknown, unknown>, spec: Variant): Element {
  const element = new Element(forIndex, coll);
  for (const [name, index] of spec.fields ?? []) {
    Object.defineProperty(element, name, {
      enumerable: true,
      get: () => {
        guardTracerEscape();
        return new FieldRef(element, index, spec.tokens[index] ?? null);
      },
    });
  }
  return element;
}

/** The eliminator over a sum collection: one `cases.case(Ctor, (el) =>
 * ...)` per constructor, in any order. The scene holds the arms to
 * TOTALITY at declaration; an empty body renders one as nothing. */
export class Cases {
  private readonly _forIndex: number;
  private readonly _coll: Collection<unknown, unknown>;

  /** @internal */
  constructor(forIndex: number, coll: Collection<unknown, unknown>) {
    this._forIndex = forIndex;
    this._coll = coll;
  }

  case<S extends Schema>(ctor: RecordType<S>, body: (el: Row<S>) => void): void {
    const variant = this._coll._variants.findIndex((v) => v.ctor === ctor);
    if (variant < 0) throw new TypeError(`kaya: ${ctor.name} is not a constructor of this collection's union`);
    records().push(wire.tx_variant_case(variant));
    const spec = this._coll._variants[variant]!;
    const el = new CaseElement(this._forIndex, this._coll, variant);
    for (const [name, index] of spec.fields ?? []) {
      Object.defineProperty(el, name, {
        enumerable: true,
        get: () => {
          guardTracerEscape();
          return new FieldRef(el, index);
        },
      });
    }
    body(el as unknown as Row<S>);
  }
}

/** The element proxy refined to one constructor. */
export class CaseElement {
  /** @internal */ readonly _forIndex: number;
  /** @internal */ readonly _coll: Collection<unknown, unknown>;
  /** @internal */ readonly _variant: number;

  /** @internal */
  constructor(forIndex: number, coll: Collection<unknown, unknown>, variant: number) {
    this._forIndex = forIndex;
    this._coll = coll;
    this._variant = variant;
  }

  /** @internal */
  _level(): number {
    return _forStack.length - 1 - this._forIndex;
  }
}

// ---------------------------------------------------------- collections

export type Key = string | number;

/** One constructor's wire shape: the record type, its wire-typed fields
 * in declaration order, and precompiled encoders. ctor null is the
 * scalar. */
class Variant {
  readonly ctor: RecordType | null;
  readonly fields: Map<string, number> | null;
  readonly names: string[];
  readonly schema: number[];
  readonly tokens: Token[];
  readonly encoders: ((v: unknown, name: string) => wire.WireValue)[];
  readonly decoders: ((v: wire.Decoded) => unknown)[];

  constructor(ctor: RecordType | null) {
    this.ctor = ctor;
    this.names = [];
    this.schema = [];
    this.tokens = [];
    this.encoders = [];
    this.decoders = [];
    if (ctor === null) {
      this.fields = null;
      this.schema.push(wire.VALUE_STR);
      this.encoders.push((v, name) => {
        if (typeof v !== "string") throw new TypeError(`kaya: a scalar collection holds strings, not ${runtime.describe(v)} (${name})`);
        return v;
      });
      this.decoders.push((v) => v);
      return;
    }
    this.fields = new Map();
    for (const [name, token] of Object.entries(ctor.schema)) {
      const tag = wireTag(token, name);
      this.fields.set(name, this.schema.length);
      this.names.push(name);
      this.schema.push(tag);
      this.tokens.push(token);
      this.encoders.push(fieldEncoder(token, tag, ctor.name));
      this.decoders.push(fieldDecoder(token));
    }
  }
}

function fieldDecoder(token: Token): (v: wire.Decoded) => unknown {
  if (token === CivilDate) return (v) => civilDate(v as number);
  if (token === CivilTime) return (v) => civilTime(v as number);
  return (v) => v;
}

function fieldEncoder(token: Token, tag: number, type: string): (v: unknown, name: string) => wire.WireValue {
  const refuse = (v: unknown, name: string, want: string): never => {
    throw new TypeError(`kaya: ${type}.${name} is a ${want} field and got ${runtime.describe(v)}`);
  };
  if (token === CivilDate) return (v, name) => new wire.I64(wire.pack_date(...dateParts(`${type}.${name}`, v)));
  if (token === CivilTime) return (v, name) => new wire.I64(wire.pack_time(...timeParts(`${type}.${name}`, v)));
  switch (tag) {
    case wire.VALUE_STR:
      return (v, name) => (typeof v === "string" ? v : refuse(v, name, "string"));
    case wire.VALUE_BOOL:
      return (v, name) => (typeof v === "boolean" ? v : refuse(v, name, "boolean"));
    case wire.VALUE_F64:
      return (v, name) => (typeof v === "number" ? v : refuse(v, name, "number"));
    case wire.VALUE_I64:
      return (v, name) => (typeof v === "number" && Number.isSafeInteger(v) ? new I64(v) : refuse(v, name, "kaya.Int (safe integer)"));
    case wire.VALUE_BLOB:
      // At encode time: handles are single-submit, so every mutation
      // carrying a blob field re-registers.
      return (v, name) => (v instanceof Uint8Array ? new BlobHandle(runtime.registerBlob(v)) : refuse(v, name, "Uint8Array"));
    default:
      throw new Error(`kaya: no encoder for wire type ${tag}`);
  }
}

/** The header bar's sort indicator (docs/tables-plan.md): which column
 * shows it, in which direction — the GUEST's declaration, re-sent after
 * it handles a sort request. The platform never sorts. */
export class Sort {
  readonly sorted: number;
  readonly direction: number;

  private constructor(sorted: number, direction: number) {
    this.sorted = sorted;
    this.direction = direction;
  }

  /** Ascending on `column` (0-based, in the declared order). */
  static asc(column: number): Sort {
    return new Sort(column, 0);
  }

  /** Descending on `column`. */
  static desc(column: number): Sort {
    return new Sort(column, 1);
  }

  /** The no-indicator bar (the wire's u32 none-sentinel). */
  static readonly NONE: Sort = new Sort(0xffff_ffff, 0);
}

/** A draft scope for bulk mutation (`coll.change((d) => ...)`): `set`
 * inserts or updates (resolved from the model), `delete` removes, reads
 * see the draft's own writes. Each operation records its patch
 * immediately; THE SCOPE IS SYNTAX, NOT A BARRIER. */
export class Draft<E> {
  private readonly _bound: BoundCollection<E, unknown>;

  /** @internal */
  constructor(bound: BoundCollection<E, unknown>) {
    this._bound = bound;
  }

  set(key: Key, value: E): void {
    if (this._bound._mirror().has(key)) this._bound.update(key, value);
    else this._bound.insert(key, value);
  }

  delete(key: Key): void {
    this._bound.remove(key);
  }

  get(key: Key): E | undefined {
    guardMirrorRead("draft reads");
    return this._bound._mirror().get(key);
  }

  has(key: Key): boolean {
    guardMirrorRead("draft membership");
    return this._bound._mirror().has(key);
  }
}

/** One instance of a collection: the table inside the copy selected by
 * `path` (the empty path for a live-zone collection). */
export class BoundCollection<E, R> {
  /** @internal */ readonly _owner: Collection<E, R>;
  /** @internal */ readonly _path: Key[];

  /** @internal */
  constructor(owner: Collection<E, R>, path: Key[]) {
    this._owner = owner;
    this._path = path;
  }

  /** @internal */
  _mirror(): Map<Key, E> {
    journalInstances(this._owner as Collection<unknown, unknown>);
    const key = pathKey(this._path);
    let table = this._owner._instances.get(key) as Map<Key, E> | undefined;
    if (table === undefined) {
      table = new Map();
      this._owner._instances.set(key, table as Map<unknown, unknown>);
    }
    return table;
  }

  /** @internal */
  _encode(value: E): [number, wire.WireValue[]] {
    const [variant, spec] = this._owner._variantFor(value);
    if (spec.fields === null) return [variant, [spec.encoders[0]!(value, "value")]];
    const fields: wire.WireValue[] = [];
    for (let i = 0; i < spec.names.length; i++) {
      const name = spec.names[i]!;
      fields.push(spec.encoders[i]!((value as Record<string, unknown>)[name], name));
    }
    return [variant, fields];
  }

  /** A signal the binding recomputes from this collection's entries after
   * every mutation, batched into the same transaction. The function is
   * pure presentation: entries (a Map, insertion order) in, one value out. */
  derive<U extends string | number | boolean>(compute: (entries: Map<Key, E>) => U): Signal<U> {
    if (this._path.length > 0) throw new Error("kaya: derive on the collection itself, not an instance — drop the at()");
    const derived = new CollectionDerived<E, U>(app()._next("signal"), this, compute);
    app()._signals.set(derived.id, derived as Signal<unknown>);
    records().push(wire.tx_create_signal(derived.id, signalValue("a derived signal", derived._mirror)));
    const list = this._owner._derived;
    list.push(derived as unknown as CollectionDerived<unknown, unknown>);
    journalOnce(["derive", derived], () => {
      const at = list.indexOf(derived as unknown as CollectionDerived<unknown, unknown>);
      if (at >= 0) list.splice(at, 1);
    });
    return derived;
  }

  /** @internal */
  _recomputeDerived(): void {
    // Deriveds hang off root handles, so nested-instance mutations
    // cannot change their input.
    if (this._path.length === 0) for (const derived of this._owner._derived) derived._recompute();
  }

  /** Re-declare this collection instance's header bar after sorting. */
  setColumns(titles: readonly string[], opts: { sort?: Sort } = {}): void {
    const handle = this._owner._forHandle;
    if (handle === null) {
      throw new Error("kaya: setColumns before columns() — the header bar is declared with the For, then re-declared here");
    }
    const sort = opts.sort ?? Sort.NONE;
    records().push(wire.tx_set_column_headers(handle, sort.sorted, sort.direction, titles.length, this._path.length, [...keyPath(this._path), ...titles]));
  }

  /** @internal An explicit key, shown to the minter on its way into the
   * table: a numeric key at or above the counter carries it up. */
  _absorbKey(key: Key): void {
    if (typeof key !== "number" || !Number.isInteger(key)) return;
    const path = pathKey(this._path);
    if (key > (this._owner._fresh.get(path) ?? 0)) this._owner._fresh.set(path, key);
  }

  insert(key: Key, value: E): void {
    const [variant, fields] = this._encode(value);
    this._absorbKey(key);
    records().push(wire.tx_collection_insert(this._owner._id, keyPath(this._path), keyValue(key), variant, fields));
    this._mirror().set(key, value);
    this._recomputeDerived();
  }

  /** Insert a record under a key the binding authors, and hand the key
   * back. One counter per collection instance, starting at 0; a fresh key
   * is fresh forever, since the counter sits outside the rollback journal
   * on purpose (docs/fresh-key-plan.md). */
  insertFresh(value: E): number {
    const path = pathKey(this._path);
    const key = (this._owner._fresh.get(path) ?? 0) + 1;
    this._owner._fresh.set(path, key);
    this.insert(key, value);
    return key;
  }

  update(key: Key, value: E): void {
    const [variant, fields] = this._encode(value);
    records().push(wire.tx_collection_update(this._owner._id, keyPath(this._path), keyValue(key), variant, fields));
    this._mirror().set(key, value);
    this._recomputeDerived();
  }

  /** Field-level deltas: `todos.patch(k, {done: true})` sends one
   * update_field per field and mutates the model entry in place. On a sum
   * the entry's CURRENT CONSTRUCTOR is the witness — a field it lacks
   * throws here. */
  patch(key: Key, fields: Partial<E>): void {
    const entry = this._mirror().get(key);
    if (entry === undefined) throw new Error(`kaya: patch of missing key ${JSON.stringify(key)}`);
    const [variant, spec] = this._owner._variantFor(entry);
    if (spec.fields === null) throw new TypeError("kaya: patch() needs a record collection");
    for (const [name, value] of Object.entries(fields)) {
      const index = spec.fields.get(name);
      if (index === undefined) throw new Error(`kaya: ${spec.ctor?.name ?? "the record"} has no wire field ${JSON.stringify(name)}`);
      records().push(
        wire.tx_collection_update_field(this._owner._id, keyPath(this._path), keyValue(key), index, variant, spec.encoders[index]!(value, name)),
      );
      (entry as Record<string, unknown>)[name] = value;
    }
    this._recomputeDerived();
  }

  /** Reposition an entry before another's key. Keys, never indices; a
   * missing key or anchor throws, and moving before itself is a no-op. */
  moveBefore(key: Key, anchor: Key): void {
    this._move(key, [anchor]);
  }

  moveToEnd(key: Key): void {
    this._move(key, []);
  }

  moveToFront(key: Key): void {
    const keys = [...this._mirror().keys()];
    if (keys.length === 0) throw new Error(`kaya: move of missing key ${JSON.stringify(key)}`);
    this._move(key, [keys[0]!]);
  }

  moveAfter(key: Key, anchor: Key): void {
    const keys = [...this._mirror().keys()];
    if (!keys.includes(key)) throw new Error(`kaya: move of missing key ${JSON.stringify(key)}`);
    if (!keys.includes(anchor)) throw new Error(`kaya: move after missing key ${JSON.stringify(anchor)}`);
    if (key === anchor) return;
    const at = keys.indexOf(anchor);
    const succ = at + 1 < keys.length ? keys[at + 1] : undefined;
    if (succ === key) return;
    this._move(key, succ === undefined ? [] : [succ]);
  }

  private _move(key: Key, before: Key[]): void {
    const mirror = this._mirror();
    if (!mirror.has(key)) throw new Error(`kaya: move of missing key ${JSON.stringify(key)}`);
    if (before.length > 0 && !mirror.has(before[0]!)) throw new Error(`kaya: move before missing key ${JSON.stringify(before[0])}`);
    if (before.length > 0 && before[0] === key) return;
    records().push(wire.tx_collection_move(this._owner._id, keyPath(this._path), keyValue(key), keyPath(before)));
    const value = mirror.get(key) as E;
    mirror.delete(key);
    if (before.length > 0) {
      const anchor = before[0]!;
      const tail = [...mirror.entries()];
      const cut = tail.findIndex(([k]) => k === anchor);
      for (const [k] of tail.slice(cut)) mirror.delete(k);
      mirror.set(key, value);
      for (const [k, v] of tail.slice(cut)) mirror.set(k, v);
    } else {
      mirror.set(key, value);
    }
    this._recomputeDerived();
  }

  remove(key: Key): void {
    records().push(wire.tx_collection_remove(this._owner._id, keyPath(this._path), keyValue(key)));
    this._mirror().delete(key);
    this._recomputeDerived();
    // The core tears down the copy, taking descendant collection
    // instances with it; the mirrors follow.
    const prefix = [...this._path, key];
    for (const child of this._owner._children) child._purge(prefix);
  }

  /** A draft scope for bulk mutation; see Draft. */
  change(body: (d: Draft<E>) => void): void {
    body(new Draft(this));
  }

  /** The entry's current value — the model's copy. Transition code only;
   * template position throws. */
  get(key: Key): E | undefined {
    guardMirrorRead("get()");
    return this._mirror().get(key);
  }

  /** The model: what this guest wrote, in insertion order. */
  items(): [Key, E][] {
    guardMirrorRead("items()");
    return [...this._mirror().entries()];
  }

  keys(): Key[] {
    guardMirrorRead("keys()");
    return [...this._mirror().keys()];
  }

  get size(): number {
    guardMirrorRead("size");
    return this._mirror().size;
  }

  has(key: Key): boolean {
    guardMirrorRead("membership");
    return this._mirror().has(key);
  }
}

function pathKey(path: readonly Key[]): string {
  return JSON.stringify(path);
}

/** The configured spelling of the ordinary For loop, and the table one. */
export type RowsOptions = {
  grow?: number;
  align?: AlignValue | AlignName;
  a11yId?: Bindable | string;
  /** Every stamped row drags within this collection; the landing arrives
   * at `onDrop` on the For's own container, with the moved row's key in
   * the clip and the row it landed on as the anchor (docs/dnd-plan.md D8). */
  reorderable?: boolean;
  onDrop?: Handler;
};
/** The clip a drag hands over, in `copy`'s own shape, plus the
 * operations the source allows (docs/dnd-plan.md D1). INSIDE A FOR'S
 * BODY a representation may be the ROW'S OWN FIELD instead of a
 * constant, the way `label({ bind: row.title })` binds; every stamped
 * copy resolves it from its own record (docs/dnd-plan.md §4). */
export type DraggableOptions = {
  text?: string | FieldRef;
  html?: string | FieldRef;
  image?: Uint8Array | FieldRef;
  files?: readonly (PickedFile | number)[];
  custom?: Readonly<Record<string, Uint8Array | FieldRef>>;
  operations?: readonly string[];
};
export type ColumnsOptions = RowsOptions & { sort?: Sort; onSort?: Handler };

export class Collection<E, R> extends BoundCollection<E, R> {
  /** @internal */ readonly _id: number;
  /** @internal */ readonly _instances = new Map<string, Map<unknown, unknown>>();
  /** @internal */ readonly _children: Collection<unknown, unknown>[] = [];
  /** @internal */ readonly _derived: CollectionDerived<unknown, unknown>[] = [];
  /** @internal */ readonly _fresh = new Map<string, number>();
  /** @internal */ readonly _variants: Variant[];
  /** @internal */ _forHandle: number | null = null;

  /** @internal */
  constructor(id: number, types: RecordType[] | null) {
    super(null as unknown as Collection<E, R>, []);
    // The owner is this very object; the base class's field is set
    // through the writable slot so the two are one.
    (this as { _owner: Collection<E, R> })._owner = this;
    this._id = id;
    this._variants = types === null ? [new Variant(null)] : types.map((t) => new Variant(t));
  }

  /** The tracing tier: in template position, `for (const t of todos)`
   * traces to a For — the loop body runs once, authoring the blueprint.
   * (Transition code iterates the model: items().) */
  [Symbol.iterator](): Iterator<R> {
    if (!(_recording || _tplDepth > 0)) {
      throw new TypeError("kaya: `for (const t of coll)` is template tracing, record time only — handlers iterate the model with items()");
    }
    if (this._variants.length > 1) {
      throw new TypeError(
        "kaya: a sum collection's template is its case arms — use kaya.forEach(c, (cases) => ...) and one cases.case(Ctor, (el) => ...) per constructor",
      );
    }
    return new ForTrace(this as Collection<unknown, unknown>) as unknown as Iterator<R>;
  }

  /** The ordinary For loop with its options: `for (const item of
   * items.rows({grow: 1, align: "stretch"}))`. */
  rows(opts: RowsOptions = {}): Iterable<R> {
    const trace = this[Symbol.iterator]() as unknown as ForTrace;
    trace._grow = opts.grow ?? null;
    trace._align = opts.align ?? null;
    trace._a11yId = opts.a11yId ?? null;
    trace._reorderable = opts.reorderable ?? false;
    trace._onDrop = opts.onDrop ?? null;
    return { [Symbol.iterator]: () => trace as unknown as Iterator<R> };
  }

  /** The column header bar on this collection's For — the table spelling
   * of the same loop. The row template's body must hold a row of exactly
   * one cell per column; `onSort` takes the 0-based column index of a
   * header click, a nested template's copy keys first. Re-declare with
   * setColumns() after sorting. */
  columns(titles: readonly string[], opts: ColumnsOptions = {}): Iterable<R> {
    return new ColumnsTrace(this as Collection<unknown, unknown>, [...titles], opts) as unknown as Iterable<R>;
  }

  /** @internal Rebuild a model value from an undo delta's wire record. An
   * entry the mirror still holds is UPDATED IN PLACE. */
  _decode(variant: number, fields: wire.Decoded[], current: unknown): E {
    const spec = this._variants[variant]!;
    for (const value of fields) {
      if (value instanceof BlobHandle) {
        throw new Error(
          "kaya: this undo step restores a collection entry with a bytes field, and the core's undo payload cannot carry blob bytes yet (wire.rs undo_body encodes them as a batch-local handle with no table behind it). Keep bytes fields out of undoable groups until that lands.",
        );
      }
    }
    if (spec.ctor === null) return fields[0] as E;
    const target = (current instanceof spec.ctor ? current : Object.create(spec.ctor.prototype)) as Record<string, unknown>;
    spec.names.forEach((name, i) => {
      target[name] = spec.decoders[i]!(fields[i]!);
    });
    return target as E;
  }

  /** @internal The constructor a model value holds — the discriminant
   * every write witnesses. */
  _variantFor(value: unknown): [number, Variant] {
    const only = this._variants.length === 1 ? this._variants[0]! : null;
    if (only !== null) {
      if (only.ctor !== null && (typeof value !== "object" || value === null)) {
        throw new TypeError(`kaya: ${runtime.describe(value)} is not a ${only.ctor.name} record`);
      }
      return [0, only];
    }
    for (let i = 0; i < this._variants.length; i++) {
      const spec = this._variants[i]!;
      if (spec.ctor !== null && value instanceof spec.ctor) return [i, spec];
    }
    throw new TypeError(`kaya: ${runtime.describe(value)} is not a constructor of this collection's union — build entries with the record types it declares`);
  }

  /** The instance of this (template-declared) collection inside the copy
   * selected by `path` — one key per enclosing For. */
  at(...path: Key[]): BoundCollection<E, R> {
    return new BoundCollection(this, path);
  }

  /** @internal */
  _purge(prefix: Key[]): void {
    journalInstances(this as Collection<unknown, unknown>);
    const head = JSON.stringify(prefix).slice(0, -1);
    for (const path of [...this._instances.keys()]) {
      if (path === JSON.stringify(prefix) || path.startsWith(head + ",")) this._instances.delete(path);
    }
    for (const child of this._children) child._purge(prefix);
  }
}

// ------------------------------------------------------------- scopes

class Container {
  readonly handle: Widget;

  constructor(handle: Widget) {
    this.handle = handle;
  }

  run(body: (() => void) | undefined): Widget {
    _parents.push(this.handle.id);
    try {
      if (body !== undefined) body();
    } finally {
      _parents.pop();
    }
    const atLiveTop = _tplDepth === 0 && (_parents.length === 0 || _parents[_parents.length - 1] === null);
    if (atLiveTop && _parents.length === 0) _pendingRoot = this.handle;
    return this.handle;
  }
}

class Template {
  private readonly _opener: (id: number, target: number) => Uint8Array;
  private readonly _targetId: number;
  private readonly _isFor: boolean;
  private readonly _coll: Collection<unknown, unknown> | null;
  private _parent: number | null | undefined;
  handle!: Widget;

  constructor(opener: (id: number, target: number) => Uint8Array, targetId: number, isFor: boolean, coll: Collection<unknown, unknown> | null = null) {
    this._opener = opener;
    this._targetId = targetId;
    this._isFor = isFor;
    this._coll = coll;
  }

  enter(): unknown {
    this.handle = allocWidgetOrNode();
    // The container parents into the enclosing scope, but the record
    // must land after template_end: an add_child inside the blueprint
    // would cross zones.
    this._parent = _parents.length > 0 ? _parents[_parents.length - 1] : null;
    records().push(this._opener(this.handle.id, this._targetId));
    _tplDepth += 1;
    _parents.push(null); // template bodies root themselves
    if (this._isFor && this._coll !== null) {
      _forStack.push(_forStack.length);
      _forCollections.push(this._coll);
      const forIndex = _forStack[_forStack.length - 1]!;
      if (this._coll._variants.length > 1) return new Cases(forIndex, this._coll);
      return rowTracer(forIndex, this._coll, this._coll._variants[0]!);
    }
    return null;
  }

  exit(): void {
    if (this._isFor) {
      _forStack.pop();
      _forCollections.pop();
    }
    _parents.pop();
    _tplDepth -= 1;
    records().push(wire.tx_template_end());
    if (this._parent !== null && this._parent !== undefined) records().push(wire.tx_add_child(this._parent, this.handle.id));
  }
}

/** The for-of tracer: opens the For template and closes it when the loop
 * asks for a second element. THE BODY RUNS ONCE — stamping is the core's
 * replay. A break leaves the template open, caught at transaction exit. */
class ForTrace implements Iterator<unknown> {
  readonly _template: Template;
  _grow: number | null = null;
  _align: AlignValue | AlignName | null = null;
  _a11yId: Bindable | string | null = null;
  _reorderable = false;
  _onDrop: Handler | null = null;
  private _state = 0;

  constructor(coll: Collection<unknown, unknown>) {
    this._template = new Template(wire.tx_create_for, coll._id, true, coll);
  }

  next(): IteratorResult<unknown> {
    if (this._state === 0) {
      this._state = 1;
      const element = this._template.enter();
      _openTraces.push(this);
      return { value: element, done: false };
    }
    if (this._state === 1) {
      this._state = 2;
      // Traces close innermost-first; anything else means the loop
      // bodies interleaved template scopes.
      if (_openTraces.length === 0 || _openTraces[_openTraces.length - 1] !== this) {
        throw new Error("kaya: nested for-loops over collections must close innermost-first");
      }
      _openTraces.pop();
      this._template.exit();
      const handle = this._template.handle;
      if (this._grow !== null) records().push(wire.tx_set_grow(handle.id, Number(this._grow)));
      if (this._align !== null) records().push(wire.tx_set_align(handle.id, alignValue(this._align)));
      if (this._a11yId !== null) handle.a11yId(this._a11yId);
      if (this._reorderable) records().push(wire.tx_set_reorderable(handle.id, 1));
      if (this._onDrop !== null) handle.onDrop(this._onDrop);
    }
    return { value: undefined, done: true };
  }

  return(): IteratorResult<unknown> {
    // A break: the template stays open on the record, and the
    // transaction exit refuses it by name.
    return { value: undefined, done: true };
  }
}

/** columns()'s wrapper over the for-of tracer: when the template closes,
 * emit the header declaration (the core validates the row template
 * against the declared arity, so it must follow the bodies), register
 * the sort handler, and remember the For handle for setColumns(). */
class ColumnsTrace implements Iterable<unknown> {
  private readonly _coll: Collection<unknown, unknown>;
  private readonly _titles: string[];
  private readonly _opts: ColumnsOptions;

  constructor(coll: Collection<unknown, unknown>, titles: string[], opts: ColumnsOptions) {
    this._coll = coll;
    this._titles = titles;
    this._opts = opts;
  }

  [Symbol.iterator](): Iterator<unknown> {
    const trace = this._coll[Symbol.iterator]() as unknown as ForTrace;
    const finish = (): void => {
      const handle = trace._template.handle;
      this._coll._forHandle = handle.id;
      const sort = this._opts.sort ?? Sort.NONE;
      records().push(wire.tx_set_column_headers(handle.id, sort.sorted, sort.direction, this._titles.length, 0, this._titles));
      if (this._opts.onSort !== undefined) app()._register(handle, wire.OCC_SORT_REQUESTED, this._opts.onSort);
      if (this._opts.grow !== undefined) records().push(wire.tx_set_grow(handle.id, Number(this._opts.grow)));
      if (this._opts.a11yId !== undefined) handle.a11yId(this._opts.a11yId);
    };
    return {
      next: () => {
        const result = trace.next();
        if (result.done) finish();
        return result;
      },
      return: () => trace.return(),
    };
  }
}

function allocWidgetOrNode(): Widget {
  // A declaration never rides the implicit transaction: with no scope and
  // no container it would be an orphan the core refuses at apply.
  if (_tx === null || (_implicit && !_recording && _parents.length === 0)) {
    throw new Error(
      "kaya: a widget is declared inside a scene scope — app.window(opts, () => ...), " +
        "pushEntry or addSection — or inside a container's body; here it would have no parent",
    );
  }
  // One counter for both (DESIGN.md, Binding conventions).
  return new Widget(app()._next("widget"), _tplDepth > 0);
}

function widget(kind: number): Widget {
  const handle = allocWidgetOrNode();
  records().push(wire.tx_create_widget(handle.id, kind));
  autoParent(handle.id);
  return handle;
}

function app(): App {
  if (_app === null) throw new Error("kaya: no App — create one first: const app = new kaya.App()");
  return _app;
}

// -------------------------------------------------------------- windows

/** Create an auxiliary window (capability-gated: a phone host rejects it
 * at the root). Materializes hidden; mounting presents. The declarative
 * spelling is `app.createWindow(id, opts, body)`. */
export function createWindow(windowId: number): void {
  records().push(wire.tx_create_window(windowId));
}

/** Close and forget an auxiliary window — also the veto grammar's
 * confirmation after onCloseRequested. */
export function destroyWindow(windowId: number): void {
  records().push(wire.tx_destroy_window(windowId));
}

/** Pop the window's top navigation entry and forget its tree — also the
 * back-veto grammar's confirmation after onBack. */
export function popEntry(window = 0): void {
  records().push(wire.tx_pop_entry(window));
}

/** Select a section programmatically: configuration, never echoes
 * onSelected (the echo doctrine). */
export function selectSection(sectionId: number, window = 0): void {
  records().push(wire.tx_select_section(window, sectionId));
}

export const SECTIONS_AUTO = wire.SECTIONS_PRESENTATION_AUTO;
export const SECTIONS_BAR = wire.SECTIONS_PRESENTATION_BAR;
export const SECTIONS_SIDEBAR = wire.SECTIONS_PRESENTATION_SIDEBAR;

/** The alert_choice cancel sentinel: `if (choice === kaya.CANCEL)`. */
export const CANCEL = wire.ALERT_CHOICE_CANCEL;

export type AlertOptions = {
  title?: string;
  message?: string;
  actions?: readonly string[];
  cancel: string;
  onResult?: (choice: number) => void;
  window?: number;
};

/** Request a modal alert: up to two action labels (the platform floor)
 * plus the REQUIRED cancel label. onResult(choice) fires exactly once —
 * 0 or 1 for actions, kaya.CANCEL for every native dismissal — and
 * WITHOUT it the call answers a promise of the choice instead, whose
 * continuation is its own implicit transaction. One alert may be live
 * per process. */
export function showAlert(opts: AlertOptions & { onResult: (choice: number) => void }): number;
export function showAlert(opts: AlertOptions): Promise<number>;
export function showAlert(opts: AlertOptions): number | Promise<number> {
  const actions = [...(opts.actions ?? [])];
  if (actions.length > 2) throw new RangeError("an alert carries at most 2 actions (the platform floor)");
  if (!opts.cancel) throw new Error("the cancel slot always exists and needs a name — pass cancel:");
  const a = app();
  const alertId = a._next("alert");
  const show = (): void => {
    records().push(
      wire.tx_show_alert(opts.window ?? 0, alertId, actions.length, opts.title ?? "", opts.message ?? "", actions[0] ?? "", actions[1] ?? "", opts.cancel),
    );
  };
  if (opts.onResult !== undefined) {
    a._alertHandlers.set(alertId, opts.onResult);
    show();
    return alertId;
  }
  return new Promise<number>((resolve) => {
    a._alertHandlers.set(alertId, resolve);
    show();
  });
}

// ---------------------------------------------------------------- files

/** One picked file: a handle to redeem, a display name, and `localPath`
 * — a RE-OPENABLE NAME, empty unless re-opening it actually works (the
 * three desktops, neither phone). */
export class PickedFile {
  readonly handle: number;
  readonly name: string;
  readonly localPath: string;

  /** @internal */
  constructor(handle: number, name: string, localPath: string) {
    this.handle = handle;
    this.name = name;
    this.localPath = localPath;
  }

  /** The whole file's bytes, read by the addon over the platform handle —
   * the one spelling that works on all three desktops (Windows hands back
   * a HANDLE that node's own C runtime cannot adopt; docs/js-plan.md §6).
   * BLOCKS, possibly for a long time. */
  read(): Uint8Array {
    return runtime.readPicked(this.handle);
  }

  /** Replace the file's content — what a save dialog's answer opens as
   * (docs/save-plan.md D1). A string is written as UTF-8. BLOCKS. */
  write(bytes: Uint8Array | string): void {
    runtime.writePicked(this.handle, typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes);
  }

  /** The streaming route: `{fd, seekable}` — a descriptor for node:fs, and
   * whether it supports random access. Unix only (see read/write); close
   * it with fs.closeSync. BLOCKS. */
  open(mode: number = wire.FILE_MODE_READ): { fd: number; seekable: boolean } {
    return runtime.openPicked(this.handle, mode);
  }
}

export type Filter = readonly [label: string, extensions: string | readonly string[]];
export type PickOptions = { filters?: readonly Filter[]; onResult?: (files: PickedFile[]) => void; window?: number };

/** Ask the platform for files. THE PICK, NOT THE OPEN. Cancel is the
 * empty list; one dialog may be live per process. */
export function pickFiles(opts: PickOptions & { onResult: (files: PickedFile[]) => void }): number;
export function pickFiles(opts?: PickOptions): Promise<PickedFile[]>;
export function pickFiles(opts: PickOptions = {}): number | Promise<PickedFile[]> {
  return pick(true, opts);
}

/** The single-file spelling: the handler (or the promise) receives zero
 * or one file. */
export function pickFile(opts: PickOptions & { onResult: (files: PickedFile[]) => void }): number;
export function pickFile(opts?: PickOptions): Promise<PickedFile[]>;
export function pickFile(opts: PickOptions = {}): number | Promise<PickedFile[]> {
  return pick(false, opts);
}

export type SaveOptions = { filters?: readonly Filter[]; onResult?: (file: PickedFile | null) => void; window?: number };

/** Ask the platform WHERE TO SAVE. `suggestedName` is the name the
 * dialog opens with; READ THE NAME YOU GOT. Cancel is null. What you get
 * back opens empty (docs/save-plan.md D1). */
export function saveFile(suggestedName: string, opts: SaveOptions & { onResult: (file: PickedFile | null) => void }): number;
export function saveFile(suggestedName: string, opts?: SaveOptions): Promise<PickedFile | null>;
export function saveFile(suggestedName: string, opts: SaveOptions = {}): number | Promise<PickedFile | null> {
  const a = app();
  const dialogId = a._next("file_dialog");
  const onResult = opts.onResult;
  const show = (): void => {
    records().push(wire.tx_show_save_dialog(opts.window ?? 0, dialogId, String(suggestedName), filters(opts.filters ?? [])));
  };
  if (onResult === undefined) {
    return new Promise<PickedFile | null>((resolve) => {
      a._fileDialogHandlers.set(dialogId, (files) => resolve(files[0] ?? null));
      show();
    });
  }
  a._fileDialogHandlers.set(dialogId, (files) => onResult(files[0] ?? null));
  show();
  return dialogId;
}

/** The advisory filter encoding BOTH dialogs share: alternating label
 * and space-separated extensions. */
function filters(list: readonly Filter[]): string[] {
  const flat: string[] = [];
  for (const [label, exts] of list) {
    flat.push(String(label));
    flat.push(typeof exts === "string" ? exts : exts.join(" "));
  }
  return flat;
}

function pick(multiple: boolean, opts: PickOptions): number | Promise<PickedFile[]> {
  const a = app();
  const dialogId = a._next("file_dialog");
  const show = (): void => {
    records().push(wire.tx_show_file_dialog(opts.window ?? 0, dialogId, multiple ? 1 : 0, filters(opts.filters ?? [])));
  };
  if (opts.onResult !== undefined) {
    a._fileDialogHandlers.set(dialogId, opts.onResult);
    show();
    return dialogId;
  }
  return new Promise<PickedFile[]>((resolve) => {
    a._fileDialogHandlers.set(dialogId, resolve);
    show();
  });
}

// ------------------------------------------------------------ clipboard

/** One representation, arriving — the sum `copy` is the record of:
 * `if (clip instanceof kaya.Representation.Text) ...`. */
class RepText {
  readonly text: string;
  constructor(text: string) {
    this.text = text;
  }
}
class RepHtml {
  readonly html: string;
  constructor(html: string) {
    this.html = html;
  }
}
/** Encoded image bytes. What comes back may be a re-encode. */
class RepImage {
  readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }
}
/** PickedFile, plural INSIDE one representation. */
class RepFiles {
  readonly files: PickedFile[];
  constructor(files: PickedFile[]) {
    this.files = files;
  }
}
/** An app-defined format, round-tripped verbatim. */
class RepCustom {
  readonly id: string;
  readonly bytes: Uint8Array;
  constructor(id: string, bytes: Uint8Array) {
    this.id = id;
    this.bytes = bytes;
  }
}
export const Representation = Object.freeze({ Text: RepText, Html: RepHtml, Image: RepImage, Files: RepFiles, Custom: RepCustom });
export type Clip = RepText | RepHtml | RepImage | RepFiles | RepCustom;

/** Turn the decoder's {clip, values} into the sum, or null — EMPTY IS THE
 * UNIVERSAL NO, and the platforms do not say which. */
function representation(payload: wire.ClipPayload): Clip | null {
  const { clip, values } = payload;
  if (clip === wire.CLIP_TEXT) return new Representation.Text(values[0] as string);
  if (clip === wire.CLIP_HTML) return new Representation.Html(values[0] as string);
  if (clip === wire.CLIP_IMAGE) return new Representation.Image(values[0] as Uint8Array);
  if (clip === wire.CLIP_CUSTOM) return new Representation.Custom(values[0] as string, values[1] as Uint8Array);
  if (clip === wire.CLIP_FILES) {
    const files: PickedFile[] = [];
    for (let i = 0; i + 2 < values.length; i += 3) {
      files.push(new PickedFile(values[i] as number, values[i + 1] as string, values[i + 2] as string));
    }
    return new Representation.Files(files);
  }
  return null;
}

/** What a drop delivered (docs/dnd-plan.md D1): `clip` is the sum a paste
 * already delivers, `operation` is OP_COPY, OP_MOVE or null, `point` is
 * (x, y) in the destination's own coordinates, and `anchor`/`before` are
 * the reorder's landing row and side (D8). */
export type Dropped = {
  point: [number, number];
  operation: string | null;
  anchor: wire.Decoded[];
  before: boolean;
  clip: Clip | null;
};

/** The drag_op word, or null for a cancelled or refused drag. */
function operation(mask: number): string | null {
  if (mask === wire.DRAG_OP_COPY) return OP_COPY;
  if (mask === wire.DRAG_OP_MOVE) return OP_MOVE;
  return null;
}

/** The drag_op mask a guest's words name; empty withdraws. */
function operationMask(operations: readonly string[]): number {
  let mask = 0;
  for (const op of operations) {
    if (op === OP_COPY) mask |= wire.DRAG_OP_COPY;
    else if (op === OP_MOVE) mask |= wire.DRAG_OP_MOVE;
    else {
      throw new Error(
        `kaya: ${JSON.stringify(op)} is not a drag operation — copy and move are the vocabulary, and link and ask are refused (docs/dnd-plan.md D3)`,
      );
    }
  }
  return mask;
}

/** A keyed declaration names ONE STAMPED COPY, so it takes a template
 * node — a live widget is one thing on screen and has no keys
 * (docs/dnd-plan.md §4). */
function templateZoneOnly(handle: Handle, what: string): void {
  if (!(handle instanceof Widget && handle.isNode)) {
    throw new Error(
      `kaya: ${what} names ONE STAMPED COPY — it takes a template node and that copy's keys, and a live widget is one thing on screen (docs/dnd-plan.md §4)`,
    );
  }
}

/** One drag representation's source (docs/dnd-plan.md §4): the row's own
 * field, packed as `level << 32 | field` for the slot it fills, or null
 * for a constant the caller writes itself. `draggable({ text: row.title })`
 * binds the way `label({ bind: row.title })` does, and every stamped copy
 * resolves it from its own record. */
function dragSlot(handle: Handle, keys: Key[], what: string, value: unknown): I64 | null {
  if (value instanceof Signal) {
    throw new TypeError(
      `kaya: a drag payload's ${what} cannot be a signal — a payload is app-updated state, re-declared when it changes (docs/dnd-plan.md D1), and inside a For's body it binds a constant or the row's own field (§4)`,
    );
  }
  let level: number;
  let field: number;
  if (value instanceof FieldRef) {
    level = value._level();
    field = value._index;
  } else if (value instanceof Element) {
    level = value._level();
    field = 0;
  } else if (value instanceof CaseElement) {
    throw new TypeError(
      `kaya: a drag payload's ${what} takes one of the row's fields (row.title), not a case element — inside a case arm project the field (docs/dnd-plan.md §4)`,
    );
  } else {
    return null;
  }
  if (keys.length > 0) {
    throw new Error(
      `kaya: draggableAt names ONE stamped copy, whose payload is already resolved — bind ${what} to the row's field in the For's body instead (docs/dnd-plan.md §4)`,
    );
  }
  if (!(handle instanceof Widget && handle.isNode)) {
    throw new Error(
      `kaya: a live widget's drag payload cannot bind ${what} to a row's field — a live widget is one thing on screen and has no row (docs/dnd-plan.md §4)`,
    );
  }
  return new I64(level * 2 ** 32 + field);
}

function dropped(payload: wire.DroppedPayload): Dropped {
  return {
    point: payload.point,
    operation: operation(payload.operation),
    anchor: payload.anchor,
    before: payload.before,
    clip: representation(payload.clip),
  };
}

/** What one undo step put back: the CORE-AUTHORITATIVE restored state
 * (docs/undo-plan.md D5). The collection mirrors are already reconciled
 * before your handler runs; signals and text are handed to the app. */
export type UndoDelta = {
  signals: [id: number, value: wire.Decoded][];
  texts: [id: number, path: wire.Decoded[], text: string][];
  entries: [coll: number, path: wire.Decoded[], key: wire.Decoded, state: [variant: number, fields: wire.Decoded[]] | null][];
  orders: [coll: number, path: wire.Decoded[], keys: wire.Decoded[]][];
};

/** Join an accept list: the closed kinds by name plus any custom ids,
 * space separated — ids carry NO SPACES. */
function acceptList(kinds: readonly string[]): string {
  const out: string[] = [];
  for (const kind of kinds) {
    const k = String(kind);
    if (!k || k.includes(" ")) {
      throw new Error(
        `kaya: ${JSON.stringify(k)} is not an accept-list entry — the closed kinds are 'text', 'html', 'image' and 'files', and a custom format id reaches the platform's own registry verbatim, so it carries no spaces`,
      );
    }
    out.push(k);
  }
  return out.join(" ");
}

export type CopyOptions = {
  text?: string;
  html?: string;
  image?: Uint8Array;
  files?: readonly (PickedFile | number)[];
  custom?: Readonly<Record<string, Uint8Array>>;
};

/** Put ONE clip on the system clipboard, offered in as many
 * representations as you fill in. A record and not a list. */
export function copy(opts: CopyOptions): void {
  const reps: wire.WireValue[] = [];
  let present = 0;
  const custom = Object.entries(opts.custom ?? {});
  const files = [...(opts.files ?? [])];
  for (const [ident, data] of custom) {
    acceptList([ident]);
    reps.push(ident, new BlobHandle(runtime.registerBlob(data)));
  }
  for (const picked of files) reps.push(new I64(typeof picked === "number" ? picked : picked.handle));
  if (opts.image !== undefined) {
    present |= wire.CLIP_IMAGE;
    reps.push(new BlobHandle(runtime.registerBlob(opts.image)));
  }
  if (opts.html !== undefined) {
    present |= wire.CLIP_HTML;
    reps.push(String(opts.html));
  }
  if (opts.text !== undefined) {
    present |= wire.CLIP_TEXT;
    reps.push(String(opts.text));
  }
  records().push(wire.tx_copy(present, files.length, custom.length, reps));
}

/** Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE.
 * onResult(clip) fires exactly once with the sum or null. */
export function readClipboard(accepting: readonly string[], opts: { onResult: (clip: Clip | null) => void }): number;
export function readClipboard(accepting: readonly string[]): Promise<Clip | null>;
export function readClipboard(accepting: readonly string[], opts: { onResult?: (clip: Clip | null) => void } = {}): number | Promise<Clip | null> {
  const a = app();
  const request = a._next("clipboard");
  const show = (): void => {
    records().push(wire.tx_read_clipboard(request, acceptList(accepting)));
  };
  if (opts.onResult !== undefined) {
    a._clipboardHandlers.set(request, opts.onResult);
    show();
    return request;
  }
  return new Promise<Clip | null>((resolve) => {
    a._clipboardHandlers.set(request, resolve);
    show();
  });
}

// ---------------------------------------------------------------- menus

/** A live menu item in its OWN id space. One command identity: exactly
 * one parent or anchor, forever (append-only). */
export class MenuItem {
  readonly id: number;

  /** @internal */
  constructor(id: number) {
    this.id = id;
  }

  label(value: string | Signal<string>): void {
    if (value instanceof Signal) records().push(wire.tx_bind_menu_label(this.id, value.id));
    else records().push(wire.tx_set_menu_label(this.id, textValue("menu label", value)));
  }

  enabled(value: boolean | Signal<boolean>): void {
    if (value instanceof Signal) records().push(wire.tx_bind_menu_enabled(this.id, value.id));
    else records().push(wire.tx_set_menu_enabled(this.id, Boolean(value)));
  }

  /** A toggle's state (toggle items only): QUIET, no menu_toggled echo. */
  checked(value: boolean | Signal<boolean>): void {
    if (value instanceof Signal) records().push(wire.tx_bind_menu_checked(this.id, value.id));
    else records().push(wire.tx_set_menu_checked(this.id, Boolean(value)));
  }

  /** A radio group's selected option index (radio groups only). QUIET. */
  value(v: number | Signal<number>): void {
    if (v instanceof Signal) records().push(wire.tx_bind_menu_value(this.id, v.id));
    else records().push(wire.tx_set_menu_value(this.id, Number(v)));
  }

  icon(data: Uint8Array): void {
    records().push(wire.tx_set_menu_icon(this.id, runtime.registerBlob(data)));
  }

  symbol(symbol: SymbolValue | SymbolName): void {
    records().push(wire.tx_set_menu_symbol(this.id, symbolValue(symbol)));
  }

  primary(on: boolean): void {
    records().push(wire.tx_set_menu_primary(this.id, Boolean(on)));
  }

  role(name: string): void {
    records().push(wire.tx_set_menu_role(this.id, name));
  }

  shortcut(spelling: string): void {
    records().push(wire.tx_set_menu_shortcut(this.id, spelling));
  }

  /** Reopen this RETAINED grouping node — the append-at-any-time
   * discipline. */
  append(body: () => void): void {
    new MenuScope(["item", this.id], true).run(body);
  }
}

/** A context catalog built free of any anchor, for a template node. */
export class ContextCatalog {
  /** @internal */ readonly _roots: number[] = [];
  /** @internal */ _attached = false;
  /** @internal */ _owner: Collection<unknown, unknown> | null = null;
}

type Seat = ["item", number] | ["widget", number] | ["free", ContextCatalog];

/** A scope whose creators seat under one menu anchor. shortcutOk carries
 * the one anchor-dependent rule to record time. onExit runs after the
 * body's children recorded — THE RADIO VALUE'S SEAT. */
class MenuScope {
  readonly _seat: Seat;
  readonly _shortcutOk: boolean;
  private readonly _onExit: (() => void) | null;

  constructor(seat: Seat, shortcutOk: boolean, onExit: (() => void) | null = null) {
    this._seat = seat;
    this._shortcutOk = shortcutOk;
    this._onExit = onExit;
  }

  run(body: () => void): void {
    _menuScopes.push(this);
    try {
      body();
    } finally {
      _menuScopes.pop();
    }
    if (this._onExit !== null) this._onExit();
  }
}

/** Create one menu item in its own id space; menu records are live-zone
 * only. */
function menuCreate(kind: number, label?: string | Signal<string>): MenuItem {
  if (_tplDepth > 0) {
    throw new Error(
      "kaya: menu items are live — build the context catalog in the live zone (kaya.contextCatalog) and attach it inside the template with node.contextMenu(catalog)",
    );
  }
  const item = new MenuItem(app()._next("menu_item"));
  records().push(wire.tx_menu_item_create(item.id, kind));
  if (label !== undefined) item.label(label);
  return item;
}

/** Seat a just-created item under the open scope's anchor and return the
 * scope (for the shortcut rule). */
function menuSeat(item: MenuItem): MenuScope {
  const scope = _menuScopes[_menuScopes.length - 1];
  if (scope === undefined) {
    throw new Error(
      "kaya: menu items declare inside a menu scope — app.menu()/app.radioGroup() for the window catalog, widget.contextMenu() or kaya.contextCatalog() for a context anchor",
    );
  }
  const [kind, target] = scope._seat;
  if (kind === "item") records().push(wire.tx_menu_item_append(target, item.id));
  else if (kind === "widget") records().push(wire.tx_context_attach(target, item.id));
  else target._roots.push(item.id);
  return scope;
}

export const ACCEPT_TEXT = "text";
export const ACCEPT_HTML = "html";
export const ACCEPT_IMAGE = "image";
export const ACCEPT_FILES = "files";

/** The drag operation vocabulary (docs/dnd-plan.md D3), named for the
 * accept list's reason: a bare string that is neither of these is a
 * silent no-op everywhere, so `operationMask` refuses it by name. */
export const OP_COPY = "copy";
export const OP_MOVE = "move";

export const ROLE_SETTINGS = "settings";
export const ROLE_CUT = "cut";
export const ROLE_COPY = "copy";
export const ROLE_PASTE = "paste";
export const ROLE_UNDO = "undo";
export const ROLE_REDO = "redo";

function menuRequireCatalog(scope: MenuScope): void {
  if (!scope._shortcutOk) {
    throw new Error("kaya: a context item takes no shortcut — a shortcut needs a window catalog as its native dispatch home");
  }
}

export type ItemOptions = {
  shortcut?: string;
  enabled?: boolean | Signal<boolean>;
  icon?: Uint8Array;
  symbol?: SymbolValue | SymbolName;
  primary?: boolean;
  role?: string;
  onActivate?: Handler;
};

/** An action — a leaf command firing exactly one menu_activated
 * occurrence. On a template-node catalog the handler receives the
 * stamped copy's keys. */
export function item(label: string | Signal<string>, opts: ItemOptions = {}): MenuItem {
  const it = menuCreate(wire.MENU_KIND_ACTION, label);
  const scope = menuSeat(it);
  if (opts.shortcut !== undefined) {
    menuRequireCatalog(scope);
    it.shortcut(opts.shortcut);
  }
  if (opts.enabled !== undefined) it.enabled(opts.enabled);
  if (opts.icon !== undefined) it.icon(opts.icon);
  if (opts.symbol !== undefined) it.symbol(opts.symbol);
  if (opts.primary !== undefined) it.primary(opts.primary);
  if (opts.role !== undefined) {
    if (!scope._shortcutOk) throw new Error("kaya: a context item takes no role — a role names a standard command in the window catalog");
    it.role(opts.role);
  }
  if (opts.onActivate !== undefined) app()._menuHandlers.set(menuKey(wire.OCC_MENU_ACTIVATED, it.id), opts.onActivate);
  return it;
}

export type ToggleOptions = {
  checked?: boolean | Signal<boolean>;
  enabled?: boolean | Signal<boolean>;
  icon?: Uint8Array;
  symbol?: SymbolValue | SymbolName;
  shortcut?: string;
  onToggle?: Handler;
};

/** A toggle — a stateful leaf reusing the Checkbox contract. */
export function toggle(label: string | Signal<string>, opts: ToggleOptions = {}): MenuItem {
  const it = menuCreate(wire.MENU_KIND_TOGGLE, label);
  const scope = menuSeat(it);
  if (opts.shortcut !== undefined) {
    menuRequireCatalog(scope);
    it.shortcut(opts.shortcut);
  }
  if (opts.checked !== undefined) it.checked(opts.checked);
  if (opts.enabled !== undefined) it.enabled(opts.enabled);
  if (opts.icon !== undefined) it.icon(opts.icon);
  if (opts.symbol !== undefined) it.symbol(opts.symbol);
  if (opts.onToggle !== undefined) app()._menuHandlers.set(menuKey(wire.OCC_MENU_TOGGLED, it.id), opts.onToggle);
  return it;
}

export type OptionOptions = { enabled?: boolean | Signal<boolean>; icon?: Uint8Array; symbol?: SymbolValue | SymbolName; shortcut?: string };

/** One labeled radio option, appended in declaration order — the order
 * IS the index vocabulary the group's value selects over. */
export function option(label: string | Signal<string>, opts: OptionOptions = {}): MenuItem {
  const it = menuCreate(wire.MENU_KIND_RADIO_OPTION, label);
  const scope = menuSeat(it);
  if (opts.shortcut !== undefined) {
    menuRequireCatalog(scope);
    it.shortcut(opts.shortcut);
  }
  if (opts.enabled !== undefined) it.enabled(opts.enabled);
  if (opts.icon !== undefined) it.icon(opts.icon);
  if (opts.symbol !== undefined) it.symbol(opts.symbol);
  return it;
}

/** Native grouping chrome: no label, no props, no handle kept. */
export function separator(): void {
  menuSeat(menuCreate(wire.MENU_KIND_SEPARATOR));
}

export type MenuOptions = { enabled?: boolean | Signal<boolean>; icon?: Uint8Array; symbol?: SymbolValue | SymbolName };

/** A NESTED menu — grouping, never navigation — inside an open menu
 * scope. Bar-level menus are `app.menu`. */
export function menu(label: string | Signal<string>, optsOrBody: MenuOptions | (() => void), body?: () => void): MenuItem {
  const [opts, run] = optsAndBody(optsOrBody, body);
  const it = menuCreate(wire.MENU_KIND_MENU, label);
  const scope = menuSeat(it);
  if (opts.enabled !== undefined) it.enabled(opts.enabled);
  if (opts.icon !== undefined) it.icon(opts.icon);
  if (opts.symbol !== undefined) it.symbol(opts.symbol);
  new MenuScope(["item", it.id], scope._shortcutOk).run(run);
  return it;
}

export type RadioGroupOptions = MenuOptions & { value?: number | Signal<number>; onSelect?: Handler };

/** A NESTED radio group, declaring only kaya.option children. `value` is
 * the selected 0-based index; onSelect receives each USER pick. */
export function radioGroup(label: string | Signal<string>, optsOrBody: RadioGroupOptions | (() => void), body?: () => void): MenuItem {
  const [opts, run] = optsAndBody(optsOrBody, body);
  const it = menuCreate(wire.MENU_KIND_RADIO_GROUP, label);
  const scope = menuSeat(it);
  if (opts.enabled !== undefined) it.enabled(opts.enabled);
  if (opts.icon !== undefined) it.icon(opts.icon);
  if (opts.symbol !== undefined) it.symbol(opts.symbol);
  if (opts.onSelect !== undefined) app()._menuHandlers.set(menuKey(wire.OCC_MENU_VALUE_CHANGED, it.id), opts.onSelect);
  // value lands at scope exit, AFTER the option children: the index
  // addresses options, and the root judges its domain at the record.
  const value = opts.value;
  new MenuScope(["item", it.id], scope._shortcutOk, value !== undefined ? () => it.value(value) : null).run(run);
  return it;
}

/** Build a context catalog UNANCHORED — free root items for a
 * template-node anchor, built in the LIVE zone. */
export function contextCatalog(body: () => void): ContextCatalog {
  const catalog = new ContextCatalog();
  new MenuScope(["free", catalog], false).run(body);
  return catalog;
}

function optsAndBody<O extends object>(optsOrBody: O | (() => void) | undefined, body: (() => void) | undefined): [O, () => void] {
  if (typeof optsOrBody === "function") return [{} as O, optsOrBody];
  if (body === undefined) throw new TypeError("kaya: this construct takes its body last: name(opts, () => {...})");
  return [optsOrBody ?? ({} as O), body];
}

function menuKey(kind: number, id: number): string {
  return `${kind}:${id}`;
}

/** Request the primary surface's content size (DIP). ADVISORY. */
export function windowSize(width: number, height: number): void {
  records().push(wire.tx_set_window_width(0, Number(width)));
  records().push(wire.tx_set_window_height(0, Number(height)));
}

// ---------------------------------------------------------------- brand

function accent(what: string, value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new TypeError(
      `kaya: brand accent ${what} takes one packed sRGB int (0x3584E4), not ${runtime.describe(value)} — brand is identity, set once before the first mount, so it is never a signal`,
    );
  }
  if (value < 0 || value > 0xffffffff) {
    throw new RangeError(`kaya: brand accent ${what} is 0x${value.toString(16)}, which does not fit the wire's u32 — the accent is one packed sRGB hex (0x3584E4)`);
  }
  return value;
}

/** REQUEST the app's brand accent (docs/styling-plan.md D1/D2): one hex
 * is the whole call; `light`/`dark` for a per-appearance variant. Set
 * once, before the first mount. */
export function brandAccent(seed: number, opts: { light?: number; dark?: number } = {}): void {
  const mask = (opts.light !== undefined ? 1 : 0) | (opts.dark !== undefined ? 2 : 0);
  records().push(
    wire.tx_set_brand_accent(accent("seed", seed), mask, opts.light !== undefined ? accent("light", opts.light) : 0, opts.dark !== undefined ? accent("dark", opts.dark) : 0),
  );
}

/** WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
 * "platform"). An app names these, it never asks which one it is. */
export const Platform = Object.freeze({
  MAC: wire.PLATFORM_MAC,
  IOS: wire.PLATFORM_IOS,
  LINUX: wire.PLATFORM_LINUX,
  WINDOWS: wire.PLATFORM_WINDOWS,
  ANDROID: wire.PLATFORM_ANDROID,
});
export type PlatformValue = (typeof Platform)[keyof typeof Platform];
export type PlatformName = "mac" | "ios" | "linux" | "windows" | "android";

const PLATFORM_NAMES: Record<string, number> = Object.fromEntries(Object.entries(Platform).map(([name, value]) => [name.toLowerCase(), value]));
const PLATFORM_NAME_OF: Record<number, string> = Object.fromEntries(Object.entries(PLATFORM_NAMES).map(([name, value]) => [value, name]));

function platformValue(platform: unknown): number {
  if (typeof platform === "string") {
    const value = PLATFORM_NAMES[platform];
    if (value === undefined) throw new Error(`kaya: brandTypeface: ${JSON.stringify(platform)} is not a platform — the vocabulary is ${JSON.stringify(Object.keys(PLATFORM_NAMES).sort())}`);
    return value;
  }
  if (typeof platform !== "number" || !Object.values(PLATFORM_NAMES).includes(platform)) {
    throw new TypeError(
      `kaya: brandTypeface: a per-platform key is kaya.Platform.LINUX or its name, not ${runtime.describe(platform)} — an app names the platforms it has a family for; it never asks which one it is`,
    );
  }
  return platform;
}

/** A window's named size class (spec enum "size_class"): what
 * `row({stackWhen})` speaks in place of an author-invented width. */
export class SizeClass {
  /** @internal */ readonly _tag: number;
  private readonly _name: string;

  /** @internal */
  constructor(tag: number, name: string) {
    this._tag = tag;
    this._name = name;
  }

  toString(): string {
    return `kaya.${this._name}`;
  }
}

/** The one size class an app can name today (`stackWhen: kaya.COMPACT`). */
export const COMPACT: SizeClass = new SizeClass(wire.SIZE_CLASS_COMPACT, "COMPACT");

// --------------------------------------------------------------- assets

/** One open asset: the bytes of a file the app's own BUILD shipped, held
 * by the core (docs/assets-plan.md). Two redemptions: hand it to kaya
 * (`font`, `icon`, `kaya.image(asset)`) or read it (`bytes()`). */
export class Asset {
  private _handle: number;
  private readonly _name: string;

  /** @internal */
  constructor(handle: number, name: string) {
    this._handle = handle;
    this._name = name;
  }

  /** The name this asset was asked for — never a path. */
  get name(): string {
    return this._name;
  }

  /** The asset's bytes, copied out of core memory. Throws if closed. */
  bytes(): Uint8Array {
    this._alive("bytes()");
    return runtime.assetBytes(this._handle);
  }

  /** @internal THE BLOB REDEMPTION: no copy, nothing through JS. */
  _blob(): number {
    this._alive("a blob redemption");
    return runtime.assetBlob(this._handle);
  }

  /** Release the core's handle. Idempotent. */
  close(): void {
    const handle = this._handle;
    this._handle = 0;
    if (handle) runtime.assetRelease(handle);
  }

  private _alive(what: string): void {
    if (!this._handle) {
      throw new Error(
        `kaya: ${what} on a closed asset (${JSON.stringify(this._name)}) — the handle was released, and the bytes it borrowed are the core's. Read before close(), or keep the bytes rather than the asset.`,
      );
    }
  }

  get length(): number {
    this._alive("length");
    return runtime.assetLen(this._handle);
  }

  [Symbol.dispose](): void {
    this.close();
  }

  toString(): string {
    return `Asset(name=${JSON.stringify(this._name)}, ${this._handle ? `${this.length} bytes` : "closed"})`;
  }
}

/** Open an asset — a file the app's own BUILD shipped beside it, named by
 * a relative path under the asset root. A MISS THROWS, WITH THE CORE'S
 * SENTENCE AND NOTHING ADDED. Each call reads. */
export function asset(name: string): Asset {
  if (typeof name !== "string") {
    throw new TypeError(
      `kaya: asset() takes a name as a string ('fonts/sora-wght.ttf'), not ${runtime.describe(name)} — a relative path under the asset root, spelled with '/' on every platform`,
    );
  }
  const handle = runtime.assetOpen(name);
  if (handle) return new Asset(handle, name);
  const sentence = runtime.assetMissSentence(name);
  throw new Error(
    sentence ||
      `kaya: asset(${JSON.stringify(name)}) did not open, and the core's own why-not answers that it resolves — those two facts were measured a moment apart, and this binding has nothing further to report`,
  );
}

/** Why `asset(name)` would fail — the sentence it would throw, handed
 * over without throwing. `""` means the name resolves. */
export function assetMissSentence(name: string): string {
  if (typeof name !== "string") {
    throw new TypeError(
      `kaya: assetMissSentence() takes a name as a string ('fonts/sora-wght.ttf'), not ${runtime.describe(name)} — a relative path under the asset root, spelled with '/' on every platform`,
    );
  }
  return runtime.assetMissSentence(name);
}

/** The one place a blob-taking consumer turns its argument into a
 * handle: an Asset redeems, bytes register. */
function blobOf(source: Asset | Uint8Array): number {
  return source instanceof Asset ? source._blob() : runtime.registerBlob(source);
}

function typefaceFamily(what: string, family: unknown): string {
  if (typeof family !== "string") {
    throw new TypeError(`kaya: brandTypeface ${what} takes a family NAME as a string ('Georgia'), not ${runtime.describe(family)} — a font FILE's bytes ride the font slot, which is a different thing`);
  }
  return family;
}

export type TypefaceOptions = { platforms?: Readonly<Record<string, string>> | ReadonlyMap<PlatformValue | PlatformName, string>; font?: Asset | Uint8Array };

/** REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b): one
 * family name is the whole call. Per-platform rows travel unresolved;
 * font bytes ride the blob channel. Set once, before the first mount. */
export function brandTypeface(family: string, opts: TypefaceOptions = {}): void {
  const pairs: wire.WireValue[] = [];
  if (opts.platforms !== undefined) {
    const entries = opts.platforms instanceof Map ? [...opts.platforms.entries()] : Object.entries(opts.platforms);
    for (const [key, value] of entries) {
      const tag = platformValue(key);
      pairs.push(new I64(tag));
      pairs.push(typefaceFamily(`family for ${PLATFORM_NAME_OF[tag] ?? tag}`, value));
    }
  }
  if (opts.font !== undefined && !(opts.font instanceof Asset || opts.font instanceof Uint8Array)) {
    throw new TypeError(
      `kaya: brandTypeface font takes a font FILE's bytes, not ${runtime.describe(opts.font)} — a family NAME is the first argument, and a font the app's BUILD shipped is kaya.asset('fonts/...')`,
    );
  }
  records().push(
    wire.tx_set_brand_typeface(opts.font !== undefined ? 1 : 0, typefaceFamily("family", family), pairs, opts.font !== undefined ? new BlobHandle(blobOf(opts.font)) : ""),
  );
}

/** DECLARE the app's identity (docs/app-identity-plan.md): the name it
 * goes by and the picture that stands for it. Set once, before the
 * first mount. */
export function appIdentity(name: string, opts: { icon?: Asset | Uint8Array } = {}): void {
  if (opts.icon !== undefined && !(opts.icon instanceof Asset || opts.icon instanceof Uint8Array)) {
    throw new TypeError(
      `kaya: appIdentity icon takes an image FILE's bytes, not ${runtime.describe(opts.icon)} — the NAME is the first argument, and a mark the app's BUILD shipped is kaya.asset('icons/...')`,
    );
  }
  if (typeof name !== "string") {
    throw new TypeError(`kaya: appIdentity takes the app's name as a string ('Aurora Notes'), not ${runtime.describe(name)} — an image FILE's bytes ride the icon slot, which is a different thing`);
  }
  records().push(wire.tx_set_app_identity(opts.icon !== undefined ? 1 : 0, name, opts.icon !== undefined ? new BlobHandle(blobOf(opts.icon)) : ""));
}

/** Make THIS transaction one undoable step in `window`'s history, under
 * `label` — one call, the app's whole undo surface (docs/undo-plan.md
 * D2). The marker goes AT THE HEAD of the batch wherever this call sits. */
export function undoable(label: string, window = 0): void {
  const text = textValue("undoable", label);
  if (!text) {
    throw new Error(
      "kaya: an undo group needs a name — the EMPTY label is taken: it is how a typing episode identifies itself on the same occurrence, so an anonymous group would be indistinguishable from the native tier",
    );
  }
  const recs = records();
  const head = recs[0];
  if (head !== undefined && head[4] === (wire.TX_UNDO_GROUP & 0xff) && head[5] === wire.TX_UNDO_GROUP >> 8) {
    throw new Error("kaya: this transaction is already an undo group — one name per step");
  }
  recs.unshift(wire.tx_undo_group(window, text));
}

/** WHAT THIS HOST CAN DO. Named booleans, never the bits. CAPABILITIES
 * INFORM; WALLS REFUSE. */
export type Capabilities = { readonly auxWindows: boolean };

/** This host's capabilities, constant for the life of the process. */
export function capabilities(): Capabilities {
  const bits = runtime.capabilityBits();
  return Object.freeze({ auxWindows: (bits & runtime.CAP_AUX_WINDOWS) !== 0 });
}

/** Declare a signal: a render pipe with no read. A number is an F64 on
 * the wire (docs/js-plan.md §4). */
export function signal<T extends string | number | boolean | CivilDate | CivilTime>(initial: T): Signal<Widen<T>> {
  const handle = new Signal<Widen<T>>(app()._next("signal"), initial as Widen<T>);
  app()._signals.set(handle.id, handle as Signal<unknown>);
  records().push(wire.tx_create_signal(handle.id, signalValue("a signal", initial)));
  return handle;
}
type Widen<T> = T extends string ? string : T extends number ? number : T extends boolean ? boolean : T;

/** Declare a collection: no argument for a scalar (string) table, a
 * record type for a record one, a list of record types for a sum — one
 * variant per member, in that order. */
export function collection(): Collection<string, Element>;
export function collection<S extends Schema>(type: RecordType<S>): Collection<Fields<S>, Row<S>>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function collection<T extends readonly RecordType<any>[]>(types: [...T]): Collection<InstanceOfAny<T>, Cases>;
export function collection(type?: RecordType | readonly RecordType[]): Collection<unknown, unknown> {
  const types = type === undefined ? null : Array.isArray(type) ? [...type] : [type as RecordType];
  const handle = new Collection<unknown, unknown>(app()._next("collection"), types);
  app()._collections.set(handle._id, handle);
  records().push(wire.tx_create_collection(handle._id, handle._variants.map((v) => v.schema)));
  const enclosing = _forCollections[_forCollections.length - 1];
  if (enclosing !== undefined) enclosing._children.push(handle);
  return handle;
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type InstanceOfAny<T extends readonly RecordType<any>[]> = { [K in keyof T]: T[K] extends RecordType<infer S> ? Fields<S> : never }[number];

/** THE ROW A STAMPED HANDLER IS ABOUT (docs/js-plan.md §4): its fields
 * read the model's copy and ASSIGN AS A PATCH (`todo.done = checked`).
 * A PROXY, so a misspelled field on assignment is refused BY NAME — a
 * per-field accessor would grow a plain property and patch nothing.
 * `instanceof` narrows a sum's row; a row that has left the collection
 * reads undefined, says `exists === false`, and matches no variant. */
export type RowHandle<E> = (E extends object ? E : { value: E }) & {
  readonly key: Key;
  readonly path: readonly Key[];
  readonly exists: boolean;
  remove(): void;
  update(value: E): void;
  patch(fields: Partial<E>): void;
  moveBefore(anchor: Key): void;
  moveAfter(anchor: Key): void;
  moveToEnd(): void;
  moveToFront(): void;
};

function rowHandle(owner: Collection<unknown, unknown>, keys: readonly Key[]): unknown {
  const path = keys.slice(0, -1);
  const key = keys[keys.length - 1]!;
  const bound: BoundCollection<unknown, unknown> = path.length === 0 ? owner : owner.at(...path);
  const current = (): unknown => bound.get(key);
  const value = current();
  const variant = value === undefined ? (owner._variants.length === 1 ? owner._variants[0]! : null) : owner._variantFor(value)[1];
  const scalar = variant !== null && variant.ctor === null;
  const fields = new Set<string>(scalar ? ["value"] : variant === null ? [] : variant.names);
  const named = variant?.ctor?.name ?? (scalar ? "a scalar row" : "a row that has left its collection");
  const methods: Record<string, unknown> = {
    key,
    path,
    get exists(): boolean {
      return current() !== undefined;
    },
    remove: () => bound.remove(key),
    update: (v: unknown) => bound.update(key, v),
    patch: (f: Record<string, unknown>) => bound.patch(key, f),
    moveBefore: (anchor: Key) => bound.moveBefore(key, anchor),
    moveAfter: (anchor: Key) => bound.moveAfter(key, anchor),
    moveToEnd: () => bound.moveToEnd(key),
    moveToFront: () => bound.moveToFront(key),
  };
  const read = (prop: string): unknown => {
    const now = current();
    if (now === undefined) return undefined;
    return scalar ? now : (now as Record<string, unknown>)[prop];
  };
  const target = Object.create(variant?.ctor?.prototype ?? Object.prototype) as object;
  return new Proxy(target, {
    get(receiver, prop) {
      if (typeof prop === "string") {
        if (fields.has(prop)) return read(prop);
        if (prop in methods) return methods[prop];
        if (prop === "toJSON") return current;
      }
      if (prop === Symbol.for("nodejs.util.inspect.custom")) return () => `RowHandle(${String(key)}) ${JSON.stringify(current())}`;
      return Reflect.get(receiver, prop);
    },
    set(_receiver, prop, v) {
      if (typeof prop === "string" && fields.has(prop)) {
        if (scalar) bound.update(key, v);
        else bound.patch(key, { [prop]: v });
        return true;
      }
      throw new TypeError(
        `kaya: ${named} has no field ${String(prop)} — the fields are ${[...fields].join(", ") || "none"}; ` +
          "a row handle patches fields and moves or removes its row, nothing else",
      );
    },
    has(receiver, prop) {
      return (typeof prop === "string" && (fields.has(prop) || prop in methods)) || Reflect.has(receiver, prop);
    },
    ownKeys() {
      return [...fields];
    },
    getOwnPropertyDescriptor(_receiver, prop) {
      if (typeof prop === "string" && fields.has(prop)) return { enumerable: true, configurable: true, writable: true, value: read(prop) };
      return undefined;
    },
  });
}

// ----------------------------------------------------------- vocabularies

export const Align = Object.freeze({
  START: wire.ALIGN_START,
  CENTER: wire.ALIGN_CENTER,
  END: wire.ALIGN_END,
  STRETCH: wire.ALIGN_STRETCH,
  BASELINE: wire.ALIGN_BASELINE,
});
export type AlignValue = (typeof Align)[keyof typeof Align];
export type AlignName = "start" | "center" | "end" | "stretch" | "baseline";
const ALIGN_NAMES: Record<string, number> = Object.fromEntries(Object.entries(Align).map(([k, v]) => [k.toLowerCase(), v]));

export const Axis = Object.freeze({ HORIZONTAL: wire.AXIS_HORIZONTAL, VERTICAL: wire.AXIS_VERTICAL });
export type AxisValue = (typeof Axis)[keyof typeof Axis];
export type AxisName = "horizontal" | "vertical";
const AXIS_NAMES: Record<string, number> = Object.fromEntries(Object.entries(Axis).map(([k, v]) => [k.toLowerCase(), v]));

function vocab(table: Record<string, number>, what: string, value: unknown, hint: string): number {
  if (typeof value === "string") {
    const v = table[value];
    if (v === undefined) throw new Error(`kaya: ${what} must be one of ${JSON.stringify(Object.keys(table).sort())}, got ${JSON.stringify(value)}`);
    return v;
  }
  if (typeof value !== "number") throw new TypeError(`kaya: ${what} takes ${hint} or its name, not ${runtime.describe(value)}`);
  if (!Object.values(table).includes(value)) throw new Error(`kaya: ${value} is not a ${what} — the vocabulary is ${JSON.stringify(Object.keys(table).sort())} (${hint})`);
  return value;
}

function axisValue(axis: unknown): number {
  return vocab(AXIS_NAMES, "axis", axis, "kaya.Axis.VERTICAL");
}

function alignValue(align: unknown): number {
  return vocab(ALIGN_NAMES, "align", align, "kaya.Align.CENTER");
}

/** SEMANTIC EMPHASIS, the closed vocabulary (docs/styling-plan.md D4). */
export const Role = Object.freeze({
  DESTRUCTIVE: wire.ROLE_DESTRUCTIVE,
  PROMINENT: wire.ROLE_PROMINENT,
  HEADING: wire.ROLE_HEADING,
  CAPTION: wire.ROLE_CAPTION,
  PLAIN: wire.ROLE_PLAIN,
});
export type RoleValue = (typeof Role)[keyof typeof Role];
export type RoleName = "destructive" | "prominent" | "heading" | "caption" | "plain";
const ROLE_NAMES: Record<string, number> = Object.fromEntries(Object.entries(Role).map(([k, v]) => [k.toLowerCase(), v]));

function roleValue(role: unknown): number {
  return vocab(ROLE_NAMES, "role", role, "kaya.Role.HEADING");
}

/** THE SEMANTIC ICON VOCABULARY (spec enum "symbol"; docs/styling-plan.md
 * D6): an app names a CONCEPT and each backend draws its own glyph. */
export const Symbol_ = Object.freeze({
  ADD: wire.SYMBOL_ADD,
  REMOVE: wire.SYMBOL_REMOVE,
  DELETE: wire.SYMBOL_DELETE,
  EDIT: wire.SYMBOL_EDIT,
  DONE: wire.SYMBOL_DONE,
  CLOSE: wire.SYMBOL_CLOSE,
  SEARCH: wire.SYMBOL_SEARCH,
  SETTINGS: wire.SYMBOL_SETTINGS,
  REFRESH: wire.SYMBOL_REFRESH,
  INFO: wire.SYMBOL_INFO,
  WARNING: wire.SYMBOL_WARNING,
  BACK: wire.SYMBOL_BACK,
  FORWARD: wire.SYMBOL_FORWARD,
  MORE: wire.SYMBOL_MORE,
  COPY: wire.SYMBOL_COPY,
  PASTE: wire.SYMBOL_PASTE,
  STAR: wire.SYMBOL_STAR,
  LOCK: wire.SYMBOL_LOCK,
  PERSON: wire.SYMBOL_PERSON,
  HOME: wire.SYMBOL_HOME,
});
// `Symbol` is JS's own; the vocabulary exports under kaya's usual name
// through this alias, so `kaya.Symbol.COPY` reads like every other binding.
export { Symbol_ as Symbol };
export type SymbolValue = (typeof Symbol_)[keyof typeof Symbol_];
export type SymbolName = Lowercase<keyof typeof Symbol_>;
const SYMBOL_NAMES: Record<string, number> = Object.fromEntries(Object.entries(Symbol_).map(([k, v]) => [k.toLowerCase(), v]));

function symbolValue(symbol: unknown): number {
  return vocab(SYMBOL_NAMES, "symbol", symbol, "kaya.Symbol.COPY");
}

// -------------------------------------------------------------- widgets

export type GrowOption = { grow?: number };
export type ContainerOptions = GrowOption & { spacing?: number; align?: AlignValue | AlignName; inset?: number };

function setLayout(handle: Handle, opts: ContainerOptions): void {
  if (opts.grow !== undefined) records().push(wire.tx_set_grow(handle.id, Number(opts.grow)));
  if (opts.spacing !== undefined) records().push(wire.tx_set_spacing(handle.id, Number(opts.spacing)));
  if (opts.align !== undefined) records().push(wire.tx_set_align(handle.id, alignValue(opts.align)));
  if (opts.inset !== undefined) records().push(wire.tx_set_inset(handle.id, Number(opts.inset)));
}

function setGrow(handle: Handle, opts: GrowOption): void {
  if (opts.grow !== undefined) records().push(wire.tx_set_grow(handle.id, Number(opts.grow)));
}

/** A vertical scroll viewport parenting EXACTLY ONE child. Give it `grow`
 * so the enclosing track CONSTRAINS it. */
export function scroll(optsOrBody?: GrowOption | (() => void), body?: () => void): Widget {
  const [opts, run] = optsAndOptionalBody(optsOrBody, body);
  const handle = widget(wire.KIND_SCROLL);
  setGrow(handle, opts);
  return new Container(handle).run(run);
}

export type GridOptions = ContainerOptions & { columnsWhen?: [SizeClass, number] };

/** A grid container laying its children out row-major into `columns`
 * columns, each at its NATURAL width, aligned across rows. `columnsWhen`
 * is a `[size class, count]` pair laying it out in that many columns
 * while the window's size class is the named one — a core-evaluated
 * breakpoint (docs/adaptive-layout-plan.md D6.2). */
export function grid(columns: number, optsOrBody?: GridOptions | (() => void), body?: () => void): Widget {
  const [opts, run] = optsAndOptionalBody(optsOrBody, body);
  const handle = widget(wire.KIND_GRID);
  records().push(wire.tx_set_columns(handle.id, Number(columns)));
  if (opts.columnsWhen !== undefined) {
    const pair = opts.columnsWhen;
    if (!Array.isArray(pair) || pair.length !== 2 || pair[0] !== COMPACT || !Number.isInteger(pair[1])) {
      throw new TypeError(
        `kaya: columnsWhen takes a [size class, count] pair — kaya.COMPACT is the only class today — not ${runtime.describe(opts.columnsWhen)} (docs/adaptive-layout-plan.md D6.2)`,
      );
    }
    if (_tplDepth > 0) {
      throw new TypeError("kaya: columnsWhen is live-only — a breakpoint's setters name live widgets, and a template grid is a blueprint stamped per entry (docs/adaptive-layout-plan.md D6.2)");
    }
    records().push(wire.tx_create_breakpoint(0, new I64(wire.SIZE_CLASS_COMPACT), 1, [new I64(handle.id), new I64(wire.PROP_COLUMNS), Number(pair[1])]));
  }
  setLayout(handle, opts);
  return new Container(handle).run(run);
}

export type LabeledOptions = GrowOption & { spacing?: number; inset?: number };

/** A LABELLED ROW (docs/forms-plan.md): `label` names the one control the
 * body declares, with an optional trailing button after it. A column of
 * nothing but these renders as the platform's form. The label is a
 * constant, a Signal, or — in a template — the enclosing For's element or
 * one of its fields. */
export function labeled(label: string | Bindable, optsOrBody?: LabeledOptions | (() => void), body?: () => void): Widget {
  const [opts, run] = optsAndOptionalBody(optsOrBody, body);
  const handle = widget(wire.KIND_LABELED);
  setLayout(handle, opts);
  return new Container(handle).run(() => {
    if (typeof label === "string") labelOf(label);
    else labelOf({ bind: label });
    if (run !== undefined) run();
  });
}

/** A spacer: PURE SUGAR for an empty grown column. */
export function spacer(opts: GrowOption = {}): Widget {
  const handle = widget(wire.KIND_COLUMN);
  records().push(wire.tx_set_grow(handle.id, Number(opts.grow ?? 1)));
  return handle;
}

/** A column container: parents everything declared inside its body. */
export function column(optsOrBody?: ContainerOptions | (() => void), body?: () => void): Widget {
  const [opts, run] = optsAndOptionalBody(optsOrBody, body);
  const handle = widget(wire.KIND_COLUMN);
  setLayout(handle, opts);
  return new Container(handle).run(run);
}

export type RowOptions = ContainerOptions & { stackWhen?: SizeClass };

/** A row container: column turned sideways. `stackWhen` stacks the
 * children vertically while the window's SIZE CLASS is the named one —
 * kaya.COMPACT — a core-evaluated breakpoint (docs/adaptive-layout-plan.md D3). */
export function row(optsOrBody?: RowOptions | (() => void), body?: () => void): Widget {
  const [opts, run] = optsAndOptionalBody(optsOrBody, body);
  const handle = widget(wire.KIND_ROW);
  if (opts.stackWhen !== undefined) {
    if (opts.stackWhen !== COMPACT) {
      throw new TypeError(
        `kaya: stackWhen takes a size class — kaya.COMPACT is the only class today — not ${runtime.describe(opts.stackWhen)}. The raw-width breakpoint is gone; kaya owns the numbers (docs/adaptive-layout-plan.md D3)`,
      );
    }
    if (_tplDepth > 0) {
      throw new TypeError("kaya: stackWhen is live-only — a breakpoint's setters name live widgets, and a template row is a blueprint stamped per entry (docs/adaptive-layout-plan.md D3)");
    }
    records().push(wire.tx_create_breakpoint(0, new I64(wire.SIZE_CLASS_COMPACT), 1, [new I64(handle.id), new I64(wire.PROP_AXIS), new I64(wire.AXIS_VERTICAL)]));
  }
  setLayout(handle, opts);
  return new Container(handle).run(run);
}

function optsAndOptionalBody<O extends object>(optsOrBody: O | (() => void) | undefined, body: (() => void) | undefined): [O, (() => void) | undefined] {
  if (typeof optsOrBody === "function") return [{} as O, optsOrBody];
  return [optsOrBody ?? ({} as O), body];
}

/** A text source: a constant string, or `{bind}` for one the row supplies. */
function textOrOpts<O extends object>(textOrOpts: string | O | undefined, opts: O | undefined): [string | undefined, O] {
  if (typeof textOrOpts === "string") return [textOrOpts, opts ?? ({} as O)];
  return [undefined, textOrOpts ?? opts ?? ({} as O)];
}

function bindText(what: string, handle: Handle, bind: unknown): void {
  if (bind instanceof Signal) records().push(wire.tx_bind_text(handle.id, bind.id));
  else if (bind instanceof Element) records().push(wire.tx_bind_text_element(handle.id, bind._level()));
  else if (bind instanceof FieldRef) records().push(wire.tx_bind_text_element(handle.id, bind._level(), bind._index));
  else {
    throw new TypeError(
      `kaya: ${what} bind takes a Signal, the enclosing For's element, or one of its fields (row.title), not ${runtime.describe(bind)} — inside a case arm project the field: kaya.${what}({bind: note.text})`,
    );
  }
}

export type ButtonOptions = GrowOption & { bind?: Bindable; onClick?: Handler };

/** A button: a constant caption, or `{bind}` for one the row supplies —
 * template-only, as in all eight other bindings (docs/tpl-props-plan.md F5). */
export function button(text: string, opts?: ButtonOptions): Widget;
export function button(opts: ButtonOptions): Widget;
export function button(a: string | ButtonOptions, b?: ButtonOptions): Widget {
  const [text, opts] = textOrOpts(a, b);
  const handle = widget(wire.KIND_BUTTON);
  if (text !== undefined) records().push(wire.tx_set_text(handle.id, textValue("button text", text)));
  if (opts.bind !== undefined) {
    if (_tplDepth === 0) {
      throw new TypeError(
        "kaya: button bind is template-only — a live button's caption is a constant in all eight bindings (docs/tpl-props-plan.md F5). Bind inside a For; live, pass the text.",
      );
    }
    bindText("button", handle, opts.bind);
  }
  if (opts.onClick !== undefined) app()._register(handle, wire.OCC_BUTTON_CLICKED, opts.onClick);
  setGrow(handle, opts);
  return handle;
}

export type CheckboxOptions = GrowOption & { checked?: boolean | Signal<boolean> | FieldRef; onToggle?: Handler };

/** A labeled on/off box. The box owns its checked bit: onToggle receives
 * the new state (template copies get the stamped keys first). */
export function checkbox(text: string, opts?: CheckboxOptions): Widget;
export function checkbox(opts: CheckboxOptions): Widget;
export function checkbox(a: string | CheckboxOptions, b?: CheckboxOptions): Widget {
  const [text, opts] = textOrOpts(a, b);
  const handle = widget(wire.KIND_CHECKBOX);
  if (text !== undefined) records().push(wire.tx_set_text(handle.id, textValue("checkbox text", text)));
  if (opts.checked !== undefined) {
    if (opts.checked instanceof Signal) records().push(wire.tx_bind_checked(handle.id, opts.checked.id));
    else if (opts.checked instanceof FieldRef) records().push(wire.tx_bind_checked_element(handle.id, opts.checked._level(), opts.checked._index));
    else records().push(wire.tx_set_checked(handle.id, opts.checked));
  }
  if (opts.onToggle !== undefined) app()._register(handle, wire.OCC_TOGGLED, opts.onToggle);
  setGrow(handle, opts);
  return handle;
}

export type ProgressOptions = GrowOption & { value?: number | Signal<number> | FieldRef; indeterminate?: boolean };

/** A progress bar: display-only. `value` is the determinate fraction
 * (0..=1); `indeterminate` switches to the platform's activity mode. */
export function progress(opts: ProgressOptions = {}): Widget {
  const handle = widget(wire.KIND_PROGRESS);
  if (opts.value !== undefined) {
    if (opts.value instanceof Signal) records().push(wire.tx_bind_value(handle.id, opts.value.id));
    else if (opts.value instanceof FieldRef) records().push(wire.tx_bind_value_element(handle.id, opts.value._level(), opts.value._index));
    else records().push(wire.tx_set_value(handle.id, Number(opts.value)));
  }
  if (opts.indeterminate !== undefined) records().push(wire.tx_set_indeterminate(handle.id, Boolean(opts.indeterminate)));
  setGrow(handle, opts);
  return handle;
}

export type ChoiceOptions = GrowOption & { selected?: number | Signal<number>; onSelect?: Handler };

function choice(kind: number, options: readonly string[], opts: ChoiceOptions): Widget {
  const handle = widget(kind);
  new Container(handle).run(() => {
    for (const text of options) label(text);
  });
  const selected = opts.selected ?? 0;
  if (selected instanceof Signal) records().push(wire.tx_bind_value(handle.id, selected.id));
  else records().push(wire.tx_set_value(handle.id, Number(selected)));
  const onSelect = opts.onSelect;
  if (onSelect !== undefined) {
    app()._register(handle, wire.OCC_VALUE_CHANGED, (...args: unknown[]) => onSelect(...args.slice(0, -1), Math.trunc(args[args.length - 1] as number)));
  }
  setGrow(handle, opts);
  return handle;
}

/** A dropdown select over fixed options. UNCONTROLLED: the widget owns
 * its selection and reports each USER pick to onSelect (a 0-based index). */
export function select(options: readonly string[], opts: ChoiceOptions = {}): Widget {
  return choice(wire.KIND_SELECT, options, opts);
}

/** A radio group over fixed options — the choice contract inline. */
export function radio(options: readonly string[], opts: ChoiceOptions = {}): Widget {
  return choice(wire.KIND_RADIO, options, opts);
}

export type SliderOptions = GrowOption & { value?: number | Signal<number> | FieldRef; min?: number; max?: number; step?: number; tickSpacing?: number; onChange?: Handler; onCommit?: Handler };

/** A slider over a numeric range. UNCONTROLLED: the widget owns its
 * position and reports each change to onChange and each settled gesture
 * to onCommit. `min`/`max` default to 0..1; `step` is the granularity the
 * thumb rests on and `tickSpacing` the distance between drawn ticks, in
 * value units (docs/slider-plan.md S1, S5). */
export function slider(opts: SliderOptions = {}): Widget {
  const handle = widget(wire.KIND_SLIDER);
  if (opts.min !== undefined) records().push(wire.tx_set_min(handle.id, Number(opts.min)));
  if (opts.max !== undefined) records().push(wire.tx_set_max(handle.id, Number(opts.max)));
  if (opts.step !== undefined) records().push(wire.tx_set_step(handle.id, Number(opts.step)));
  if (opts.tickSpacing !== undefined) records().push(wire.tx_set_tick_spacing(handle.id, Number(opts.tickSpacing)));
  if (opts.value !== undefined) {
    if (opts.value instanceof Signal) records().push(wire.tx_bind_value(handle.id, opts.value.id));
    else if (opts.value instanceof FieldRef) records().push(wire.tx_bind_value_element(handle.id, opts.value._level(), opts.value._index));
    else records().push(wire.tx_set_value(handle.id, Number(opts.value)));
  }
  if (opts.onChange !== undefined) app()._register(handle, wire.OCC_VALUE_CHANGED, opts.onChange);
  if (opts.onCommit !== undefined) app()._register(handle, wire.OCC_VALUE_COMMITTED, opts.onCommit);
  setGrow(handle, opts);
  return handle;
}

export type DatePickerOptions = GrowOption & { value?: CivilDate | Signal<CivilDate> | FieldRef; min?: CivilDate; max?: CivilDate; onChange?: Handler };

function pickerField(what: string, ref: FieldRef, want: Token, wanted: string): void {
  if (ref._token !== want) throw new TypeError(`kaya: ${what} binds a ${wanted} field`);
}

/** A date picker over civil dates — the compact field that opens the
 * platform's calendar (docs/datetime-plan.md). UNCONTROLLED: the control
 * owns its value and reports each COMMITTED pick to onChange, template
 * copies getting the row first. `min`/`max` are the inclusive range; a
 * pick past a bound lands on the bound. */
export function datePicker(opts: DatePickerOptions = {}): Widget {
  const handle = widget(wire.KIND_DATE_PICKER);
  if (opts.min !== undefined) records().push(wire.tx_set_min_date(handle.id, ...dateParts("min_date", opts.min)));
  if (opts.max !== undefined) records().push(wire.tx_set_max_date(handle.id, ...dateParts("max_date", opts.max)));
  if (opts.value !== undefined) {
    if (opts.value instanceof Signal) records().push(wire.tx_bind_date(handle.id, opts.value.id));
    else if (opts.value instanceof FieldRef) {
      pickerField("a date picker", opts.value, CivilDate, "kaya.CivilDate");
      records().push(wire.tx_bind_date_element(handle.id, opts.value._level(), opts.value._index));
    } else records().push(wire.tx_set_date(handle.id, ...dateParts("a date picker's value", opts.value)));
  }
  const onChange = opts.onChange;
  if (onChange !== undefined) {
    app()._register(handle, wire.OCC_DATE_CHANGED, (...args: unknown[]) => onChange(...args.slice(0, -1), civilDate(args[args.length - 1] as number)));
  }
  setGrow(handle, opts);
  return handle;
}

export type TimePickerOptions = GrowOption & { value?: CivilTime | Signal<CivilTime> | FieldRef; step?: number; onChange?: Handler };

/** A time picker over civil times — hours and minutes, no seconds.
 * `step` is the minute granularity (1, 5, 10, 15 or 30) and a pick snaps
 * to it. */
export function timePicker(opts: TimePickerOptions = {}): Widget {
  const handle = widget(wire.KIND_TIME_PICKER);
  if (opts.step !== undefined) records().push(wire.tx_set_minute_step(handle.id, Number(opts.step)));
  if (opts.value !== undefined) {
    if (opts.value instanceof Signal) records().push(wire.tx_bind_time(handle.id, opts.value.id));
    else if (opts.value instanceof FieldRef) {
      pickerField("a time picker", opts.value, CivilTime, "kaya.CivilTime");
      records().push(wire.tx_bind_time_element(handle.id, opts.value._level(), opts.value._index));
    } else records().push(wire.tx_set_time(handle.id, ...timeParts("a time picker's value", opts.value)));
  }
  const onChange = opts.onChange;
  if (onChange !== undefined) {
    app()._register(handle, wire.OCC_TIME_CHANGED, (...args: unknown[]) => onChange(...args.slice(0, -1), civilTime(args[args.length - 1] as number)));
  }
  setGrow(handle, opts);
  return handle;
}

export type TextInputOptions = GrowOption & { text?: string; onChange?: Handler };

/** A single-line text field. Uncontrolled, by doctrine: the widget owns
 * its text and reports each edit to onChange; there is no read-back. */
export function entry(opts: TextInputOptions = {}): Widget {
  const handle = widget(wire.KIND_ENTRY);
  if (opts.text !== undefined) records().push(wire.tx_set_text(handle.id, textValue("entry text", opts.text)));
  if (opts.onChange !== undefined) app()._register(handle, wire.OCC_TEXT_CHANGED, opts.onChange);
  setGrow(handle, opts);
  return handle;
}

/** A multi-line text editor: the entry's contract over the platform's
 * real multi-line editor. */
export function textarea(opts: TextInputOptions = {}): Widget {
  const handle = widget(wire.KIND_TEXTAREA);
  if (opts.text !== undefined) records().push(wire.tx_set_text(handle.id, textValue("textarea text", opts.text)));
  if (opts.onChange !== undefined) app()._register(handle, wire.OCC_TEXT_CHANGED, opts.onChange);
  setGrow(handle, opts);
  return handle;
}

export type LabelOptions = GrowOption & { bind?: Bindable };

/** A label: a constant, or `{bind}` for a Signal or the enclosing For's
 * element or field. */
export function label(text: string, opts?: LabelOptions): Widget;
export function label(opts: LabelOptions): Widget;
export function label(a: string | LabelOptions, b?: LabelOptions): Widget {
  const [text, opts] = textOrOpts(a, b);
  const handle = widget(wire.KIND_LABEL);
  if (text !== undefined) records().push(wire.tx_set_text(handle.id, textValue("label text", text)));
  if (opts.bind !== undefined) bindText("label", handle, opts.bind);
  setGrow(handle, opts);
  return handle;
}

// `labeled`'s own parameter is named `label`, which shadows the
// constructor it has to call.
const labelOf = label;

/** A label wearing the heading role, in one word (the h1 tradition). */
export function heading(text: string, opts?: LabelOptions): Widget;
export function heading(opts: LabelOptions): Widget;
export function heading(a: string | LabelOptions, b?: LabelOptions): Widget {
  return (typeof a === "string" ? label(a, b) : label(a)).role("heading");
}

/** A label wearing the caption role: the footnote tier. */
export function caption(text: string, opts?: LabelOptions): Widget;
export function caption(opts: LabelOptions): Widget;
export function caption(a: string | LabelOptions, b?: LabelOptions): Widget {
  return (typeof a === "string" ? label(a, b) : label(a)).role("caption");
}

export type ImageSource = Uint8Array | Asset | Signal<unknown> | FieldRef;

/** An image displaying encoded bytes: the toolkit decodes natively. The
 * source is bytes, an Asset, a Signal, or an element field. */
export function image(source?: ImageSource, opts: GrowOption = {}): Widget {
  const handle = widget(wire.KIND_IMAGE);
  if (source !== undefined) {
    if (source instanceof Signal) records().push(wire.tx_bind_source(handle.id, source.id));
    else if (source instanceof FieldRef) records().push(wire.tx_bind_source_element(handle.id, source._level(), source._index));
    else if (source instanceof Asset || source instanceof Uint8Array) records().push(wire.tx_set_source(handle.id, blobOf(source)));
    else {
      throw new TypeError(
        `kaya: image source takes encoded bytes, an asset the app's build shipped (kaya.asset('icons/...')), a Signal or an element field, not ${runtime.describe(source)} — text belongs on kaya.label`,
      );
    }
  }
  setGrow(handle, opts);
  return handle;
}

// --------------------------------------------------------------- canvas

// The five canvas vocabularies, by the names every binding spells them
// with. The NUMBERS come from the generated wire file, never retyped.
const PAINTS: Record<string, number> = {
  series: wire.PAINT_SERIES,
  series_fill: wire.PAINT_SERIES_FILL,
  grid: wire.PAINT_GRID,
  axis: wire.PAINT_AXIS,
  ground: wire.PAINT_GROUND,
};
const FILL_RULES: Record<string, number> = { nonzero: wire.FILL_RULE_NONZERO, even_odd: wire.FILL_RULE_EVEN_ODD };
const TEXT_ALIGNS: Record<string, number> = { start: wire.TEXT_ALIGN_START, middle: wire.TEXT_ALIGN_MIDDLE, end: wire.TEXT_ALIGN_END };
const TEXT_BASELINES: Record<string, number> = {
  alphabetic: wire.TEXT_BASELINE_ALPHABETIC,
  middle: wire.TEXT_BASELINE_MIDDLE,
  top: wire.TEXT_BASELINE_TOP,
  bottom: wire.TEXT_BASELINE_BOTTOM,
};
export type Paint = "series" | "series_fill" | "grid" | "axis" | "ground";
export type FillRule = "nonzero" | "even_odd";
export type TextAlign = "start" | "middle" | "end";
export type TextBaseline = "alphabetic" | "middle" | "top" | "bottom";

function drawVocab(table: Record<string, number>, what: string, name: string): I64 {
  const v = table[name];
  if (v === undefined) throw new Error(`kaya: ${JSON.stringify(name)} is not a canvas ${what}; the vocabulary is ${Object.keys(table).sort().join(", ")}`);
  return new I64(v);
}

/** The drawing scope's recorder: immediate-mode calls, recorded, ONE
 * record submitted when the scope closes (docs/canvas-plan.md §2.1). */
export class Draw {
  readonly viewbox: [number, number];
  /** @internal */ readonly _ops: wire.WireValue[] = [];

  /** @internal */
  constructor(viewbox: [number, number]) {
    this.viewbox = viewbox;
  }

  private _op(code: number, ...operands: wire.WireValue[]): this {
    this._ops.push(new I64(code), ...operands);
    return this;
  }

  moveTo(x: number, y: number): this {
    return this._op(wire.DRAW_OP_MOVE_TO, Number(x), Number(y));
  }

  lineTo(x: number, y: number): this {
    return this._op(wire.DRAW_OP_LINE_TO, Number(x), Number(y));
  }

  close(): this {
    return this._op(wire.DRAW_OP_CLOSE);
  }

  /** moveTo the first point and lineTo the rest. */
  polyline(points: readonly (readonly [number, number])[]): this {
    points.forEach(([x, y], i) => (i === 0 ? this.moveTo(x, y) : this.lineTo(x, y)));
    return this;
  }

  /** Stroke the built path and clear it. `width` is in points and does
   * NOT carry the viewbox stretch (docs/canvas-plan.md §3.2). */
  stroke(paint: Paint, width = 1): this {
    return this._op(wire.DRAW_OP_STROKE, drawVocab(PAINTS, "paint role", paint), Number(width));
  }

  /** Fill the built path and clear it. */
  fill(paint: Paint, rule: FillRule = "nonzero"): this {
    return this._op(wire.DRAW_OP_FILL, drawVocab(PAINTS, "paint role", paint), drawVocab(FILL_RULES, "fill rule", rule));
  }

  /** Select the face for subsequent text ops; `""` is kaya's own
   * embedded default face. */
  font(size: number, asset = "", weight = 400): this {
    return this._op(wire.DRAW_OP_FONT, String(asset), Number(size), new I64(Math.trunc(weight)));
  }

  /** Draw ONE LINE with its anchor at (x, y). A line break is refused by
   * the core (docs/canvas-plan.md §3.3). */
  text(x: number, y: number, s: string, opts: { paint?: Paint; align?: TextAlign; baseline?: TextBaseline } = {}): this {
    return this._op(
      wire.DRAW_OP_TEXT,
      Number(x),
      Number(y),
      drawVocab(PAINTS, "paint role", opts.paint ?? "axis"),
      drawVocab(TEXT_ALIGNS, "text align", opts.align ?? "start"),
      drawVocab(TEXT_BASELINES, "text baseline", opts.baseline ?? "alphabetic"),
      String(s),
    );
  }
}

export type Size = [width: number, height: number];
export type CanvasOptions = GrowOption & { fixed?: boolean; onDraw?: (d: Draw, size: Size) => void; onTick?: (d: Draw, size: Size, time: number) => void };

/** WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
 * (docs/canvas-plan.md §3.2.1). `scale` is spelled by declaring nothing.
 * THE HANDLER IS THE DECLARATION: registering it and putting the policy
 * on the wire are ONE act. */
function sizePolicy(handle: Widget, opts: CanvasOptions): void {
  const declared = (["fixed", "onDraw", "onTick"] as const).filter((k) => opts[k]);
  if (declared.length === 0) return;
  if (declared.length > 1) throw new Error(`kaya: a canvas declares ONE size policy, not ${declared.join(" and ")} (docs/canvas-plan.md §3.2.1)`);
  if (handle.isNode) {
    throw new Error("kaya: the size policy is a LIVE-ZONE declaration in this slice — a canvas inside a row template keeps `scale` (docs/deferred.md, the template-zone size policy entry)");
  }
  let policy: number;
  if (opts.fixed) policy = wire.SIZE_POLICY_FIXED;
  else if (opts.onDraw !== undefined) {
    policy = wire.SIZE_POLICY_REDRAW;
    app()._registerDraw(handle, policy, opts.onDraw);
  } else {
    policy = wire.SIZE_POLICY_TICK;
    app()._registerDraw(handle, policy, opts.onTick!);
  }
  records().push(wire.tx_set_size_policy(handle.id, policy));
}

/** A drawing surface. `viewbox` is the [width, height] coordinate system
 * the ops are written in AND the canvas's natural size in points
 * (docs/canvas-plan.md §3.2). Declare what it draws with
 * `handle.draw((d) => ...)`. `fixed`, `onDraw(d, size)` and `onTick(d,
 * size, time)` are the three size policies; declaring none is `scale`. */
export function canvas(viewbox: Size, opts: CanvasOptions = {}): Widget {
  const [w, h] = viewbox;
  const handle = widget(wire.KIND_CANVAS);
  _canvasViewboxes.set(handle.id, [Number(w), Number(h)]);
  setGrow(handle, opts);
  sizePolicy(handle, opts);
  return handle;
}

/** A For over `coll`: the body declares the template and receives the
 * element — a Row of FieldRefs, the scalar Element, or a sum's Cases. */
export function forEach<E, R>(coll: Collection<E, R>, body: (element: R) => void): Widget {
  if (!(coll instanceof Collection)) throw new TypeError("kaya: forEach binds the collection itself, not an instance — drop the .at(...)");
  const template = new Template(wire.tx_create_for, coll._id, true, coll as Collection<unknown, unknown>);
  const element = template.enter() as R;
  body(element);
  template.exit();
  return template.handle;
}

/** A When over a boolean signal: stamps its template on true, unstamps
 * on false. */
export function when(sig: Signal<boolean>, body: () => void): Widget {
  const template = new Template(wire.tx_create_when, sig.id, false);
  template.enter();
  body();
  template.exit();
  return template.handle;
}

// ---------------------------------------------------------------- app

export type WindowProps = {
  title?: string;
  width?: number;
  height?: number;
  vetoClose?: boolean;
  dirty?: boolean;
  panes?: number;
  sectionsPresentation?: number;
  inset?: number;
};

export type WindowOptions = WindowProps & {
  onCloseRequested?: () => void;
  onClosed?: () => void;
  onUndone?: (label: string, delta: UndoDelta) => void;
  onRedone?: (label: string, delta: UndoDelta) => void;
  windowId?: number;
};

/** The window construct's props, emitted into the ambient transaction —
 * ONE place, so the scene scope and the live call cannot drift apart. */
function windowProps(window: number, p: WindowProps): void {
  const recs = records();
  if (p.title !== undefined) recs.push(wire.tx_set_window_title(window, String(p.title)));
  if (p.vetoClose !== undefined) recs.push(wire.tx_set_window_veto_close(window, Boolean(p.vetoClose)));
  if (p.dirty !== undefined) recs.push(wire.tx_set_window_dirty(window, Boolean(p.dirty)));
  if (p.panes !== undefined) recs.push(wire.tx_set_window_panes(window, Math.trunc(p.panes)));
  if (p.sectionsPresentation !== undefined) recs.push(wire.tx_set_window_sections_presentation(window, Math.trunc(p.sectionsPresentation)));
  if (p.inset !== undefined) recs.push(wire.tx_set_window_inset(window, Number(p.inset)));
  if (p.width !== undefined || p.height !== undefined) {
    if (p.width === undefined || p.height === undefined) throw new Error("kaya: window width and height travel together");
    recs.push(wire.tx_set_window_width(window, Number(p.width)));
    recs.push(wire.tx_set_window_height(window, Number(p.height)));
  }
}

type ScopeKind = "window" | "build" | "push" | "section";

/** One scene scope: a transaction with a mount on exit (window, entry,
 * section) or without one (build). Entries and sections NEST inside an
 * open transaction; windows and builds do not. */
function runScope(
  kind: ScopeKind,
  body: (() => void) | undefined,
  surface: number,
  open: () => void,
): void {
  requireAppThread();
  if (kind === "push" || kind === "section") {
    const nested = _tx !== null;
    if (!nested) {
      _tx = [];
      _journal = new Map();
    }
    const outer: [boolean, Handle | null] = [_recording, _pendingRoot];
    _recording = true;
    _pendingRoot = null;
    let failed = false;
    try {
      open();
      if (body !== undefined) body();
    } catch (e) {
      failed = true;
      throw e;
    } finally {
      const root = pendingRoot();
      [_recording, _pendingRoot] = outer;
      if (failed) {
        if (!nested) {
          _tx = null;
          _journal = null;
        }
      } else {
        if (root === null) {
          if (!nested) {
            _tx = null;
            _journal = null;
          }
          throw new Error("kaya: pushEntry()/addSection() body declared no root container");
        }
        _tx!.push(wire.tx_mount(surface, root.id));
        if (!nested) {
          const recs = _tx!;
          _tx = null;
          _journal = null;
          if (recs.length > 0) runtime.submit(recs);
        }
      }
    }
    return;
  }
  if (_tx !== null && _implicit) commitImplicit();
  if (_tx !== null) throw new Error("kaya: transactions do not nest");
  _tx = [];
  _journal = new Map();
  _pendingRoot = null;
  _recording = kind === "window";
  let threw = false;
  try {
    open();
    if (body !== undefined) body();
  } catch (e) {
    threw = true;
    throw e;
  } finally {
    _recording = false;
    const recs = _tx!;
    _tx = null;
    const journal = _journal!;
    _journal = null;
    const abandoned = _openTraces.splice(0);
    _menuScopes.splice(0);
    if (threw || abandoned.length > 0) {
      _tplDepth = 0;
      _parents.splice(0);
      _forStack.splice(0);
      _forCollections.splice(0);
    }
    if (threw) {
      for (const restore of journal.values()) restore();
    } else if (abandoned.length > 0) {
      for (const restore of journal.values()) restore();
      throw new Error(
        "kaya: a `for (const t of coll)` template never closed — the loop body must run to completion (no break/return); conditional rendering is kaya.when",
      );
    } else {
      const root = pendingRoot();
      if (kind === "window" && root !== null) recs.push(wire.tx_mount(surface, root.id));
      if (recs.length > 0) runtime.submit(recs);
    }
  }
}

export type EntryOptions = { title?: string; interceptBack?: boolean; onPopped?: () => void; onBack?: () => void };
export type SectionOptions = { title?: string; symbol?: SymbolValue | SymbolName; onSelected?: () => void; window?: number };
export type BarMenuOptions = MenuOptions & { window?: number };
export type BarRadioGroupOptions = RadioGroupOptions & { window?: number };

export class App {
  private readonly _counters: Record<string, number> = { signal: 0, widget: 0, collection: 0, alert: 0, menu_item: 0, file_dialog: 0, clipboard: 0 };
  /** @internal */ readonly _widgetHandlers = new Map<string, Handler>();
  /** @internal */ readonly _nodeHandlers = new Map<string, Handler>();
  /** @internal */ readonly _nodeOwners = new Map<number, Collection<unknown, unknown>>();
  /** @internal */ readonly _itemCatalogs = new Map<number, ContextCatalog>();
  /** @internal */ readonly _alertHandlers = new Map<number, (choice: number) => void>();
  /** @internal */ readonly _fileDialogHandlers = new Map<number, (files: PickedFile[]) => void>();
  /** @internal */ readonly _clipboardHandlers = new Map<number, (clip: Clip | null) => void>();
  /** @internal */ readonly _menuHandlers = new Map<string, Handler>();
  /** @internal */ readonly _entryPopped = new Map<number, () => void>();
  /** @internal */ readonly _backRequested = new Map<number, () => void>();
  /** @internal */ readonly _sectionSelected = new Map<number, () => void>();
  /** @internal */ readonly _closeRequested = new Map<number, () => void>();
  /** @internal */ readonly _windowClosed = new Map<number, () => void>();
  /** @internal */ readonly _undone = new Map<number, (label: string, delta: UndoDelta) => void>();
  /** @internal */ readonly _redone = new Map<number, (label: string, delta: UndoDelta) => void>();
  /** @internal */ readonly _collections = new Map<number, Collection<unknown, unknown>>();
  /** @internal */ readonly _signals = new Map<number, Signal<unknown>>();
  /** @internal */ readonly _drawHandlers = new Map<number, [Widget, (d: Draw, size: Size, time: number) => void]>();
  private _posted: [Handler, unknown[]][] = [];
  private _drainScheduled = false;
  private _shutdown: (() => void) | null = null;

  constructor() {
    if (!runtime.IS_APP_THREAD) throw new Error("kaya: the App is created on the app thread — the worker the entry module runs in");
    _app = this;
  }

  /** @internal */
  _next(space: string): number {
    const n = (this._counters[space] ?? 0) + 1;
    this._counters[space] = n;
    return n;
  }

  /** @internal */
  _register(handle: Handle, kind: number, fn: Handler): void {
    // THE ROW HANDLE'S OWNER: the innermost For open at registration. A
    // catalog item registered live learns its owner at the attach
    // (contextMenu).
    const owner = _forCollections[_forCollections.length - 1];
    if (owner !== undefined) this._nodeOwners.set(handle.id, owner);
    else if (handle instanceof MenuItem) {
      const scope = _menuScopes[_menuScopes.length - 1];
      if (scope !== undefined && scope._seat[0] === "free") this._itemCatalogs.set(handle.id, scope._seat[1]);
    }
    (handle instanceof Widget && handle.isNode ? this._nodeHandlers : this._widgetHandlers).set(menuKey(kind, handle.id), fn);
  }

  /** @internal The row a stamped occurrence names, as a handle — or the
   * bare keys when no collection owns the registration. */
  _rowArgs(ident: number, keys: readonly Key[]): unknown[] {
    const owner = this._nodeOwners.get(ident) ?? this._itemCatalogs.get(ident)?._owner ?? null;
    if (owner === null || keys.length === 0) return [...keys];
    return [rowHandle(owner, keys)];
  }

  /** @internal The registration half of `canvas({onDraw})`/`({onTick})`.
   * THE HANDLER IS WIDENED HERE: a TICK canvas is a REDRAW canvas too, so
   * the answer path has ONE call shape (docs/canvas-plan.md, "WIDEN THE
   * HANDLER AT REGISTRATION"). */
  _registerDraw(handle: Widget, policy: number, fn: ((d: Draw, size: Size) => void) | ((d: Draw, size: Size, time: number) => void)): void {
    const widened = policy === wire.SIZE_POLICY_REDRAW ? (d: Draw, size: Size, _time: number) => (fn as (d: Draw, size: Size) => void)(d, size) : (fn as (d: Draw, size: Size, time: number) => void);
    this._drawHandlers.set(handle.id, [handle, widened]);
  }

  /** ANSWER ONE CANVAS ASK: draw at the size the core assigned and submit
   * that drawing, inside a transaction this binding opens; the ask never
   * reaches the app (docs/canvas-plan.md §3.2.1). */
  private _answerCanvas(ident: number, kind: number, values: wire.Decoded[]): void {
    const seat = this._drawHandlers.get(ident);
    if (seat === undefined) return;
    const [handle, fn] = seat;
    const size: Size = [Number(values[0]), Number(values[1])];
    const time = kind === wire.OCC_TICK ? Number(values[2]) : 0;
    this._dispatch(() => {
      _canvasViewboxes.set(ident, size);
      handle.draw((d) => fn(d, size, time));
    });
  }

  private _registerHistory(windowId: number, onUndone?: (label: string, delta: UndoDelta) => void, onRedone?: (label: string, delta: UndoDelta) => void): void {
    if (onUndone !== undefined) this._undone.set(windowId, onUndone);
    if (onRedone !== undefined) this._redone.set(windowId, onRedone);
  }

  /** An auxiliary surface's scene scope: the single top-level container
   * mounts INTO IT on exit. Capability-gated. */
  createWindow(windowId: number, opts: WindowOptions, body: () => void): void {
    if (opts.onCloseRequested !== undefined) this._closeRequested.set(windowId, opts.onCloseRequested);
    if (opts.onClosed !== undefined) this._windowClosed.set(windowId, opts.onClosed);
    this._registerHistory(windowId, opts.onUndone, opts.onRedone);
    runScope("window", body, windowId, () => {
      records().push(wire.tx_create_window(windowId));
      windowProps(windowId, opts);
    });
  }

  /** The scene scope: an ambient transaction whose single top-level
   * container mounts into the window on exit. THE LIVE SPELLING IS THIS
   * SAME CONSTRUCT, CALLED WITHOUT A BODY inside a handler:
   * `app.window({dirty: true})`. onUndone(label, delta) fires per undo
   * routed at this surface, and never retires. */
  window(opts: WindowOptions, body?: () => void): void;
  window(body: () => void): void;
  window(a: WindowOptions | (() => void), b?: () => void): void {
    const [opts, body] = optsAndOptionalBody<WindowOptions>(a, b);
    const windowId = opts.windowId ?? 0;
    if (opts.onCloseRequested !== undefined) this._closeRequested.set(windowId, opts.onCloseRequested);
    if (opts.onClosed !== undefined) this._windowClosed.set(windowId, opts.onClosed);
    this._registerHistory(windowId, opts.onUndone, opts.onRedone);
    if (_tx !== null) {
      // THE LIVE FORM: a transaction is already open, so the props join
      // it here and there is nothing to enter.
      if (body !== undefined) {
        throw new Error(
          "kaya: the window construct's props are already in this transaction — inside a handler (or app.build) the construct is a PLAIN CALL, app.window({dirty: true}). The body form is the scene scope: it opens a transaction of its own and mounts a root, which a handler must not do.",
        );
      }
      requireAppThread();
      windowProps(windowId, opts);
      return;
    }
    runScope("window", body, windowId, () => windowProps(windowId, opts));
  }

  /** An ambient transaction without the mount — for mutations outside
   * handlers. */
  build(body: () => void): void {
    runScope("build", body, 0, () => {});
  }

  /** A navigation entry's scene scope (DESIGN.md, Navigation): push_entry
   * plus the entry's props, and the single top-level container mounts
   * INTO IT on exit. Nests inside a handler's transaction. */
  pushEntry(entryId: number, opts: EntryOptions, body: () => void): void {
    runScope("push", body, entryId, () => {
      records().push(wire.tx_push_entry(0, entryId));
      if (opts.title !== undefined) records().push(wire.tx_set_entry_title(entryId, String(opts.title)));
      if (opts.interceptBack !== undefined) records().push(wire.tx_set_entry_intercept_back(entryId, Boolean(opts.interceptBack)));
      if (opts.onPopped !== undefined) this._entryPopped.set(entryId, opts.onPopped);
      if (opts.onBack !== undefined) this._backRequested.set(entryId, opts.onBack);
    });
  }

  /** A section's scene scope (DESIGN.md, Sections): add_section plus the
   * section's props, and the body's root mounts INTO IT on exit.
   * `symbol` is REFUSED HERE, at the call, if it is not in the vocabulary. */
  addSection(sectionId: number, opts: SectionOptions, body: () => void): void {
    const symbol = opts.symbol === undefined ? null : symbolValue(opts.symbol);
    const host = opts.window ?? 0;
    runScope("section", body, sectionId, () => {
      records().push(wire.tx_add_section(host, sectionId));
      if (opts.title !== undefined) records().push(wire.tx_set_section_title(sectionId, String(opts.title)));
      if (symbol !== null) records().push(wire.tx_set_section_symbol(sectionId, symbol));
      if (opts.onSelected !== undefined) this._sectionSelected.set(sectionId, opts.onSelected);
    });
  }

  /** A top-level menu in the window's command catalog — the menubar rides
   * the window construct. Returns the retained handle, which
   * `.append(body)` reopens at any time. */
  menu(label: string | Signal<string>, optsOrBody: BarMenuOptions | (() => void), body?: () => void): MenuItem {
    const [opts, run] = optsAndBody(optsOrBody, body);
    const it = menuCreate(wire.MENU_KIND_MENU, label);
    records().push(wire.tx_menubar_append(opts.window ?? 0, it.id));
    if (opts.enabled !== undefined) it.enabled(opts.enabled);
    if (opts.icon !== undefined) it.icon(opts.icon);
    if (opts.symbol !== undefined) it.symbol(opts.symbol);
    new MenuScope(["item", it.id], true).run(run);
    return it;
  }

  /** A BAR-LEVEL radio group, declaring only kaya.option children. */
  radioGroup(label: string | Signal<string>, optsOrBody: BarRadioGroupOptions | (() => void), body?: () => void): MenuItem {
    const [opts, run] = optsAndBody(optsOrBody, body);
    const it = menuCreate(wire.MENU_KIND_RADIO_GROUP, label);
    records().push(wire.tx_menubar_append(opts.window ?? 0, it.id));
    if (opts.enabled !== undefined) it.enabled(opts.enabled);
    if (opts.icon !== undefined) it.icon(opts.icon);
    if (opts.symbol !== undefined) it.symbol(opts.symbol);
    if (opts.onSelect !== undefined) this._menuHandlers.set(menuKey(wire.OCC_MENU_VALUE_CHANGED, it.id), opts.onSelect);
    const value = opts.value;
    new MenuScope(["item", it.id], true, value !== undefined ? () => it.value(value) : null).run(run);
    return it;
  }

  /** One handler dispatch, INSIDE an ambient transaction the runtime
   * opens; commits atomically on return. An exception crossing the build
   * boundary — which rolled the mirrors back and dropped the records — is
   * logged, and the loop moves on. An ASYNC handler's transaction ends
   * at its first await: what it returns is watched only to log a
   * rejection. */
  private _dispatch(handler: (...args: unknown[]) => unknown, ...args: unknown[]): void {
    try {
      let result: unknown;
      this.build(() => {
        result = handler(...args);
      });
      if (result !== null && typeof result === "object" && typeof (result as { then?: unknown }).then === "function") {
        (result as Promise<unknown>).then(undefined, (err: unknown) => {
          console.error(err instanceof Error ? (err.stack ?? err.message) : String(err));
          console.error(
            "kaya: an async handler rejected — its transaction committed at its first await, and " +
              "the continuation's writes before the throw stand (docs/js-plan.md §4)",
          );
        });
      }
    } catch (err) {
      console.error(err instanceof Error ? (err.stack ?? err.message) : String(err));
      console.error("kaya: handler threw (transaction rolled back)");
    }
  }

  /* post(), below, runs fn as a transaction on the app thread after
     whatever is running now, never nested — the way an async
     continuation gets back into a transaction. */
  /** Commit what this continuation has written and go on in a new
   * transaction: `await app.commit()`. Inside a handler the handler's own
   * transaction commits when its synchronous part returns, so this only
   * has to flush an implicit one. */
  commit(): Promise<void> {
    commitImplicit();
    return Promise.resolve();
  }

  post(fn: Handler, ...args: unknown[]): void {
    this._posted.push([fn, args]);
    if (!this._drainScheduled) {
      this._drainScheduled = true;
      setImmediate(() => this._drainPosted());
    }
  }

  /** Fold an undo's payload into the collection mirrors and the signal
   * cache — the rollback journal in reverse, core-authoritative. BEFORE
   * THE HANDLER AND WITHOUT ONE. No derived recompute, deliberately: the
   * derived write rode the same transaction as its cause and the core
   * restored it (bindings/python/kaya/__init__.py, _absorb_undo). */
  private _absorbUndo(delta: UndoDelta): void {
    for (const [signalId, value] of delta.signals) {
      const sig = this._signals.get(signalId);
      if (sig !== undefined) sig._mirror = value;
    }
    for (const [collId, path, key, state] of delta.entries) {
      const coll = this._collections.get(collId);
      if (coll === undefined) continue;
      const pk = pathKey(path as Key[]);
      let table = coll._instances.get(pk);
      if (table === undefined) {
        table = new Map();
        coll._instances.set(pk, table);
      }
      if (state === null) {
        table.delete(key);
        const prefix = [...(path as Key[]), key as Key];
        for (const child of coll._children) child._purge(prefix);
        continue;
      }
      const [variant, fields] = state;
      table.set(key, coll._decode(variant, fields, table.get(key)));
    }
    for (const [collId, path, keys] of delta.orders) {
      const coll = this._collections.get(collId);
      if (coll === undefined) continue;
      const table = coll._instances.get(pathKey(path as Key[]));
      if (table === undefined) continue;
      const named = new Set(keys);
      for (const key of [...keys, ...[...table.keys()].filter((k) => !named.has(k as wire.Decoded))]) {
        if (table.has(key)) {
          const value = table.get(key);
          table.delete(key);
          table.set(key, value);
        }
      }
    }
  }

  /** Run everything posted, each as its own transaction, in order. The
   * batch is taken BEFORE any of it runs, so a callable that posts again
   * lands in the NEXT batch. */
  private _drainPosted(): void {
    this._drainScheduled = false;
    const batch = this._posted;
    this._posted = [];
    for (const [fn, args] of batch) this._dispatch(fn, ...args);
  }

  private _onOccurrence(occ: wire.Occurrence): void {
    // Posted work first, then the ring: whatever brought this thread
    // back, it looks here before anywhere else.
    this._drainPosted();
    const { kind, keys, payload } = occ;
    const ident = occ.id as number;
    if (kind === wire.OCC_CLOSE_REQUESTED) {
      const handler = this._closeRequested.get(ident);
      if (handler !== undefined) this._dispatch(handler);
      return;
    }
    if (kind === wire.OCC_WINDOW_CLOSED) {
      this._closeRequested.delete(ident);
      const handler = this._windowClosed.get(ident);
      this._windowClosed.delete(ident);
      if (handler !== undefined) this._dispatch(handler);
      return;
    }
    if (kind === wire.OCC_ENTRY_POPPED) {
      this._backRequested.delete(ident);
      const handler = this._entryPopped.get(ident);
      this._entryPopped.delete(ident);
      if (handler !== undefined) this._dispatch(handler);
      return;
    }
    if (kind === wire.OCC_SECTION_SELECTED) {
      const handler = this._sectionSelected.get(ident);
      if (handler !== undefined) this._dispatch(handler);
      return;
    }
    if (kind === wire.OCC_BACK_REQUESTED) {
      const handler = this._backRequested.get(ident);
      if (handler !== undefined) this._dispatch(handler);
      return;
    }
    if (kind === wire.OCC_ALERT_RESULT) {
      const handler = this._alertHandlers.get(ident);
      this._alertHandlers.delete(ident);
      if (handler !== undefined) this._dispatch(handler as Handler, payload);
      return;
    }
    if (kind === wire.OCC_FILE_DIALOG_RESULT) {
      const handler = this._fileDialogHandlers.get(ident);
      this._fileDialogHandlers.delete(ident);
      if (handler !== undefined) {
        const files = (payload as wire.PickedTriple[]).map(([h, n, p]) => new PickedFile(h, n, p));
        this._dispatch(handler as Handler, files);
      }
      return;
    }
    if (kind === wire.OCC_CLIPBOARD_RESULT) {
      const handler = this._clipboardHandlers.get(ident);
      this._clipboardHandlers.delete(ident);
      if (handler !== undefined) this._dispatch(handler as Handler, representation(payload as wire.ClipPayload));
      return;
    }
    if (kind === wire.OCC_UNDONE || kind === wire.OCC_REDONE) {
      const { label: text, signals, texts, entries, orders } = payload as wire.UndoPayload;
      const delta: UndoDelta = { signals, texts, entries, orders };
      this._absorbUndo(delta);
      const handler = (kind === wire.OCC_UNDONE ? this._undone : this._redone).get(ident);
      if (handler !== undefined) this._dispatch(handler as Handler, text, delta);
      return;
    }
    if (kind === wire.OCC_DRAW_REQUESTED || kind === wire.OCC_TICK) {
      this._answerCanvas(ident, kind, payload as wire.Decoded[]);
      return;
    }
    if (kind === wire.OCC_MENU_ACTIVATED || kind === wire.OCC_MENU_TOGGLED || kind === wire.OCC_MENU_VALUE_CHANGED) {
      const handler = this._menuHandlers.get(menuKey(kind, ident));
      if (handler === undefined) return;
      const args: unknown[] = this._rowArgs(ident, keys as Key[]);
      if (kind === wire.OCC_MENU_TOGGLED) args.push(payload);
      else if (kind === wire.OCC_MENU_VALUE_CHANGED) args.push(Math.trunc(payload as number));
      this._dispatch(handler, ...args);
      return;
    }
    const handler = keys.length > 0 ? this._nodeHandlers.get(menuKey(kind, ident)) : this._widgetHandlers.get(menuKey(kind, ident));
    if (handler === undefined) return;
    const args: unknown[] = this._rowArgs(ident, keys as Key[]);
    if (kind === wire.OCC_PASTED) args.push(representation(payload as wire.ClipPayload));
    // A drop rides the same tag with four more words (docs/dnd-plan.md D1);
    // a null operation is a cancelled or refused drag, not an error.
    else if (kind === wire.OCC_DROPPED) args.push(dropped(payload as wire.DroppedPayload));
    else if (kind === wire.OCC_DRAG_ENDED) args.push(operation(payload as number));
    else if (payload !== null) args.push(payload);
    this._dispatch(handler, ...args);
  }

  /** Start dispatching occurrences on this thread — the worker that IS
   * the app thread. Returns a promise that settles when the core shuts
   * down; the exit code is the main thread's, which ends the process. */
  run(): Promise<void> {
    // The scene is queued by now; the main thread may enter the loop.
    runtime.signalReady();
    return new Promise((resolve) => {
      this._shutdown = resolve;
      runtime.startPump((occ) => {
        if (occ === null) {
          const done = this._shutdown;
          this._shutdown = null;
          if (done !== null) done();
          return;
        }
        this._onOccurrence(occ);
      });
    });
  }
}
