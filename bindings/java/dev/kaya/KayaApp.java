package dev.kaya;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/**
 * kaya's idiomatic surface for the JVM: the structural core.
 *
 * Three jobs, layered over KayaRing (the JNI ring access) and the
 * generated wire vocabulary (KayaWire):
 *
 * <ul>
 *   <li>id allocation: signals, widgets, collections, and template
 *       nodes come from per-space counters behind distinct types, so no
 *       app hand-numbers the id spaces — and the compiler keeps
 *       blueprint nodes (Node) from being used where live widgets
 *       (Widget) belong;
 *   <li>template scoping: forEach and when take a Consumer&lt;Tpl&gt;
 *       whose body declares the blueprint, bracketing the records;
 *   <li>occurrence dispatch: handlers register per button; the app loop
 *       consumes the ring with the platform's hand-won recipe (Unsafe
 *       fenced access on raw addresses; see the git history for the ART
 *       findings) and routes each click, handing template-node handlers
 *       the stamped copy's key path. Handlers receive their transaction
 *       explicitly; it submits when the handler returns.
 * </ul>
 */
public final class KayaApp {
    // Work handed over by other threads, waiting to run as transactions
    // on the app thread. THE ONLY STATE HERE TOUCHED FROM ANOTHER
    // THREAD, and the only reason this class carries a monitor at all —
    // everything else is app-thread-only by construction.
    private final Object postLock = new Object();
    private List<Consumer<Tx>> posted = new ArrayList<>();

    /** The closed standard-command vocabulary (DESIGN.md, Menus):
     * macOS places this one in the application menu, and every other
     * host leaves the item where the app declared it. */
    // A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
    // are. The accept list is open-ended — a custom format id is any
    // app-chosen string — so the four closed kinds cannot be a mask; but
    // they can be spelled once here instead of quoted at every call site.
    // A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
    // clipboard will ever offer, so Paste stays dead and the paste hook
    // never fires, with nothing to see anywhere. A custom id has no
    // constant by nature — the app that defines it names it.
    public static final String ACCEPT_TEXT = "text";

    public static final String ACCEPT_HTML = "html";

    public static final String ACCEPT_IMAGE = "image";

    public static final String ACCEPT_FILES = "files";

    public static final String ROLE_SETTINGS = "settings";

    /** The three clipboard commands. They lower to the platform's own,
     * act on the FOCUSED widget, and work out their own enablement from
     * what the clipboard offers and what that widget accepts.
     *
     * <p>GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only
     * the widget knows what is selected, so an app cannot assemble the
     * payload for "copy the selected text" out of the data layer. Copy
     * of a selection is therefore necessarily a command, and Paste is
     * its mirror. copy() and readClipboard() are for overriding that
     * default and for targets with no native behaviour. */
    public static final String ROLE_CUT = "cut";

    public static final String ROLE_COPY = "copy";

    public static final String ROLE_PASTE = "paste";

    /** The same gesture layer one tier deeper (docs/undo-plan.md D6).
     * Undo asks the FOCUSED widget first — a text widget whose native
     * stack has something to give answers before the core's ledger does
     * — and works out its own enablement from that same question, which
     * is why these are roles and not app-authored actions. An app that
     * declares them writes nothing else for undo except
     * {@link Tx#undoable}. */
    public static final String ROLE_UNDO = "undo";

    public static final String ROLE_REDO = "redo";

    /**
     * A container's cross-axis child placement (the align spec enum;
     * wire values pinned by the generated KayaWire constants).
     * Baseline is rows-only — the scene rejects it on columns.
     */
    public enum Align {
        START(0), CENTER(1), END(2), STRETCH(3), BASELINE(4);

        final long wire;

        Align(long wire) {
            this.wire = wire;
        }
    }

    /**
     * SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
     * never how it looks. A closed vocabulary — an app picks a meaning
     * and each platform spells it in its own chrome (red text on Apple,
     * an error-role container on Material, {@code .destructive-action}
     * on GTK), which is the whole reason this is an enum and not a
     * color.
     *
     * <p>Each variant fits one kind, and the ROOT refuses the misfits at
     * declare time in one sentence naming both sides — a destructive
     * label never reaches a backend to be improvised on.
     *
     * <p>Not to be confused with the {@code ROLE_*} string constants
     * above: those are the MENU role vocabulary (the platform's own
     * Cut/Copy/Paste items), a different tier with a different wire
     * prop.
     */
    public enum Role {
        /** An action whose press destroys something — buttons. */
        DESTRUCTIVE(KayaWire.ROLE_DESTRUCTIVE),
        /** THE primary action, one per dialog's worth of emphasis —
         * buttons. */
        PROMINENT(KayaWire.ROLE_PROMINENT),
        /** A text hierarchy heading — labels. The platform's heading
         * text style AND the accessibility heading trait assistive
         * users skim by. */
        HEADING(KayaWire.ROLE_HEADING);

        final long wire;

        Role(long wire) {
            this.wire = wire;
        }
    }

    // Which per-appearance brand overrides ride the set_brand_accent
    // record (Tx.brandAccent packs them). HAND-WRITTEN, because the
    // mask bits are the one part of that record the generator emits no
    // constant for: they are named here so the two numbers are said
    // once, with their meaning, rather than as bare 1 and 2 inside the
    // call.
    private static final int BRAND_MASK_LIGHT = 1;
    private static final int BRAND_MASK_DARK = 2;

    private long signals, widgets, collections, nodes, menuItems;
    private final Map<Long, Consumer<Tx>> widgetHandlers = new HashMap<>();
    // Menu dispatch tables, keyed by MENU ITEM id — their own id
    // space, separate from every widget/node table ("two tables,
    // always" — now N tables, still always). The node flavors receive
    // the stamped copy's key path (the keys ARE the noun).
    final Map<Long, Consumer<Tx>> menuActivated = new HashMap<>();
    final Map<Long, BiConsumer<Tx, List<Object>>> menuActivatedNode = new HashMap<>();
    final Map<Long, BiConsumer<Tx, Boolean>> menuToggled = new HashMap<>();
    final Map<Long, ToggleHandler> menuToggledNode = new HashMap<>();
    final Map<Long, BiConsumer<Tx, Integer>> menuSelected = new HashMap<>();
    final Map<Long, MenuSelectHandler> menuSelectedNode = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, List<Object>>> nodeHandlers = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, String>> widgetChanges = new HashMap<>();
    private final Map<Long, ChangeHandler> nodeChanges = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, Boolean>> widgetToggles = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, Double>> widgetValues = new HashMap<>();
    private final Map<Long, ValueHandler> nodeValues = new HashMap<>();
    // Window lifecycle: one handler each, receiving the window id.
    final java.util.Map<Long, Consumer<Tx>> closeRequested = new java.util.HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> entryPopped = new java.util.HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> backRequested = new java.util.HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> sectionSelected = new java.util.HashMap<>();
    private final java.util.Map<Long, BiConsumer<Tx, java.util.List<PickedFile>>> fileDialogs =
            new java.util.HashMap<>();
    private final java.util.Map<Long, BiConsumer<Tx, Integer>> alerts =
            new java.util.HashMap<>();
    private long nextAlert;
    private long nextFileDialog;
    // Clipboard reads share the alert's request/result grammar and so
    // its table shape: one-shot, keyed by request id.
    private final java.util.Map<Long, BiConsumer<Tx, Representation>> clipboardReads =
            new java.util.HashMap<>();
    private final java.util.Map<Long, BiConsumer<Tx, Representation>> widgetPastes =
            new java.util.HashMap<>();
    private final java.util.Map<Long, PasteHandler> nodePastes = new java.util.HashMap<>();
    private long nextClipboardRead;
    // Undo/redo handlers, keyed by WINDOW because the ledger is: Undo in
    // one window has never meant "revert what happened in another". NOT
    // one-shot — the section-selected stance rather than the alert's; a
    // history is walked as often as the user likes.
    private final java.util.Map<Long, UndoHandler> undone = new java.util.HashMap<>();
    private final java.util.Map<Long, UndoHandler> redone = new java.util.HashMap<>();
    // How to rebuild a collection entry's model value from the wire
    // fields an undo hands back. Registered where the collection is
    // declared, because that is the only place the guest's type is
    // known — the model keeps the guest's own object, while the delta
    // is core-authoritative wire values.
    final Map<Long, java.util.function.BiFunction<Integer, List<Object>, Object>> rebuild =
            new HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> windowClosed = new java.util.HashMap<>();
    private final Map<Long, ToggleHandler> nodeToggles = new HashMap<>();
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel (template bodies root themselves; a cross-zone addChild
    // is structurally impossible). The ambient app/tx pair exists for
    // the generated row traces — an Iterable is static code, and a
    // collection is only an id (one app per guest process, the Python
    // binding's own assumption).
    static KayaApp ambient;
    Tx currentTx;
    final java.util.List<Long> parents = new java.util.ArrayList<>();
    int openTraces;
    // >0 while a template body is being declared (a For body, a When
    // body, or an open row trace). openFors tracks Fors only — when()
    // pushes nothing there — so template-scope detection needs its own
    // counter. The template records once and replays: a model read
    // inside its body would bake one snapshot into every stamp as
    // silently dead data, so mirror reads throw while this is armed;
    // live-zone, handler, and build reads stay legal.
    int tplDepth;
    // Signals recomputed from a collection after each of its
    // mutations, written into the same transaction.
    private final Map<Long, List<Consumer<Tx>>> derived = new HashMap<>();

    /** A template entry's change handler: the stamped copy's keys, then
     * the entry's new text. */
    public interface ChangeHandler {
        void accept(Tx tx, List<Object> keys, String text);
    }

    /** A template widget's paste handler: the stamped copy's keys, then
     * the one representation that arrived. A paste onto a stamped row
     * is the same event as a paste onto a live one, exactly as a click
     * is. */
    public interface PasteHandler {
        void accept(Tx tx, List<Object> keys, Representation clip);
    }

    /** A template checkbox's toggle handler: the stamped copy's keys,
     * then the box's new state. */
    public interface ToggleHandler {
        void accept(Tx tx, List<Object> keys, boolean checked);
    }

    /** A template slider's or choice widget's change handler: the
     * stamped copy's keys, then the new value — a choice widget's being
     * its 0-based option index, widened, because the wire carries every
     * Value as an F64 and a template constructor takes no handler to
     * narrow it inside. */
    public interface ValueHandler {
        void accept(Tx tx, List<Object> keys, double value);
    }

    /** A node-anchored radio group's pick handler: the stamped copy's
     * keys, then the new 0-based option index. */
    public interface MenuSelectHandler {
        void accept(Tx tx, List<Object> keys, int index);
    }

    /** One signal the undo put back. */
    public record UndoSignal(long signal, Object value) {}

    /** One field's restored text, NAMED THE WAY THE EDIT THAT FILLED IT
     * was named: an EMPTY {@code path} means {@code id} is a live
     * widget's, and a non-empty one means it is the template node of a
     * stamped copy, at that key path — the same identity tag a click or
     * a paste on a copy already carries.
     *
     * <p>THE DELTA IS THE ONLY NOTIFICATION for this run: restoring a
     * typing episode is a programmatic write, and a programmatic write
     * never echoes, so an app folding {@code onChange} into its own
     * model would go stale on exactly this step if the payload did not
     * carry it (docs/undo-plan.md D5). An app with two rows needs the
     * path for the same reason: a text with no name could only be put
     * back in the field the app guessed. */
    public record UndoText(long id, List<Object> path, String text) {}

    /** One collection entry's restored state. {@code present} false is
     * "the restored state does not have this entry at all", and then
     * {@code variant} and {@code fields} are empty. */
    public record UndoEntry(
            long collection,
            List<Object> path,
            Object key,
            boolean present,
            int variant,
            List<Object> fields) {}

    /** One collection instance's restored key order — position is the
     * one thing per-entry statements cannot carry. */
    public record UndoOrder(long collection, List<Object> path, List<Object> keys) {}

    /**
     * What an undo or a redo PUT BACK: the core-authoritative statement
     * of the restored state (docs/undo-plan.md D5).
     *
     * <p>A STATEMENT, NOT A REPLAY. Every member says what a thing now
     * IS, so a mirror that applies one twice is still correct and no
     * binding diffs anything of its own. The core owns the truth; the
     * eight bindings fold the same payload the way they already fold a
     * rollback journal, which is what keeps mirror drift to one
     * implementation instead of eight.
     */
    public record UndoDelta(
            List<UndoSignal> signals,
            List<UndoText> texts,
            List<UndoEntry> entries,
            List<UndoOrder> orders) {}

    /** An undo's or a redo's handler: the group's authored label (EMPTY
     * for a typing episode) and what the core put back. */
    public interface UndoHandler {
        void accept(Tx tx, String label, UndoDelta delta);
    }

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call, so reads
    // (items, count) are exactly the writes. childCollections records
    // the declared-inside-a-For edges the model purges along when a
    // parent entry's copy is torn down.
    private final Map<Long, List<Instance>> model = new HashMap<>();
    private final Map<Long, List<Long>> childCollections = new HashMap<>();
    private final List<Long> openFors = new ArrayList<>();

    // The minter's counters: the highest I64 key each collection
    // INSTANCE has minted or absorbed, keyed by path the way the model
    // itself is. On the app and not on the Tx, deliberately — the
    // rollback journal restores the model, never these, so a key spent
    // by an abandoned transaction stays spent (see Tx.insertFresh).
    private final Map<Long, Map<List<Object>, Long>> fresh = new HashMap<>();

    /**
     * The next fresh key for one instance: counter+1, and the counter
     * keeps it. Monotonic by construction — nothing else writes it
     * downwards (see {@link Tx#insertFresh}).
     */
    private long mintKey(long coll, List<Object> path) {
        Map<List<Object>, Long> counters = fresh.computeIfAbsent(coll, k -> new HashMap<>());
        // The path is the instance's identity here exactly as it is in
        // the model; copied because it is the map's key from now on.
        List<Object> at = List.copyOf(path);
        long next = counters.getOrDefault(at, 0L) + 1;
        counters.put(at, next);
        return next;
    }

    /**
     * An explicit key, shown to the minter on its way into the table.
     * A numeric key at or above the counter carries it up so the next
     * mint clears it; anything else moves nothing, having no way to
     * collide with an I64.
     *
     * <p>INTEGER COUNTS AS I64 BECAUSE THE WIRE SAYS SO:
     * {@code KayaWire.encodeValue} sends both Integer and Long as
     * VALUE_I64, so a guest that writes {@code insert(tx, 7, ...)} —
     * autoboxed to Integer — has put a numeric key in the same space
     * the minter draws from, and the minter has to see it. Double is
     * VALUE_F64 and Boolean VALUE_BOOL; neither can collide.
     */
    private void absorbKey(long coll, List<Object> path, Object key) {
        long n;
        if (key instanceof Long) {
            n = (Long) key;
        } else if (key instanceof Integer) {
            n = (Integer) key;
        } else {
            return;
        }
        Map<List<Object>, Long> counters = fresh.computeIfAbsent(coll, k -> new HashMap<>());
        List<Object> at = List.copyOf(path);
        if (n > counters.getOrDefault(at, 0L)) {
            counters.put(at, n);
        }
    }

    /** One key/value pair of a collection instance, in insertion order. */
    public static final class Entry {
        public final Object key;
        public final Object value;

        Entry(Object key, Object value) {
            this.key = key;
            this.value = value;
        }
    }

    /**
     * One instance of a collection: the table inside the stamped copy
     * selected by path (the empty path for a live-zone collection).
     */
    private static final class Instance {
        final List<Object> path;
        final List<Entry> entries = new ArrayList<>();

        Instance(List<Object> path) {
            this.path = path;
        }

        Instance copy() {
            Instance c = new Instance(path);
            c.entries.addAll(entries);
            return c;
        }
    }

    private Instance instanceOf(long coll, List<Object> path) {
        for (Instance instance : model.getOrDefault(coll, java.util.Collections.emptyList())) {
            if (instance.path.equals(path)) {
                return instance;
            }
        }
        return null;
    }

    /**
     * A collection declared inside a For's template is torn down with
     * its copies: record the edge so the model purges along it.
     */
    private void registerCollection(long id) {
        if (!openFors.isEmpty()) {
            childCollections
                    .computeIfAbsent(openFors.get(openFors.size() - 1), k -> new ArrayList<>())
                    .add(id);
        }
    }

    /** A signal carrying its value type: writes are checked at compile
     * time, and when() demands a {@code Signal<Boolean>} instead of
     * panicking in the scene. */
    public static final class Signal<V> {
        final long id;

        Signal(long id) {
            this.id = id;
        }
    }

    /**
     * A live widget: exactly one thing on screen. It carries the
     * transaction that minted it so construction chains read
     * declaratively (tx.label(s).grow(1)); the id alone is the
     * widget's name, and a Widget stored past its build keeps naming
     * the same widget — only the chain methods die with it.
     */
    /** The window-prop chain, in the construction-sugar tier. */
    /** The alert chain: accumulates the one atomic SHOW_ALERT record
     * and sends it at show() — a request has a send moment, unlike a
     * window declaration. A chain that never calls show() sends
     * nothing. */
    public static final class AlertRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;
        private long window;
        private String title = "";
        private String message = "";
        private final java.util.ArrayList<String> actions = new java.util.ArrayList<>();
        private String cancel = "";
        private BiConsumer<Tx, Integer> onResult;

        AlertRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** Present over this window instead of the primary. */
        public AlertRef inWindow(long window) {
            this.window = window;
            return this;
        }

        public AlertRef title(String title) {
            this.title = title;
            return this;
        }

        public AlertRef message(String message) {
            this.message = message;
            return this;
        }

        /** Add an action button (at most two — the platform floor). */
        public AlertRef action(String label) {
            if (actions.size() >= 2) {
                throw new IllegalStateException(
                        "kaya: an alert carries at most 2 actions (the platform floor)");
            }
            actions.add(label);
            return this;
        }

        /** Name the always-present cancel slot. Required. */
        public AlertRef cancel(String label) {
            this.cancel = label;
            return this;
        }

        /** Bind the one-shot result handler to THIS request. */
        public AlertRef onResult(BiConsumer<Tx, Integer> handler) {
            this.onResult = handler;
            return this;
        }

        /** Send the request, returning its id; the one answer arrives
         * at the onResult handler. */
        public long show() {
            if (cancel.isEmpty()) {
                throw new IllegalStateException(
                        "kaya: the cancel slot always exists and needs a name — "
                                + "call cancel(label) before show()");
            }
            String action0 = actions.size() >= 1 ? actions.get(0) : "";
            String action1 = actions.size() == 2 ? actions.get(1) : "";
            if (onResult != null) {
                app.alerts.put(id, onResult);
            }
            tx.emit(KayaWire.txShowAlert(
                    window, id, actions.size(), title, message,
                    action0, action1, cancel));
            return id;
        }
    }

    /**
     * One file the picker answered with: a handle to redeem, a display
     * name, and localPath — a RE-OPENABLE NAME, empty unless
     * re-opening it actually works, which measurement puts at the
     * three desktops and neither phone (DESIGN.md, File dialogs).
     */
    /** One representation, arriving — the sum a copy is the record of.
     *
     * <p>Java has sealed interfaces and records, so this is one of each
     * and a switch is the elimination. YOU OFFER MANY AND YOU RECEIVE
     * ONE, and the two shapes say so: a record of five optional fields
     * would invite a guest to check five where four are structurally
     * always empty. */
    public sealed interface Representation {
        record Text(String value) implements Representation {}

        record Html(String value) implements Representation {}

        /** Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE —
         * the hosts convert freely between image types — so compare
         * what the image IS, never the bytes it arrived in. */
        record Image(byte[] bytes) implements Representation {}

        /** Files, plural INSIDE one representation — the same nesting
         * text/uri-list and CF_HDROP already have. A pasted file is the
         * picker's own capability arriving through a second door, so it
         * opens with the call that already exists. */
        record Files(java.util.List<PickedFile> value) implements Representation {}

        /** An app-defined format, round-tripped verbatim. */
        record Custom(String id, byte[] bytes) implements Representation {}
    }

    /** Turn the decoder's kind-and-values into the sum, or null.
     *
     * <p>EMPTY IS THE UNIVERSAL NO: null covers a denied prompt on iOS,
     * an unfocused reader on Android or Wayland, an empty clipboard,
     * and content in no representation this read accepted. The guest is
     * not told which, because the platforms deliberately do not say. */
    static Representation representation(Object payload) {
        if (!(payload instanceof KayaWire.ClipValues clip)) {
            return null;
        }
        java.util.List<Object> v = clip.values;
        return switch (clip.kind) {
            case KayaWire.CLIP_TEXT -> new Representation.Text(clipString(v, 0));
            case KayaWire.CLIP_HTML -> new Representation.Html(clipString(v, 0));
            case KayaWire.CLIP_IMAGE -> new Representation.Image(clipBytes(v, 0));
            case KayaWire.CLIP_CUSTOM ->
                    new Representation.Custom(clipString(v, 0), clipBytes(v, 1));
            case KayaWire.CLIP_FILES -> {
                // The picker's own three-per-file grouping, so a guest
                // that decodes a dialog result decodes this with the
                // same loop.
                java.util.List<PickedFile> files = new java.util.ArrayList<>();
                for (int i = 0; i + 2 < v.size(); i += 3) {
                    long handle = v.get(i) instanceof Long h ? h : 0L;
                    files.add(new PickedFile(
                            handle, clipString(v, i + 1), clipString(v, i + 2)));
                }
                yield new Representation.Files(files);
            }
            default -> null;
        };
    }

    private static String clipString(java.util.List<Object> values, int i) {
        return i < values.size() && values.get(i) instanceof String s ? s : "";
    }

    private static byte[] clipBytes(java.util.List<Object> values, int i) {
        return i < values.size() && values.get(i) instanceof byte[] b ? b : new byte[0];
    }

    /** Join an accept list: the closed kinds by name plus any custom
     * ids, space separated.
     *
     * <p>A LIST AND NOT A MASK, because half the set is open-ended. A
     * custom format that could be written and never accepted would be
     * an escape hatch that only opens outward, and round-tripping an
     * app's own data is the whole reason to have one. Ids reach every
     * platform's registry verbatim, so they carry no spaces — which is
     * what makes the join unambiguous, and what this refuses to let you
     * break. */
    static String acceptList(String... kinds) {
        for (String kind : kinds) {
            if (kind == null || kind.isEmpty() || kind.contains(" ")) {
                throw new IllegalArgumentException(
                        "kaya: \"" + kind + "\" is not an accept-list entry — the "
                        + "closed kinds are \"text\", \"html\", \"image\" and "
                        + "\"files\", and a custom format id reaches the platform's "
                        + "own registry verbatim, so it carries no spaces");
            }
        }
        return String.join(" ", kinds);
    }

    public record PickedFile(long handle, String name, String localPath) {
        /**
         * Redeem the handle for real streams, plus whether it seeks.
         *
         * THE MODE DECIDES WHAT YOU GET, and it is the mode you pass
         * here: {@link KayaWire#FILE_MODE_READ} answers with a reading
         * half only, {@link KayaWire#FILE_MODE_WRITE} with a writing
         * half only (and the file is already truncated — the core's
         * open did it), {@link KayaWire#FILE_MODE_READ_WRITE} with
         * both.
         *
         * BLOCKS, and may block for a long time — a cloud provider can
         * download the file first — so call it from a thread you chose
         * and post the result back. kaya is not in the data path: what
         * comes back are ordinary java.io streams.
         *
         * Seekable RIDES THE OPEN rather than the pick because that is
         * the only place the answer exists: an Android provider may
         * hand back a pipe, and nothing short of opening reveals it.
         */
        public Opened open(int mode) throws java.io.IOException {
            int[] seekable = new int[1];
            java.io.FileDescriptor fd = KayaRing.openPicked(handle, mode, seekable);
            return new Opened(fd, mode, seekable[0] != 0);
        }
    }

    /**
     * An opened picked file: the halves THE MODE PERMITS, and whether
     * it seeks.
     *
     * <p>THE DEFECT THIS SHAPE EXISTS TO PREVENT (docs/save-plan.md D3,
     * measured 2026-08-09): this used to be a record holding one
     * {@code FileInputStream}, built the same way whatever mode was
     * asked for. The mode still reached the core and still decided the
     * OS handle's access, so the descriptor was writable — and the
     * binding wrapped it in a reading stream anyway. Every Java app on
     * every platform got "Bad file descriptor" the moment it tried to
     * write to a file the user picked, and no scene, leg or test asked
     * for a mode other than read, so nothing said so for four
     * milestones.
     *
     * <p>JAVA IS THE ONE LANGUAGE THAT NEEDS TWO OBJECTS HERE, and this
     * is the whole of the carve-out (DESIGN.md, Binding conventions —
     * the idiom decides the spelling, never the semantics). Every other
     * binding hands back ONE duplex object whose permitted operations
     * follow the mode: {@code std::fs::File}, {@code FileHandle},
     * {@code FileStream} with a {@code FileAccess}, {@code os.fdopen}
     * with "rb"/"wb"/"r+b", GHC's {@code Handle}, {@code os.File},
     * {@code Unix.file_descr}. Java's stream types are unidirectional
     * and no public API wraps a descriptor in a duplex object at all
     * ({@code RandomAccessFile} takes a path, and a channel from either
     * stream carries that stream's one direction), so read-write hands
     * back both halves OVER ONE DESCRIPTOR — MEASURED to share one file
     * offset, which is what makes them a faithful stand-in: read three
     * bytes then write, and the write lands at three, exactly as the
     * duplex object would.
     *
     * <p>The half the mode does not permit is ABSENT, and asking for it
     * throws with the mode named rather than handing over a stream
     * whose every call fails at the descriptor.
     */
    public static final class Opened implements java.io.Closeable {
        private final java.io.InputStream in;
        private final java.io.OutputStream out;
        private final boolean seekable;
        private final int mode;

        Opened(java.io.FileDescriptor fd, int mode, boolean seekable) {
            this.mode = mode;
            this.seekable = seekable;
            switch (mode) {
                case KayaWire.FILE_MODE_READ -> {
                    this.in = new java.io.FileInputStream(fd);
                    this.out = null;
                }
                case KayaWire.FILE_MODE_WRITE -> {
                    this.in = null;
                    this.out = new java.io.FileOutputStream(fd);
                }
                case KayaWire.FILE_MODE_READ_WRITE -> {
                    // Both over the SAME descriptor: one file offset,
                    // and closing either closes it once (the JDK's
                    // FileDescriptor tracks its parents).
                    this.in = new java.io.FileInputStream(fd);
                    this.out = new java.io.FileOutputStream(fd);
                }
                default -> throw new IllegalArgumentException(
                        "kaya: " + mode + " is not a file mode — pass "
                        + "KayaWire.FILE_MODE_READ, FILE_MODE_WRITE or "
                        + "FILE_MODE_READ_WRITE");
            }
        }

        /** The reading half — absent when the mode was write-only. */
        public java.io.InputStream stream() {
            if (in == null) {
                throw new IllegalStateException(
                        "kaya: this file was opened with "
                        + "KayaWire.FILE_MODE_WRITE, which has no reading half"
                        + " — open it again with FILE_MODE_READ to read what "
                        + "you wrote, or with FILE_MODE_READ_WRITE to do both "
                        + "through one handle");
            }
            return in;
        }

        /** The writing half — absent when the mode was read-only.
         *
         * <p>FILE_MODE_WRITE ARRIVES TRUNCATED: the core's open did it,
         * on a picked file and on a save destination alike, so the first
         * byte written is the file's first byte. FILE_MODE_READ_WRITE
         * does not truncate, and shares its offset with
         * {@link #stream()}. */
        public java.io.OutputStream sink() {
            if (out == null) {
                throw new IllegalStateException(
                        "kaya: this file was opened with "
                        + "KayaWire.FILE_MODE_READ, which has no writing half"
                        + " — open it again with FILE_MODE_WRITE (which "
                        + "truncates) or FILE_MODE_READ_WRITE to write through "
                        + "it");
            }
            return out;
        }

        /** Whether the handle supports random access. */
        public boolean seekable() {
            return seekable;
        }

        /** The mode this was opened with — one of KayaWire's three. */
        public int mode() {
            return mode;
        }

        /** Close the descriptor, whichever halves are open. Closing one
         * half closes it for both; this closes what there is, once. */
        @Override
        public void close() throws java.io.IOException {
            try {
                if (in != null) {
                    in.close();
                }
            } finally {
                if (out != null) {
                    out.close();
                }
            }
        }
    }

    /** Accumulates the one atomic SHOW_FILE_DIALOG record; nothing is
     * sent until show (a request has a send moment). */
    public static final class FileDialogRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;
        private final boolean multiple;
        private long window;
        private final java.util.List<Object> filters = new java.util.ArrayList<>();
        private BiConsumer<Tx, java.util.List<PickedFile>> onResult;

        FileDialogRef(Tx tx, KayaApp app, long id, boolean multiple) {
            this.tx = tx;
            this.app = app;
            this.id = id;
            this.multiple = multiple;
        }

        /** Target an auxiliary window (0 = primary). */
        public FileDialogRef in(long window) {
            this.window = window;
            return this;
        }

        /** One advisory (label, space-separated extensions) pair.
         * ADVISORY on every platform: a default view rather than a
         * guarantee, so the guest still validates what it got. */
        public FileDialogRef filter(String label, String extensions) {
            filters.add(label);
            filters.add(extensions);
            return this;
        }

        /** Bind the one-shot result handler to THIS request. */
        public FileDialogRef onResult(BiConsumer<Tx, java.util.List<PickedFile>> handler) {
            this.onResult = handler;
            return this;
        }

        /** Send the request, returning its id. */
        public long show() {
            if (onResult != null) {
                app.fileDialogs.put(id, onResult);
            }
            tx.emit(KayaWire.txShowFileDialog(
                    window, id, multiple ? 1 : 0, filters.toArray()));
            return id;
        }
    }

    /** Accumulates the one atomic SHOW_SAVE_DIALOG record; nothing is
     * sent until show, the picker chain's shape exactly.
     *
     * <p>ONE ID SPACE AND ONE TABLE with the picker, because that is
     * what the wire says: the answer comes back as a file_dialog_result
     * and one dialog of either kind is live per process. The narrowing
     * to at-most-one file happens HERE rather than in every app —
     * "exactly one locator or none" is a fact of the request, not
     * something a guest should re-derive from a list length. */
    public static final class SaveDialogRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;
        private final String suggestedName;
        private long window;
        private final java.util.List<Object> filters = new java.util.ArrayList<>();
        private BiConsumer<Tx, PickedFile> onResult;

        SaveDialogRef(Tx tx, KayaApp app, long id, String suggestedName) {
            this.tx = tx;
            this.app = app;
            this.id = id;
            this.suggestedName = suggestedName;
        }

        /** Target an auxiliary window (0 = primary). */
        public SaveDialogRef in(long window) {
            this.window = window;
            return this;
        }

        /** One advisory (label, space-separated extensions) pair — the
         * picker's rule verbatim: a default view, never a guarantee. */
        public SaveDialogRef filter(String label, String extensions) {
            filters.add(label);
            filters.add(extensions);
            return this;
        }

        /** Bind the one-shot result handler to THIS request. CANCEL IS
         * null — the empty answer the picker spells as an empty list,
         * narrowed to the one destination this request can have. */
        public SaveDialogRef onResult(BiConsumer<Tx, PickedFile> handler) {
            this.onResult = handler;
            return this;
        }

        /** Send the request, returning its id. */
        public long show() {
            if (onResult != null) {
                BiConsumer<Tx, PickedFile> handler = onResult;
                app.fileDialogs.put(id, (t, files) ->
                        handler.accept(t, files.isEmpty() ? null : files.get(0)));
            }
            tx.emit(KayaWire.txShowSaveDialog(
                    window, id, suggestedName, filters.toArray()));
            return id;
        }
    }

    /** The copy chain: a clip record under construction. Each method
     * fills one representation, and send() puts it on the clipboard.
     *
     * <p>A RECORD AND NOT A LIST is the whole shape — at most one per
     * kind is structural, since a second text() replaces the field
     * rather than needing a duplicate check the root has to run. */
    public static final class CopyRef {
        private final Tx tx;
        private String text;
        private String html;
        private byte[] image;
        private final java.util.List<Long> files = new java.util.ArrayList<>();
        private final java.util.List<Object[]> custom = new java.util.ArrayList<>();

        CopyRef(Tx tx) {
            this.tx = tx;
        }

        public CopyRef text(String value) {
            this.text = value;
            return this;
        }

        public CopyRef html(String value) {
            this.html = value;
            return this;
        }

        /** Encoded image bytes — the same currency the image property
         * takes. */
        public CopyRef image(byte[] bytes) {
            this.image = bytes;
            return this;
        }

        /** Offer a picked file, the picker's own capability put
         * straight on the clipboard. The bytes never move through
         * kaya. */
        public CopyRef file(PickedFile f) {
            files.add(f.handle());
            return this;
        }

        /** An app-defined format, round-tripped verbatim. The id
         * reaches every platform's own registry unchanged — a UTI on
         * Apple, RegisterClipboardFormat on Windows, a target atom on
         * X11 and Wayland, a MIME type on Android — so it carries no
         * spaces, and kaya does nothing clever with the bytes. */
        public CopyRef custom(String id, byte[] bytes) {
            acceptList(id);
            custom.add(new Object[] {id, bytes});
            return this;
        }

        /** Put the clip on the system clipboard. The wire order is
         * kaya's, not this chain's — descending richness, which is
         * preference order on every host that has one. */
        public void send() {
            int present = 0;
            java.util.List<Object> values = new java.util.ArrayList<>();
            for (Object[] pair : custom) {
                values.add(pair[0]);
                values.add(new KayaWire.BlobHandle(
                        KayaRing.blobRegister((byte[]) pair[1])));
            }
            for (long handle : files) {
                values.add(handle);
            }
            if (image != null) {
                present |= KayaWire.CLIP_IMAGE;
                values.add(new KayaWire.BlobHandle(KayaRing.blobRegister(image)));
            }
            if (html != null) {
                present |= KayaWire.CLIP_HTML;
                values.add(html);
            }
            if (text != null) {
                present |= KayaWire.CLIP_TEXT;
                values.add(text);
            }
            tx.emit(KayaWire.txCopy(
                    present, files.size(), custom.size(), values.toArray()));
        }
    }

    /** The read chain: which representations this read can use, and the
     * request id its one answer arrives under. */
    public static final class ClipReadRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;
        private final java.util.List<String> accepting = new java.util.ArrayList<>();
        private BiConsumer<Tx, Representation> onResult;

        ClipReadRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        public ClipReadRef text() {
            return accept("text");
        }

        public ClipReadRef html() {
            return accept("html");
        }

        public ClipReadRef image() {
            return accept("image");
        }

        public ClipReadRef files() {
            return accept("files");
        }

        /** Accept an app-defined format by id. Custom formats are tried
         * FIRST, in the order named: an app's own format round-trips
         * its data losslessly, which is the only reason to have one. */
        public ClipReadRef custom(String formatId) {
            return accept(formatId);
        }

        private ClipReadRef accept(String kind) {
            accepting.add(kind);
            return this;
        }

        /** Bind the one-shot handler to THIS request. The answer is
         * null when the clipboard had nothing this read accepted — and
         * null equally when the read was denied or the app was
         * unfocused, because no platform says which. */
        public ClipReadRef onResult(BiConsumer<Tx, Representation> handler) {
            this.onResult = handler;
            return this;
        }

        /** Send the request, returning its id. */
        public long send() {
            if (onResult != null) {
                app.clipboardReads.put(id, onResult);
            }
            tx.emit(KayaWire.txReadClipboard(
                    id, acceptList(accepting.toArray(new String[0]))));
            return id;
        }
    }

    public static final class WindowRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;

        WindowRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** Binds the close-veto handler to THIS window (per-window —
         * handlers scope to the thing that creates them): fires per
         * chrome close while vetoClose is armed; nothing has closed —
         * answer with tx.destroyWindow to agree. */
        public WindowRef onCloseRequested(Consumer<Tx> handler) {
            app.closeRequested.put(id, handler);
            return this;
        }

        /** Binds the closed handler to THIS window: fires when the
         * non-veto auxiliary is chrome-closed (informational;
         * destroyWindow reconciles), retiring with it. */
        public WindowRef onClosed(Consumer<Tx> handler) {
            app.windowClosed.put(id, handler);
            return this;
        }

        /**
         * Binds the undone handler to THIS window (per-window — handlers
         * scope to the thing that creates them, and the ledger is:
         * Undo in one window has never meant "revert what happened in
         * another"): fires each time kaya routes an undo here, with the
         * group's authored label (EMPTY for a typing episode) and what
         * the core put back.
         *
         * <p>NOT ONE-SHOT — the onSelected stance rather than the
         * alert's. A history is walked as often as the user likes, and
         * the registration outlives every step.
         *
         * <p>THE DELTA IS THE ONLY NOTIFICATION. Applying an inverse is
         * a programmatic write, so the echo doctrine silences every
         * occurrence it would otherwise cause — no onChange for the text
         * it restored, no value change for the signals. This binding has
         * already folded the payload into its own collection model
         * before the handler runs; this is where an app folds it into
         * ITS model.
         */
        public WindowRef onUndone(UndoHandler handler) {
            app.undone.put(id, handler);
            return this;
        }

        /**
         * The {@link #onUndone} twin. A FRONTIER typing episode redoes
         * on the platform's own stack and reports itself as an ordinary
         * edit, so it does not arrive here.
         */
        public WindowRef onRedone(UndoHandler handler) {
            app.redone.put(id, handler);
            return this;
        }

        /** The surface's title (title bar / switcher / task label). */
        public WindowRef title(String title) {
            tx.emit(KayaWire.txSetWindowTitle(id, title));
            return this;
        }

        /** The ADVISORY content-size request in DIP. */
        public WindowRef size(double width, double height) {
            tx.emit(KayaWire.txSetWindowWidth(id, width));
            tx.emit(KayaWire.txSetWindowHeight(id, height));
            return this;
        }

        /** Arms the veto class for the chrome close. */
        public WindowRef vetoClose(boolean on) {
            tx.emit(KayaWire.txSetWindowVetoClose(id, on));
            return this;
        }

        /**
         * Say this surface holds UNSAVED WORK: the backend shows its
         * platform's own affordance — the dot in the close button on
         * macOS, a leading {@code *} in the rendered caption on
         * Windows, a bullet beside the header-bar title on GTK,
         * nothing on the phones, which have none
         * (docs/dirty-plan.md D2/D4).
         *
         * <p>STATE, NOT CHROME, and the title you declared is left
         * alone: there is no marker to compose into it and no
         * placeholder to leave room for (the rejected Qt design). It
         * ARMS NOTHING either — "unsaved changes, close anyway?" is
         * {@link #vetoClose} plus a dialog, which is yours to compose,
         * because apps legitimately differ on what it should do.
         */
        public WindowRef dirty(boolean on) {
            tx.emit(KayaWire.txSetWindowDirty(id, on));
            return this;
        }

        /**
         * The window CONTENT INSET, in layout units — LAYOUT, not
         * appearance (docs/styling-plan.md D3): the space kaya's own
         * interpreters put around the mounted root. 16 unless you say
         * otherwise; 0 is full bleed (a Sublime-shaped editor, a
         * canvas), honored unconditionally because the inset is kaya's
         * own padding.
         *
         * <p>A platform's SAFE AREA is a separate fact and is not
         * removed by it: content extends to the safe-area edge, not
         * past it, so a phone keeps flowing like itself at inset 0.
         *
         * <p>Negative has no reading — an inset is space, not an offset
         * — and the root refuses it.
         */
        public WindowRef inset(double units) {
            tx.emit(KayaWire.txSetWindowInset(id, units));
            return this;
        }

        /**
         * Ask this window to present its ENTRY STACK as list-detail: on a REGULAR window the base root takes the leading pane and the top of the stack the trailing one; on a COMPACT one nothing changes.
         * There is no argument for WHICH way it presents - that is the size class's answer, not the app's.
         */
        public WindowRef listDetail(boolean on) {
            tx.emit(KayaWire.txSetWindowListDetail(id, on));
            return this;
        }

        /** The window's ADVISORY sections hint
         * (KayaWire.SECTIONS_PRESENTATION_AUTO/BAR/SIDEBAR — the
         * width/height precedent; phones ignore it by physics). */
        public WindowRef sectionsPresentation(long hint) {
            tx.emit(KayaWire.txSetWindowSectionsPresentation(id, hint));
            return this;
        }

        /** The window id, for mountIn. */
        public long id() {
            return id;
        }

        /**
         * A top-level menu in this window's command catalog — the
         * menubar rides the window construct (DESIGN.md, Menus):
         * tx.window(0).menu("File") returns the retained grouping
         * handle, whose creators append the children:
         * file.item("Save").shortcut("primary+s").onActivate(fn).
         * Append-at-any-time: reopen the retained handle in a later
         * transaction with tx.menu(file).
         */
        public MenuItem menu(String label) {
            MenuItem m = tx.newMenuItem(KayaWire.MENU_KIND_MENU, label, false);
            tx.emit(KayaWire.txMenubarAppend(id, m.id));
            return m;
        }

        /**
         * A BAR-LEVEL radio group — admissible wherever a menu
         * grouping node is (it materializes as a top-level menu with
         * the platform's checkmark idiom). Declare only option()
         * children; chain value() AFTER them (the Choice contract:
         * the selected 0-based index; programmatic writes are quiet)
         * and onSelect() for each USER pick's new index.
         */
        public MenuItem radioGroup(String label) {
            MenuItem m = tx.newMenuItem(KayaWire.MENU_KIND_RADIO_GROUP, label, false);
            tx.emit(KayaWire.txMenubarAppend(id, m.id));
            return m;
        }
    }

    /**
     * A live menu item: its OWN id space (the c_menu_item counter)
     * behind its own type, so cross-use with widget or node ids is a
     * compile error. The id alone is the item's durable name; the
     * chain methods (props, creators, handlers) ride the transaction
     * that minted the value and die with it — the Widget.grow
     * discipline — and tx.menu(item) reopens a retained handle in a
     * later transaction (append-at-any-time; props mutate freely;
     * nothing is ever removed in v1).
     */
    public static final class MenuItem {
        final long id;
        final Tx tx;
        final KayaApp app;
        // A context-anchored chain: a shortcut needs a window catalog
        // as its native dispatch home, so shortcut() throws here at
        // record time — the root remains the floor beneath.
        final boolean ctx;

        MenuItem(long id, Tx tx, KayaApp app, boolean ctx) {
            this.id = id;
            this.tx = tx;
            this.app = app;
            this.ctx = ctx;
        }

        Tx chain() {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                        "kaya: menu chain outside its transaction — reopen the"
                                + " retained handle with tx.menu inside a live transaction");
            }
            return tx;
        }

        MenuItem child(int kind, String label) {
            MenuItem c = chain().newMenuItem(kind, label, ctx);
            tx.emit(KayaWire.txMenuItemAppend(id, c.id));
            return c;
        }

        /** Appends an action — a leaf command firing exactly one
         * menu_activated occurrence (menu click OR its shortcut: ONE
         * occurrence, one dispatch path). Chain onActivate beside it. */
        public MenuItem item(String label) {
            return child(KayaWire.MENU_KIND_ACTION, label);
        }

        /** Appends a stateful leaf reusing the Checkbox contract: user
         * flips emit menu_toggled (chain onToggle); programmatic
         * checked writes are quiet. */
        public MenuItem toggle(String label) {
            return child(KayaWire.MENU_KIND_TOGGLE, label);
        }

        /** Appends a NESTED menu — grouping, never navigation. One
         * nested grouping level is the cap (root-checked). */
        public MenuItem menu(String label) {
            return child(KayaWire.MENU_KIND_MENU, label);
        }

        /** Appends a NESTED radio group — the Choice contract inline,
         * with the platform's checkmark idiom. Only option children. */
        public MenuItem radioGroup(String label) {
            return child(KayaWire.MENU_KIND_RADIO_GROUP, label);
        }

        /** Appends one labeled option (radio groups only — root
         * checked), in declaration order: the order IS the index
         * vocabulary the group's value selects over. */
        public MenuItem option(String label) {
            return child(KayaWire.MENU_KIND_RADIO_OPTION, label);
        }

        /** Appends native grouping chrome: no label, no props, no
         * handle kept. */
        public void separator() {
            child(KayaWire.MENU_KIND_SEPARATOR, null);
        }

        /** Renames the item to constant text. Label writes never emit
         * anything. */
        public MenuItem label(String text) {
            chain().emit(KayaWire.txSetMenuLabel(id, text));
            return this;
        }

        /** Binds the item's label to a Str signal. */
        public MenuItem label(Signal<String> s) {
            chain().emit(KayaWire.txBindMenuLabel(id, s.id));
            return this;
        }

        /** Whether the item is enabled (default true). Enablement
         * writes never emit anything; disabling a grouping node
         * disables its subtree (the inherited-disabled contract). */
        public MenuItem enabled(boolean on) {
            chain().emit(KayaWire.txSetMenuEnabled(id, on));
            return this;
        }

        /** Binds the item's enablement to a Bool signal. */
        public MenuItem enabled(Signal<Boolean> s) {
            chain().emit(KayaWire.txBindMenuEnabled(id, s.id));
            return this;
        }

        /** A toggle's state (toggle items only — root-checked): the
         * Checkbox contract. The programmatic write is configuration —
         * QUIET, no menu_toggled echo (the echo doctrine). */
        public MenuItem checked(boolean on) {
            chain().emit(KayaWire.txSetMenuChecked(id, on));
            return this;
        }

        /** Binds a toggle's state to a Bool signal, both ways. */
        public MenuItem checked(Signal<Boolean> s) {
            chain().emit(KayaWire.txBindMenuChecked(id, s.id));
            return this;
        }

        /** A radio group's selected option index (radio groups only —
         * root-checked): the Choice contract. QUIET, like checked. */
        public MenuItem value(int index) {
            chain().emit(KayaWire.txSetMenuValue(id, index));
            return this;
        }

        /** Binds a radio group's selected index to a float signal,
         * both ways. */
        public MenuItem value(Signal<Double> s) {
            chain().emit(KayaWire.txBindMenuValue(id, s.id));
            return this;
        }

        /** The item's icon (the blob channel): used by phone
         * promotion, ignored where native menu dress has no icons.
         * Const-only. */
        public MenuItem icon(byte[] data) {
            chain().emit(KayaWire.txSetMenuIcon(id, KayaRing.blobRegister(data)));
            return this;
        }

        /** The phone-bar promotion hint (actions only — root-checked).
         * Flipping it recomputes the promoted set deterministically;
         * INERT on desktops — not a toolbar grammar. Const-only. */
        public MenuItem primary(boolean on) {
            chain().emit(KayaWire.txSetMenuPrimary(id, on));
            return this;
        }

        /** Declares this action a standard command (actions only —
         * root-checked). The declaration is uniform; PLACEMENT is each
         * host's business: macOS shows {@link #ROLE_SETTINGS} in the
         * application menu, everyone else leaves the item where it was
         * declared. One item per role, and a role never invents a
         * chord — spell shortcut() too if the app wants one.
         * Const-only. */
        public MenuItem role(String name) {
            if (ctx) {
                throw new IllegalStateException(
                        "kaya: a context item takes no role — a role names a"
                                + " standard command in the window catalog");
            }
            chain().emit(KayaWire.txSetMenuRole(id, name));
            return this;
        }

        /** The shortcut of any LEAF command — an action, a toggle, or
         * one option of a group (window-anchored only).
         * Canonicalized by the binding's one parser
         * (KayaWire.canonicalizeShortcut); the shortcut is another
         * affordance of the same item — it fires the SAME
         * menu_activated occurrence as a click. Const-only. */
        public MenuItem shortcut(String spelling) {
            if (ctx) {
                throw new IllegalStateException(
                        "kaya: a context item takes no shortcut — a shortcut needs"
                                + " a window catalog as its native dispatch home");
            }
            chain().emit(KayaWire.txSetMenuShortcut(id, spelling));
            return this;
        }

        /** Binds this action's handler — it rides the declaration (no
         * app-global menu dispatcher exists), and the action's click
         * and its shortcut are ONE occurrence on one dispatch path, so
         * it covers both. */
        public MenuItem onActivate(Consumer<Tx> fn) {
            chain();
            app.menuActivated.put(id, fn);
            return this;
        }

        /** The template-node flavor: an item attached to a stamped
         * copy reports the copy's key path, outermost first — the keys
         * ARE the noun the command acts on. */
        public MenuItem onActivateNode(BiConsumer<Tx, List<Object>> fn) {
            chain();
            app.menuActivatedNode.put(id, fn);
            return this;
        }

        /** Binds a toggle's handler: each USER flip's new state.
         * Programmatic checked writes are quiet, so a handler's own
         * writes cannot loop back at it. */
        public MenuItem onToggle(BiConsumer<Tx, Boolean> fn) {
            chain();
            app.menuToggled.put(id, fn);
            return this;
        }

        /** The template-node flavor: the copy's keys, then the state. */
        public MenuItem onToggleNode(ToggleHandler fn) {
            chain();
            app.menuToggledNode.put(id, fn);
            return this;
        }

        /** Binds a radio group's handler (registered on the GROUP):
         * each USER pick's new 0-based option index. Programmatic
         * value writes are quiet. */
        public MenuItem onSelect(BiConsumer<Tx, Integer> fn) {
            chain();
            app.menuSelected.put(id, fn);
            return this;
        }

        /** The template-node flavor: the copy's keys, then the index. */
        public MenuItem onSelectNode(MenuSelectHandler fn) {
            chain();
            app.menuSelectedNode.put(id, fn);
            return this;
        }
    }

    /**
     * A live widget's context anchor (tx.contextMenu): the same item
     * vocabulary as the bar, scoped to a NOUN — each creator attaches
     * another root. No shortcuts here (record-time checked; the
     * editable text controls reject attachment at the root).
     */
    public static final class ContextRef {
        private final Tx tx;
        private final long widget;

        ContextRef(Tx tx, long widget) {
            this.tx = tx;
            this.widget = widget;
        }

        MenuItem root(int kind, String label) {
            MenuItem m = tx.newMenuItem(kind, label, true);
            tx.emit(KayaWire.txContextAttach(widget, m.id));
            return m;
        }

        /** Attaches an action root; chain onActivate beside it. */
        public MenuItem item(String label) {
            return root(KayaWire.MENU_KIND_ACTION, label);
        }

        /** Attaches a toggle root; chain onToggle beside it. */
        public MenuItem toggle(String label) {
            return root(KayaWire.MENU_KIND_TOGGLE, label);
        }

        /** Attaches a grouping root (one nested grouping level — the
         * context depth cap is root-checked). */
        public MenuItem menu(String label) {
            return root(KayaWire.MENU_KIND_MENU, label);
        }

        /** Attaches a radio-group root; declare only option children. */
        public MenuItem radioGroup(String label) {
            return root(KayaWire.MENU_KIND_RADIO_GROUP, label);
        }

        /** Attaches native grouping chrome. */
        public void separator() {
            root(KayaWire.MENU_KIND_SEPARATOR, null);
        }
    }

    /**
     * A context catalog built UNANCHORED (tx.contextCatalog) for a
     * template node: menu items are live and shared across stamped
     * copies, so the catalog is built in the live zone and
     * Tpl.contextMenu attaches it inside the template, where each
     * activation carries the copy's key path. An item takes exactly
     * one anchor — a second attach throws.
     */
    public static final class ContextCatalog {
        private final Tx tx;
        final List<Long> roots = new ArrayList<>();
        boolean attached;

        ContextCatalog(Tx tx) {
            this.tx = tx;
        }

        MenuItem root(int kind, String label) {
            MenuItem m = tx.newMenuItem(kind, label, true);
            roots.add(m.id);
            return m;
        }

        /** Collects an action root; chain onActivateNode beside it. */
        public MenuItem item(String label) {
            return root(KayaWire.MENU_KIND_ACTION, label);
        }

        /** Collects a toggle root; chain onToggleNode beside it. */
        public MenuItem toggle(String label) {
            return root(KayaWire.MENU_KIND_TOGGLE, label);
        }

        /** Collects a grouping root. */
        public MenuItem menu(String label) {
            return root(KayaWire.MENU_KIND_MENU, label);
        }

        /** Collects a radio-group root; chain onSelectNode. */
        public MenuItem radioGroup(String label) {
            return root(KayaWire.MENU_KIND_RADIO_GROUP, label);
        }

        /** Collects native grouping chrome. */
        public void separator() {
            root(KayaWire.MENU_KIND_SEPARATOR, null);
        }
    }

    /** Chains navigation-entry props, the construction-sugar tier:
     * tx.pushEntry(7).title("detail").interceptBack(true). */
    public static final class EntryRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;

        EntryRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** The entry's title — the back affordance's label source. */
        public EntryRef title(String title) {
            tx.emit(KayaWire.txSetEntryTitle(id, title));
            return this;
        }

        /** Arms the close-veto class transplanted to POP: back emits
         * back_requested and nothing pops until popEntry agrees. */
        public EntryRef interceptBack(boolean on) {
            tx.emit(KayaWire.txSetEntryInterceptBack(id, on));
            return this;
        }

        /** Binds the popped handler to THIS entry (per-entry, the
         * request-bound alert precedent — no id inspection anywhere):
         * fires when the user's back affordance pops it natively
         * (post-fact; a programmatic popEntry does not fire it — its
         * caller already knows), retiring with the one pop. */
        public EntryRef onPopped(Consumer<Tx> handler) {
            app.entryPopped.put(id, handler);
            return this;
        }

        /** Binds the back-veto handler to THIS entry: fires per back
         * request while interceptBack is armed — nothing has popped;
         * answer with tx.popEntry to agree. */
        public EntryRef onBackRequested(Consumer<Tx> handler) {
            app.backRequested.put(id, handler);
            return this;
        }

        /** The entry's surface id, for mountIn. */
        public long id() {
            return id;
        }
    }

    /** Chains section props, the construction-sugar tier:
     * tx.addSection(7).title("Feed").onSelected(tx -> …). */
    public static final class SectionRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;

        SectionRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** The switcher item's label — the tab title everywhere. */
        public SectionRef title(String title) {
            tx.emit(KayaWire.txSetSectionTitle(id, title));
            return this;
        }

        /** Binds the selected handler to THIS section (per-section):
         * fires each time the USER switches to it through the
         * platform's switcher — post-fact and NOT one-shot. A
         * programmatic selectSection does not fire it (the echo
         * doctrine). */
        public SectionRef onSelected(Consumer<Tx> handler) {
            app.sectionSelected.put(id, handler);
            return this;
        }

        /** The section's surface id, for mountIn. */
        public long id() {
            return id;
        }
    }

    public static final class Widget {
        final long id;
        final Tx tx;

        Widget(long id, Tx tx) {
            this.id = id;
            this.tx = tx;
        }

        /**
         * Weight this widget within its row/column at construction —
         * the declarative chain. Appends to the transaction that
         * minted the widget, so it belongs in the build body; on a
         * Widget that outlived its build it fails loudly — use
         * Tx.setGrow inside a live transaction for dynamic changes.
         */
        public Widget grow(double weight) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: grow on a widget outside its build transaction"
                    + " — use Tx.setGrow inside a live transaction");
            }
            tx.setGrow(this, weight);
            return this;
        }

        /**
         * This container's inter-child gap at construction — the
         * declarative chain: tx.column(() -> {...}).spacing(12).
         * Same transaction discipline as grow.
         */
        public Widget spacing(double gap) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: spacing on a widget outside its build transaction"
                    + " — use Tx.setSpacing inside a live transaction");
            }
            tx.setSpacing(this, gap);
            return this;
        }

        /**
         * This container's cross-axis child placement at construction
         * — the declarative chain:
         * tx.row(() -> {...}).align(Align.BASELINE). Same transaction
         * discipline as grow.
         */
        public Widget align(Align align) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: align on a widget outside its build transaction"
                    + " — use Tx.setAlign inside a live transaction");
            }
            tx.setAlign(this, align);
            return this;
        }

        /**
         * This widget's SEMANTIC EMPHASIS at construction — the
         * declarative chain:
         * tx.button("Delete").role(Role.DESTRUCTIVE). Same transaction
         * discipline as grow.
         *
         * <p>What the widget MEANS, never how it looks: destructive and
         * prominent are button emphasis, heading is label hierarchy,
         * and the root refuses a role on a kind it does not fit — at
         * declare time, in one sentence naming both sides.
         */
        public Widget role(Role role) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: role on a widget outside its build transaction"
                    + " — use Tx.setRole inside a live transaction");
            }
            tx.setRole(this, role);
            return this;
        }

        /**
         * This widget's accessibility identifier at construction — the
         * declarative chain: tx.entry().a11yId("name"). Same
         * transaction discipline as grow.
         */
        public Widget a11yId(String id) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: a11yId on a widget outside its build transaction"
                    + " — use Tx.setA11yId inside a live transaction");
            }
            tx.setA11yId(this, id);
            return this;
        }

        /**
         * This widget's spoken accessibility label at construction —
         * the declarative chain:
         * tx.entry().a11yId("name").a11yLabel("Full name"). Same
         * transaction discipline as grow.
         */
        public Widget a11yHint(String hint) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: a11yHint on a widget outside its build transaction"
                    + " — use Tx.setA11yHint inside a live transaction");
            }
            tx.setA11yHint(this, hint);
            return this;
        }

        /** Declare what this widget takes from a paste — the closed
         * kinds by name ("text", "html", "image", "files") plus any
         * custom format ids.
         *
         * <p>ONE DECLARATION, THREE JOBS: it drives whether the Paste
         * command is live while this widget is focused, it filters what
         * can reach the paste hook, and on Android it IS the native
         * registration (setOnReceiveContentListener takes the mime
         * types on the view). Per-widget because whether Paste should
         * be enabled is the INTERSECTION of what the clipboard offers
         * and what the FOCUSED target takes.
         *
         * <p>DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget
         * that declares nothing gets the platform's own insertion and
         * reports it through the ordinary change path, which is why a
         * plain text editor writes none of this and has working cut,
         * copy and paste. */
        public Widget accepts(String... kinds) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: accepts on a widget outside its build transaction"
                    + " — use Tx.setAccepts inside a live transaction");
            }
            tx.setAccepts(this, kinds);
            return this;
        }

        public Widget a11yLabel(String label) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: a11yLabel on a widget outside its build transaction"
                    + " — use Tx.setA11yLabel inside a live transaction");
            }
            tx.setA11yLabel(this, label);
            return this;
        }
    }

    /**
     * A half-open range of a text widget's content, in KAYA'S UNIT:
     * UTF-8 byte offsets into the widget's current text.
     *
     * <p>A TYPE RATHER THAN TWO INTS, because Java's own unit is not
     * kaya's and the two are indistinguishable as bare numbers.
     * {@code String.indexOf}, {@code length()} and {@code substring}
     * all count UTF-16 code units; the wire counts UTF-8 bytes, which
     * is what every binding sends and what the core validates and
     * converts before a backend sees it (scratchpad/ranges-units.md).
     * For ASCII the two agree, which is exactly why an unconverted
     * index ships: one CJK word earlier in the document and every
     * offset is three bytes per character short. The conformance
     * scene's document opens with one for that reason — its matches sit
     * at bytes 57, 203 and 753 where {@code indexOf} answers 51, 197
     * and 747.
     *
     * <p>So the two factories NAME THE UNIT and there is no third way
     * to make one: {@link #in} converts from Java's index, {@link
     * #ofBytes} takes kaya's directly (an app whose model is already
     * byte-addressed — a rope, a memory-mapped file, a language server
     * — has them and should not pay to convert twice).
     */
    public static final class TextRange {
        /** Start offset, in UTF-8 bytes, inclusive. */
        public final long start;

        /** End offset, in UTF-8 bytes, exclusive. */
        public final long stop;

        private TextRange(long start, long stop) {
            this.start = start;
            this.stop = stop;
        }

        /**
         * A range from offsets that are ALREADY UTF-8 byte offsets
         * into the widget's text.
         *
         * <p>The endpoints are checked against each other here and
         * against the text itself in the core, which is the only place
         * that holds it: an offset past the end, or one that splits a
         * character, is refused there by name (a malformed offset
         * reaching a backend is not a wrong colour — on macOS an
         * out-of-range text attribute aborts the process).
         */
        public static TextRange ofBytes(long start, long stop) {
            if (start < 0) {
                throw new IllegalArgumentException(
                        "kaya: text range start " + start + " is negative");
            }
            if (start > stop) {
                throw new IllegalArgumentException(
                        "kaya: text range start " + start + " is after stop " + stop);
            }
            return new TextRange(start, stop);
        }

        /**
         * A range from JAVA'S OWN INDICES — UTF-16 code-unit offsets
         * into {@code text}, the kind {@code indexOf} returns and
         * {@code substring} takes — converted once against that text:
         *
         * <pre>{@code
         * int at = doc.indexOf(needle);
         * tx.selectRange(editor, TextRange.in(doc, at, at + needle.length()));
         * }</pre>
         *
         * <p>{@code text} MUST BE THE WIDGET'S CURRENT TEXT, because a
         * byte offset only means anything against the string it was
         * measured on. That is the app's own document — the fold its
         * change handler already keeps — and not a widget read: kaya
         * has none.
         */
        public static TextRange in(String text, int startIndex, int stopIndex) {
            if (startIndex > stopIndex) {
                throw new IllegalArgumentException(
                        "kaya: text range start index " + startIndex
                        + " is after stop index " + stopIndex);
            }
            return new TextRange(byteOffset(text, startIndex), byteOffset(text, stopIndex));
        }

        /**
         * Java's index into kaya's: the UTF-8 byte offset of the
         * character at UTF-16 index {@code index} of {@code text}.
         *
         * <p>REFUSES AN INDEX THAT SPLITS A SURROGATE PAIR, which is
         * the one way a Java app can hand out a byte offset that is
         * silently wrong. For the string {@code ab} U+1F600 {@code cd},
         * {@code substring(0, 3)} keeps a lone high surrogate, and
         * encoding that to UTF-8 yields the single byte {@code 0x3F} —
         * a literal {@code ?} —
         * so the offset comes back 2 instead of 5 and every later
         * offset in the document is short by three (measured against
         * .NET, which substitutes U+FFFD instead and is wrong by a
         * different amount: scratchpad/ranges-units.md §4). Neither
         * runtime raises anything. An index inside a pair is not a
         * position in the text, so it is refused here rather than
         * converted into a plausible number.
         *
         * <p>Costs one encode of the prefix, and it is deliberately
         * THE SAME ENCODE the wire performs on the text itself
         * ({@code getBytes(UTF_8)}), so the two cannot disagree.
         */
        public static long byteOffset(String text, int index) {
            if (index < 0 || index > text.length()) {
                throw new IndexOutOfBoundsException(
                        "kaya: index " + index + " is outside the text (" + text.length()
                        + " UTF-16 code units)");
            }
            if (index > 0 && index < text.length()
                    && Character.isHighSurrogate(text.charAt(index - 1))
                    && Character.isLowSurrogate(text.charAt(index))) {
                throw new IllegalArgumentException(
                        "kaya: index " + index + " splits the surrogate pair for U+"
                        + Integer.toHexString(text.codePointAt(index - 1)).toUpperCase()
                        + " — it is inside a character, not between two");
            }
            return text.substring(0, index).getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
        }

        /**
         * Kaya's index into Java's: the UTF-16 index of the character
         * at UTF-8 byte offset {@code offset} of {@code text}, so an
         * app holding kaya's offsets can slice its own String with
         * them — {@code text.substring(charIndex(text, r.start),
         * charIndex(text, r.stop))}. The inverse of {@link
         * #byteOffset}, and the direction an app needs when the
         * offsets came from something byte-addressed (a grep, a
         * language server) rather than from its own search.
         *
         * <p>An offset inside a character is refused, in the same
         * words the core uses: it is not a position in the text.
         */
        public static int charIndex(String text, long offset) {
            long at = 0;
            int i = 0;
            while (i < text.length()) {
                if (at == offset) {
                    return i;
                }
                int cp = text.codePointAt(i);
                at += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
                if (at > offset) {
                    throw new IllegalArgumentException(
                            "kaya: byte offset " + offset + " is not a character boundary; it is"
                            + " inside U+" + Integer.toHexString(cp).toUpperCase());
                }
                i += Character.charCount(cp);
            }
            if (at == offset) {
                return i;
            }
            throw new IndexOutOfBoundsException(
                    "kaya: byte offset " + offset + " is past the end of the text (" + at
                    + " bytes)");
        }

        /** {@code start:stop} in kaya's unit — the spelling the scene
         * scripts assert in, so a debug print and a failure message read
         * alike. */
        @Override
        public String toString() {
            return start + ":" + stop;
        }
    }

    /**
     * A template node: a blueprint entry, stamped per collection entry.
     * Never on screen by itself; clicks on its copies arrive with the
     * copy's key path.
     */
    public static final class Node {
        final long id;

        Node(long id) {
            this.id = id;
        }
    }

    /**
     * A collection instance handle: the collection plus the key path
     * selecting one stamped copy's table. Tx.collection() returns the
     * root (empty-path, live-zone) handle; at() steps into a copy, one
     * key per enclosing For. Mutations and reads take the handle, so
     * the target is spelled once.
     */
    public static final class Collection {
        final long id;
        final List<Object> path;

        Collection(long id, List<Object> path) {
            this.id = id;
            this.path = path;
        }

        /**
         * The instance of this collection inside the copy keyed by
         * {@code key} of the next enclosing For; chain for deeper
         * nesting.
         */
        public Collection at(Object key) {
            List<Object> deeper = new ArrayList<>(path);
            deeper.add(key);
            return new Collection(id, deeper);
        }

        // A For binds the collection itself — its template stamps per
        // entry of every instance — so handing it an at(...) handle is
        // a bug.
        void assertRoot() {
            if (!path.isEmpty()) {
                throw new IllegalArgumentException(
                        "kaya: forEach binds the collection itself, not an instance"
                                + " — drop the at(...)");
            }
        }

        /**
         * The for-each form over a scalar collection: {@code for (var
         * row : items.rows())} traces the For template — the body runs
         * once over the scalar row surface, a break is caught at
         * submit, and the trace rides the zone it opens in, so
         * statement traces nest (the record twin is the generated
         * {@code <Type>Kaya.rows}; the Go {@code Collection.Rows}
         * twin).
         */
        public Iterable<Row> rows() {
            Collection c = this;
            return () -> new java.util.Iterator<Row>() {
                int state;
                RowTrace trace;

                @Override
                public boolean hasNext() {
                    if (state == 0) {
                        return true;
                    }
                    if (state == 1) {
                        state = 2;
                        trace.close();
                    }
                    return false;
                }

                @Override
                public Row next() {
                    if (state != 0) {
                        throw new java.util.NoSuchElementException();
                    }
                    state = 1;
                    KayaApp app = KayaApp.ambient;
                    if (app == null || app.currentTx == null) {
                        throw new IllegalStateException(
                                "kaya: rows() iterates at record time, inside a transaction");
                    }
                    trace = app.currentTx.beginRowTrace(c);
                    return new Row(trace.tpl);
                }
            };
        }
    }

    /**
     * The for-STATEMENT façade over the template zone: everything
     * {@link Tpl} constructs, on the surface a {@code for (var row : …)}
     * body holds. Subclasses add the row's TOKENS and nothing else —
     * {@link Row} the scalar element's, the generated
     * {@code <Type>Kaya.Row} one per record component.
     *
     * <p>ONE FORWARDING LIST, WHICH IS THE POINT. The zone had three
     * surfaces in Java and each hand-listed its own subset: Tpl had
     * label/button/checkbox/image, this façade had label/button and no
     * image, the generated one had image/checkbox and no button. A
     * constructor on one and not another is reachable through
     * {@code tx.forEach} and not through {@code for (var row : …)},
     * which is a difference no guest should have to know about, and
     * three lists cannot be held level by anyone remembering to. So
     * the forwards live here once and both façades inherit them; the
     * annotation processor emits tokens and typed handlers, never a
     * constructor list.
     *
     * <p>Handlers register the way they do everywhere in this zone —
     * {@code app.onClick(node, (tx, keys) -> …)} and its siblings —
     * because a stamped copy's event names the copy: the keys ARE the
     * noun.
     */
    public abstract static class RowSurface {
        private final Tpl t;

        // Protected, not package-private: the generated row surfaces
        // extend this from the GUEST's package.
        protected RowSurface(Tpl t) {
            this.t = t;
        }

        /** The blueprint this row records into, for the generated
         * subclass's typed routes. A method rather than a protected
         * field: a record component named {@code tpl} would SHADOW the
         * field and change what the generated code means, while a field
         * and a method of one name coexist. */
        protected final Tpl tpl() {
            return t;
        }

        public Node label(String text) {
            return t.label(text);
        }

        public Node label(Signal<String> s) {
            return t.label(s);
        }

        public Node label(KayaRecords.Field<String> f) {
            return t.label(f);
        }

        public Node button(String text) {
            return t.button(text);
        }

        public Node button(Signal<String> s) {
            return t.button(s);
        }

        public Node button(KayaRecords.Field<String> f) {
            return t.button(f);
        }

        public Node checkbox(boolean checked) {
            return t.checkbox(checked);
        }

        public Node checkbox(Signal<Boolean> s) {
            return t.checkbox(s);
        }

        public Node checkbox(KayaRecords.Field<Boolean> f) {
            return t.checkbox(f);
        }

        public Node image(byte[] source) {
            return t.image(source);
        }

        public Node image(Signal<byte[]> s) {
            return t.image(s);
        }

        public Node image(KayaRecords.Field<byte[]> f) {
            return t.image(f);
        }

        public Node entry() {
            return t.entry();
        }

        public Node entry(String text) {
            return t.entry(text);
        }

        public Node entry(Signal<String> s) {
            return t.entry(s);
        }

        public Node entry(KayaRecords.Field<String> f) {
            return t.entry(f);
        }

        public Node textarea() {
            return t.textarea();
        }

        public Node textarea(String text) {
            return t.textarea(text);
        }

        public Node textarea(Signal<String> s) {
            return t.textarea(s);
        }

        public Node textarea(KayaRecords.Field<String> f) {
            return t.textarea(f);
        }

        public Node row(Runnable body) {
            return t.row(body);
        }

        public Node column(Runnable body) {
            return t.column(body);
        }

        public Node scroll(Runnable body) {
            return t.scroll(body);
        }

        public Node grid(int columns, Runnable body) {
            return t.grid(columns, body);
        }

        public Node spacer() {
            return t.spacer();
        }

        public Node progress(double value) {
            return t.progress(value);
        }

        public Node progress(Signal<Double> s) {
            return t.progress(s);
        }

        public Node progress(KayaRecords.Field<Double> f) {
            return t.progress(f);
        }

        public Node progressIndeterminate() {
            return t.progressIndeterminate();
        }

        public Node slider(double min, double max, double value) {
            return t.slider(min, max, value);
        }

        public Node slider(double min, double max, Signal<Double> value) {
            return t.slider(min, max, value);
        }

        public Node slider(double min, double max, KayaRecords.Field<Double> value) {
            return t.slider(min, max, value);
        }

        public Node select(String[] options, int selected) {
            return t.select(options, selected);
        }

        public Node select(String[] options, Signal<Double> selected) {
            return t.select(options, selected);
        }

        public Node select(String[] options, KayaRecords.Field<Double> selected) {
            return t.select(options, selected);
        }

        public Node radio(String[] options, int selected) {
            return t.radio(options, selected);
        }

        public Node radio(String[] options, Signal<Double> selected) {
            return t.radio(options, selected);
        }

        public Node radio(String[] options, KayaRecords.Field<Double> selected) {
            return t.radio(options, selected);
        }

        /** One of this row's nodes' flex weight — a Node carries no
         * transaction, so a setter after construction is the spelling
         * rather than a chain ({@link Tpl#setGrow}). */
        public void setGrow(Node n, double weight) {
            t.setGrow(n, weight);
        }

        /** One of this row's nodes' accessibility identifier
         * ({@link Tpl#setA11yId(Node, String)}). */
        public void setA11yId(Node n, String id) {
            t.setA11yId(n, id);
        }

        public void setA11yId(Node n, Signal<String> s) {
            t.setA11yId(n, s);
        }

        public void setA11yId(Node n, KayaRecords.Field<String> f) {
            t.setA11yId(n, f);
        }

        public void bindA11yIdField(Node n, int level, KayaRecords.Field<String> f) {
            t.bindA11yIdField(n, level, f);
        }

        /** What an assistive client speaks for this row's copy of that
         * node ({@link Tpl#setA11yLabel(Node, KayaRecords.Field)} is the
         * overload this surface exists for: the row's own field). */
        public void setA11yLabel(Node n, String label) {
            t.setA11yLabel(n, label);
        }

        public void setA11yLabel(Node n, Signal<String> s) {
            t.setA11yLabel(n, s);
        }

        public void setA11yLabel(Node n, KayaRecords.Field<String> f) {
            t.setA11yLabel(n, f);
        }

        public void bindA11yLabelField(Node n, int level, KayaRecords.Field<String> f) {
            t.bindA11yLabelField(n, level, f);
        }

        /** What activating this row's copy of that node does —
         * activation kinds only ({@link Tpl#setA11yHint(Node, String)}). */
        public void setA11yHint(Node n, String hint) {
            t.setA11yHint(n, hint);
        }

        public void setA11yHint(Node n, Signal<String> s) {
            t.setA11yHint(n, s);
        }

        public void setA11yHint(Node n, KayaRecords.Field<String> f) {
            t.setA11yHint(n, f);
        }

        public void bindA11yHintField(Node n, int level, KayaRecords.Field<String> f) {
            t.bindA11yHintField(n, level, f);
        }

        /** What this row's copy of that node takes from a paste, and the
         * half {@link KayaApp#onPaste(Node, PasteHandler)} needs to fire
         * at all ({@link Tpl#setAccepts}). */
        public void setAccepts(Node n, String... kinds) {
            t.setAccepts(n, kinds);
        }

        /** A collection declared inside this row's template — the
         * nested-instance shape. */
        public Collection collection() {
            return t.collection();
        }

        /** Attach a live-built context catalog to one of this row's
         * template nodes; each activation carries the stamped copy's
         * key path. */
        public void contextMenu(Node n, ContextCatalog catalog) {
            t.contextMenu(n, catalog);
        }
    }

    /**
     * The scalar-collection row surface a rows() trace yields: the
     * template vocabulary plus the element's own token — a scalar
     * collection has exactly one field, the element itself, and
     * value() is that token (the record twin mints one token per
     * record component).
     */
    public static final class Row extends RowSurface {
        Row(Tpl t) {
            super(t);
        }

        /** The element's token: what a stamped copy's bindings read. */
        public KayaRecords.Field<String> value() {
            return KayaRecords.fieldAt(0);
        }
    }

    /**
     * A stamped template: the For/When handle in the enclosing zone
     * plus whatever the body chose to return — the way handles declared
     * inside the template (nested collections, buttons) reach the
     * handlers, since Java lambdas cannot assign captured locals.
     */
    /** An open generated row trace: the Tpl the loop body records
     * against, and the close that ends the template. */
    public static final class RowTrace {
        public final Tpl tpl;
        private final Runnable close;

        RowTrace(Tpl tpl, Runnable close) {
            this.tpl = tpl;
            this.close = close;
        }

        public void close() {
            close.run();
        }
    }

    public static final class Stamped<H, R> {
        public final H handle;
        public final R out;

        Stamped(H handle, R out) {
            this.handle = handle;
            this.out = out;
        }
    }

    /**
     * One transaction: everything queued inside build (or a handler)
     * applies atomically when it returns.
     */
    public final class Tx {
        /**
         * Set when the enclosing build finishes with this transaction,
         * committed or rolled back: a construction chain
         * (Widget.grow) on a widget that outlived its build must die
         * loudly, not append into an orphaned record list.
         */
        boolean closed;

        private final List<byte[]> records = new ArrayList<>();

        /**
         * THE ONE CHOKEPOINT: the only place that appends to a
         * transaction. Every constructor, setter and chain method goes
         * through it so the liveness check cannot be forgotten at a new
         * callsite. The check used to live on the chain methods only,
         * so a write through a Tx that had outlived its build appended
         * into a list already submitted and never submitted again — no
         * exception, no error, the write simply vanished.
         *
         * <p>Nothing invited that mistake until {@code post} arrived.
         * Posting is exactly the reason a guest now holds a Tx near a
         * background thread, so the guard has to be total.
         */
        private void emit(byte[] record) {
            alive();
            records.add(record);
        }

        /**
         * The head-of-batch undo marker, or null. Held apart from
         * {@code records} rather than inserted at index 0, for two
         * reasons that agree: the wire's rule is that the marker LEADS
         * the batch while the call may sit anywhere in the chain, and
         * {@link #emit} is the one and only append (a second
         * {@code records.add} would be a write that skipped the
         * liveness check — see tools/check-tx-liveness.sh). Prepended by
         * {@link #submitIfAny}.
         */
        private byte[] undoGroup;

        /**
         * Make this transaction ONE undoable step, under {@code label}.
         *
         * <p>The unit of undo is a NAMED GROUP declared at the opener,
         * not every transaction: handlers fire per-gesture transactions
         * constantly and most of them are consequences rather than
         * intents, and a per-keystroke editor would earn one step per
         * character — the exact problem grouping exists to solve. So a
         * group is opt-in, which is also what keeps a collaborative app
         * free to own its own history (docs/undo-plan.md D2, D8).
         *
         * <p>CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides
         * at the head: a handler naturally builds first and names the
         * step when it knows what the step was, and the wire's
         * head-of-batch rule should not turn that into a footgun.
         *
         * <p>WHAT A GROUP MAY HOLD is the reactive half — signal writes
         * and collection deltas, whose inverse the core derives from
         * state it already keeps. Focus is permitted and not restored.
         * Anything else (a const property write, creating a widget,
         * clear, showing a dialog) fails at apply, naming the op: undo
         * restores state, and state is signals plus collections. The app
         * hears the result through {@link WindowRef#onUndone}.
         */
        public void undoable(String label) {
            undoableIn(0, label);
        }

        /**
         * {@link #undoable} against an auxiliary window's ledger. Each
         * window has its own history, because Undo in one window has
         * never meant "revert what happened in another".
         */
        public void undoableIn(long window, String label) {
            alive();
            if (undoGroup != null) {
                throw new IllegalStateException(
                        "kaya: this transaction is already an undo group — one name per step");
            }
            undoGroup = KayaWire.txUndoGroup(window, label);
        }

        /**
         * A Tx is valid ONLY inside the build or handler that made it,
         * on the app thread. To mutate from anywhere else, post.
         */
        void alive() {
            if (closed) {
                throw new IllegalStateException(
                        "kaya: transaction is over — a Tx is only usable inside the build or "
                                + "handler that created it; to mutate from a background thread "
                                + "use App.post");
            }
        }

        // How to undo this transaction's model edits: a snapshot per
        // touched collection, taken on first touch.
        private final Map<Long, List<Instance>> journal = new HashMap<>();

        // Deriveds registered in this transaction: promoted to the app
        // registry on submit, abandoned with a rolled-back Tx (their
        // signals were never created).
        private final List<Map.Entry<Long, Consumer<Tx>>> pendingDerived = new ArrayList<>();

        void registerDerived(long coll, Consumer<Tx> recompute) {
            pendingDerived.add(Map.entry(coll, recompute));
        }

        /** How an undo's wire fields become this collection's model
         * value; see {@link KayaApp#absorbUndo}. Registered at
         * declaration, unconditionally — collection ids are never
         * reused, so a rolled-back build leaves a decoder nothing can
         * name. */
        void registerRebuild(
                long coll, java.util.function.BiFunction<Integer, List<Object>, Object> decoder) {
            rebuild.put(coll, decoder);
        }

        /** Every derived signal rooted at this collection, recomputed
         * and written into this transaction. Deriveds hang off root
         * handles, so nested-instance mutations cannot change their
         * input. */
        private void recomputeDerived(Collection c) {
            if (!c.path.isEmpty()) {
                return;
            }
            for (Consumer<Tx> recompute : derived.getOrDefault(c.id, java.util.Collections.emptyList())) {
                recompute.accept(this);
            }
            for (Map.Entry<Long, Consumer<Tx>> entry : pendingDerived) {
                if (entry.getKey() == c.id) {
                    entry.getValue().accept(this);
                }
            }
        }

        void submitIfAny() {
            if (openTraces != 0) {
                openTraces = 0;
                // The open trace also left the template-scope counter
                // armed; a stuck counter would poison later reads.
                tplDepth = 0;
                throw new IllegalStateException(
                        "kaya: a for-each over rows was exited early (break?)"
                                + " — the template never closed");
            }
            for (Map.Entry<Long, Consumer<Tx>> entry : pendingDerived) {
                derived.computeIfAbsent(entry.getKey(), k -> new ArrayList<>()).add(entry.getValue());
            }
            pendingDerived.clear();
            if (undoGroup != null) {
                // THE MARKER LEADS THE BATCH. A transaction is a bare
                // list with no header, so per-transaction metadata has
                // nowhere else to live and head-of-batch is the one
                // position that cannot be ambiguous — the core refuses
                // it anywhere else.
                byte[][] batch = new byte[records.size() + 1][];
                batch[0] = undoGroup;
                for (int i = 0; i < records.size(); i++) {
                    batch[i + 1] = records.get(i);
                }
                KayaRing.submit(KayaWire.tx(batch));
                return;
            }
            if (!records.isEmpty()) {
                KayaRing.submit(KayaWire.tx(records.toArray(new byte[0][])));
            }
        }

        void rollback() {
            openTraces = 0;
            // App state, not tx state: an aborted build is abandoned
            // but the app continues, and a stuck counter would poison
            // every later mirror read.
            tplDepth = 0;
            parents.clear();
            model.putAll(journal);
        }

        private void touch(long coll) {
            if (journal.containsKey(coll)) {
                return;
            }
            List<Instance> snapshot = new ArrayList<>();
            for (Instance instance : model.getOrDefault(coll, java.util.Collections.emptyList())) {
                snapshot.add(instance.copy());
            }
            journal.put(coll, snapshot);
        }

        private void modelSet(long coll, List<Object> path, Object key, Object value) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            if (instance == null) {
                instance = new Instance(path);
                model.computeIfAbsent(coll, k -> new ArrayList<>()).add(instance);
            }
            for (int i = 0; i < instance.entries.size(); i++) {
                if (java.util.Objects.equals(instance.entries.get(i).key, key)) {
                    instance.entries.set(i, new Entry(key, value));
                    return;
                }
            }
            instance.entries.add(new Entry(key, value));
        }

        private void modelRemove(long coll, List<Object> path, Object key) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            if (instance != null) {
                instance.entries.removeIf(e -> java.util.Objects.equals(e.key, key));
            }
            // The core tears down the copy, taking descendant collection
            // instances with it; the model follows.
            List<Object> prefix = new ArrayList<>(path);
            prefix.add(key);
            purgeChildren(coll, prefix);
        }

        private void modelMove(long coll, List<Object> path, Object key, Object[] before) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            // The same checks the scene makes, made where the guest
            // can see the stack: a missing key or anchor is a guest
            // bug, never a fallback. Both validated before anything
            // mutates.
            int pos = -1;
            if (instance != null) {
                for (int i = 0; i < instance.entries.size(); i++) {
                    if (java.util.Objects.equals(instance.entries.get(i).key, key)) {
                        pos = i;
                        break;
                    }
                }
            }
            if (pos < 0) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            if (before.length > 0) {
                boolean found = false;
                for (Entry entry : instance.entries) {
                    if (java.util.Objects.equals(entry.key, before[0])) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    throw new IllegalStateException("kaya: move before missing key " + before[0]);
                }
            }
            Entry entry = instance.entries.remove(pos);
            int at = instance.entries.size();
            if (before.length > 0) {
                for (int i = 0; i < instance.entries.size(); i++) {
                    if (java.util.Objects.equals(instance.entries.get(i).key, before[0])) {
                        at = i;
                        break;
                    }
                }
            }
            instance.entries.add(at, entry);
        }

        private List<Object> keysOf(Collection c) {
            List<Object> keys = new ArrayList<>();
            Instance instance = instanceOf(c.id, c.path);
            if (instance != null) {
                for (Entry entry : instance.entries) {
                    keys.add(entry.key);
                }
            }
            return keys;
        }

        private void purgeChildren(long coll, List<Object> prefix) {
            for (long kid : childCollections.getOrDefault(coll, java.util.Collections.emptyList())) {
                touch(kid);
                List<Instance> instances = model.get(kid);
                if (instances != null) {
                    instances.removeIf(i -> i.path.size() >= prefix.size()
                            && i.path.subList(0, prefix.size()).equals(prefix));
                }
                purgeChildren(kid, prefix);
            }
        }

        public <V> Signal<V> signal(V initial) {
            Signal s = new Signal<>(++signals);
            emit(KayaWire.txCreateSignal(s.id, initial));
            return s;
        }

        public <V> void write(Signal<V> s, V value) {
            emit(KayaWire.txWriteSignal(s.id, value));
        }

        public Widget widget(int kind) {
            Widget w = new Widget(++widgets, this);
            emit(KayaWire.txCreateWidget(w.id, kind));
            autoParent(w.id);
            return w;
        }

        // The current ambient parent (0 when the scope roots itself:
        // template bodies, or no open container).
        long currentParent() {
            return parents.isEmpty() ? 0 : parents.get(parents.size() - 1);
        }

        void autoParent(long id) {
            long p = currentParent();
            if (p != 0) {
                emit(KayaWire.txAddChild(p, id));
            }
        }

        /**
         * A widget's text: a label's caption, a button's title, and —
         * on the uncontrolled text widgets — the "open a document into
         * the editor" write.
         *
         * <p>ONE WRITE, NOT A BINDING. On an entry or a textarea the
         * app is not pinning the field to a value it will keep pushing;
         * it performs this write and hands the text back to the user,
         * who owns it from that moment. The field answers with its
         * ordinary change occurrence and the app's fold takes it from
         * there — the same round trip a keystroke makes.
         *
         * <p>A write that CHANGES the text also drops whatever the app
         * had declared over it (see {@link #highlightRanges}: ranges
         * are bound to the text they were declared against), and it
         * spends the field's native undo history.
         */
        public void setText(Widget w, String text) {
            emit(KayaWire.txSetText(w.id, text));
        }

        public void setChecked(Widget w, boolean checked) {
            emit(KayaWire.txSetChecked(w.id, checked));
        }

        /**
         * Set a widget's flex weight within its row/column: 0 is
         * natural size, positive weights divide the container's
         * leftover main-axis space in proportion (see Prop::Grow in
         * the core). Java has no named or optional arguments, so the
         * setter directly after construction is both the declarative
         * spelling and the dynamic path.
         */
        public void setGrow(Widget w, double weight) {
            emit(KayaWire.txSetGrow(w.id, weight));
        }

        /**
         * A container's inter-child gap (main axis, DIP; the
         * normalized default is 8). Containers only — the scene
         * rejects it anywhere else.
         */
        public void setSpacing(Widget w, double gap) {
            emit(KayaWire.txSetSpacing(w.id, gap));
        }

        /**
         * A container's cross-axis child placement. Containers only;
         * baseline is rows-only — the scene rejects misuse at the
         * root.
         */
        public void setAlign(Widget w, Align align) {
            emit(KayaWire.txSetAlign(w.id, align.wire));
        }

        /**
         * A widget's semantic emphasis (docs/styling-plan.md D4): what
         * it MEANS, which the platform spells in its own chrome. The
         * dynamic path; the declarative spelling is the role chain at
         * construction. Each variant fits one kind — the root refuses
         * the misfits, naming both sides.
         */
        public void setRole(Widget w, Role role) {
            emit(KayaWire.txSetRole(w.id, role.wire));
        }

        /**
         * A widget's accessibility IDENTIFIER: a stable authored key
         * that assistive tooling and UI automation address it by, and
         * which is NEVER spoken. Universal — every kind carries one.
         * The dynamic path; the declarative spelling is the a11yId
         * chain at construction.
         */
        public void setA11yId(Widget w, String id) {
            emit(KayaWire.txSetA11yId(w.id, id));
        }

        /**
         * What an assistive client SPEAKS for a widget. Universal, and
         * deliberately separate from the identifier — an automation key
         * is not a spoken name. Leave it unset to keep whatever the
         * platform derives from the control's own content; setting it
         * OVERRIDES that, so a button whose caption already reads well
         * needs nothing here.
         */
        public void setA11yLabel(Widget w, String label) {
            emit(KayaWire.txSetA11yLabel(w.id, label));
        }

        /**
         * What ACTIVATING this widget does — the platforms' hint (Apple
         * defines it as the result of performing an action; Android
         * carries it as the click action's label). Write a VERB PHRASE.
         * Activation kinds only; the root rejects it elsewhere.
         */
        public void setA11yHint(Widget w, String hint) {
            emit(KayaWire.txSetA11yHint(w.id, hint));
        }

        public void bindChecked(Widget w, Signal<Boolean> s) {
            emit(KayaWire.txBindChecked(w.id, s.id));
        }

        public void bindText(Widget w, Signal<String> s) {
            emit(KayaWire.txBindText(w.id, s.id));
        }

        /**
         * Point an image at encoded bytes (PNG, JPEG, ...): registers
         * them with the core now — one copy into core memory; the u64
         * handle is consumed by this transaction's submit, so the
         * caller's array is free to change the moment this returns.
         * Handles are single-submit: setting again re-registers.
         */
        public void setSource(Widget w, byte[] source) {
            emit(KayaWire.txSetSource(w.id, KayaRing.blobRegister(source)));
        }

        public void bindSource(Widget w, Signal<byte[]> s) {
            emit(KayaWire.txBindSource(w.id, s.id));
        }

        // Construction sugar: containers take their body as a
        // Runnable and parent everything declared inside it (the
        // ambient stack); the common constructors carry their
        // essential prop, so the build body reads as the tree.
        // Statement position is the point: a for-each over a generated
        // row trace stands between siblings. Handler registration
        // stays explicit (app.onClick), the Java idiom.
        public Widget column(Runnable body) {
            return containerOf(KayaWire.KIND_COLUMN, body);
        }

        public Widget row(Runnable body) {
            return containerOf(KayaWire.KIND_ROW, body);
        }

        /** A vertical scroll viewport over EXACTLY ONE child (declare
         * it in the body; the scene rejects a second). Chain .grow(1)
         * so the enclosing track CONSTRAINS it — an unconstrained
         * viewport hugs its content and nothing overflows. */
        public Widget scroll(Runnable body) {
            return containerOf(KayaWire.KIND_SCROLL, body);
        }

        /** A grid laying its children out row-major into columns
         * columns — each column takes its NATURAL width, aligned
         * across rows (the thing nested rows cannot express). */
        public Widget grid(int columns, Runnable body) {
            Widget parent = widget(KayaWire.KIND_GRID);
            emit(KayaWire.txSetColumns(parent.id, columns));
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        /** A spacer: PURE SUGAR for an empty grown column — it
         * consumes the leftover main-axis space between its
         * siblings. */
        public Widget spacer() {
            Widget w = widget(KayaWire.KIND_COLUMN);
            emit(KayaWire.txSetGrow(w.id, 1.0));
            return w;
        }

        private Widget containerOf(int kind, Runnable body) {
            Widget parent = widget(kind);
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        /** A button with its caption. */
        public Widget button(String text) {
            Widget w = widget(KayaWire.KIND_BUTTON);
            setText(w, text);
            return w;
        }

        /** A button with its caption and click handler — the Swing
         * JButton(Action) shape. */
        public Widget button(String text, Consumer<Tx> onClick) {
            Widget w = button(text);
            KayaApp.this.onClick(w, onClick);
            return w;
        }

        /** A labeled checkbox with its toggle handler co-located
         * (null for none). */
        public Widget checkbox(String text, BiConsumer<Tx, Boolean> onToggle) {
            Widget w = widget(KayaWire.KIND_CHECKBOX);
            setText(w, text);
            if (onToggle != null) {
                KayaApp.this.onToggle(w, onToggle);
            }
            return w;
        }

        /** A progress bar: display-only, like label and image.
         * value is the determinate fraction (0..=1);
         * progressIndeterminate is the activity-mode arm. */
        public Widget progress(double value) {
            Widget w = widget(KayaWire.KIND_PROGRESS);
            emit(KayaWire.txSetValue(w.id, value));
            return w;
        }

        /** A progress bar in the platform's activity mode. */
        public Widget progressIndeterminate() {
            Widget w = widget(KayaWire.KIND_PROGRESS);
            emit(KayaWire.txSetIndeterminate(w.id, true));
            return w;
        }

        /** A slider whose position binds a float signal — the
         * programmatic write path (write fans out to the control;
         * property writes never echo an occurrence, so a handler's
         * own writes cannot loop back at it). */
        public Widget slider(double min, double max, Signal<Double> value,
                BiConsumer<Tx, Double> onChange) {
            Widget w = widget(KayaWire.KIND_SLIDER);
            emit(KayaWire.txSetMin(w.id, min));
            emit(KayaWire.txSetMax(w.id, max));
            emit(KayaWire.txBindValue(w.id, value.id));
            if (onChange != null) {
                KayaApp.this.onValueChanged(w, onChange);
            }
            return w;
        }

        /** A slider over min..max at value, with its change handler
         * co-located (null for none). */
        public Widget slider(double min, double max, double value,
                BiConsumer<Tx, Double> onChange) {
            Widget w = widget(KayaWire.KIND_SLIDER);
            emit(KayaWire.txSetMin(w.id, min));
            emit(KayaWire.txSetMax(w.id, max));
            emit(KayaWire.txSetValue(w.id, value));
            if (onChange != null) {
                KayaApp.this.onValueChanged(w, onChange);
            }
            return w;
        }

        /** A dropdown select over fixed options — each option
         * becomes a label child (labels only, scene-checked) — at
         * selected, the initial 0-based index (domain-checked at the
         * root against the option count), with its pick handler
         * co-located (null for none): onSelect receives each USER
         * pick's new 0-based index (programmatic writes never echo)
         * — the slider's uncontrolled contract. */
        public Widget select(String[] options, int selected,
                BiConsumer<Tx, Integer> onSelect) {
            Widget w = widget(KayaWire.KIND_SELECT);
            parents.add(w.id);
            for (String option : options) {
                Widget o = widget(KayaWire.KIND_LABEL);
                setText(o, option);
            }
            parents.remove(parents.size() - 1);
            emit(KayaWire.txSetValue(w.id, selected));
            if (onSelect != null) {
                KayaApp.this.onValueChanged(w,
                        (tx, v) -> onSelect.accept(tx, (int) (double) v));
            }
            return w;
        }

        /** A radio group over fixed options — the choice contract
         * (see select) in its inline presentation: same option
         * children, same 0-based selected index, same pick handler
         * (null for none). */
        public Widget radio(String[] options, int selected,
                BiConsumer<Tx, Integer> onSelect) {
            Widget w = widget(KayaWire.KIND_RADIO);
            parents.add(w.id);
            for (String option : options) {
                Widget o = widget(KayaWire.KIND_LABEL);
                setText(o, option);
            }
            parents.remove(parents.size() - 1);
            emit(KayaWire.txSetValue(w.id, selected));
            if (onSelect != null) {
                KayaApp.this.onValueChanged(w,
                        (tx, v) -> onSelect.accept(tx, (int) (double) v));
            }
            return w;
        }

        /** A label with constant text (the signal-bound flavor is
         * the overload below) — the const-label sugar every other
         * binding already had. */
        public Widget label(String text) {
            Widget w = widget(KayaWire.KIND_LABEL);
            setText(w, text);
            return w;
        }

        /** A label bound to a signal. */
        public Widget label(Signal<String> s) {
            Widget w = widget(KayaWire.KIND_LABEL);
            bindText(w, s);
            return w;
        }

        /** A text field; register its handler with app.onChange. */
        public Widget entry() {
            return widget(KayaWire.KIND_ENTRY);
        }

        /** A multi-line text editor: the entry's uncontrolled
         * contract over the platform's real multi-line editor;
         * register its handler with app.onChange. */
        public Widget textarea() {
            return widget(KayaWire.KIND_TEXTAREA);
        }

        /** A text field with its change handler. */
        public Widget entry(BiConsumer<Tx, String> onChange) {
            Widget w = entry();
            KayaApp.this.onChange(w, onChange);
            return w;
        }

        /**
         * An image displaying encoded bytes (PNG, JPEG, ...): the
         * toolkit decodes natively, and decode failure renders the
         * placeholder, never a crash. Registration semantics per
         * setSource: one copy into core memory, the handle consumed by
         * this transaction's submit.
         */
        public Widget image(byte[] source) {
            Widget w = widget(KayaWire.KIND_IMAGE);
            setSource(w, source);
            return w;
        }

        /** An image bound to a blob signal. */
        public Widget image(Signal<byte[]> s) {
            Widget w = widget(KayaWire.KIND_IMAGE);
            bindSource(w, s);
            return w;
        }

        public void addChild(Widget parent, Widget child) {
            emit(KayaWire.txAddChild(parent.id, child.id));
        }

        /**
         * Drop the widget's owned content — a one-shot command:
         * momentary verbs into widget-owned state, riding this
         * transaction like any write, so the insert and the clear
         * beside it commit together or not at all. Fire-and-forget: no
         * state at rest, nothing to journal, and the widget answers
         * through its normal occurrence path (a clear arrives back as
         * a text change with empty text, so the app's draft fold
         * empties itself — never a side assignment).
         */
        public void clear(Widget w) {
            emit(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_CLEAR));
        }

        /** Give the widget keyboard focus (the post-submit refocus
         * every real form wants) — a one-shot command riding the
         * transaction like clear. */
        public void focus(Widget w) {
            emit(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_FOCUS));
        }

        /**
         * DECLARE the decorated ranges of a textarea, replacing
         * whatever was declared before; an empty list is the clear.
         *
         * <p>kaya ships no search. What to decorate is the app's
         * question and every editor answers it differently — case
         * folding, word boundaries, a regex dialect with its own rules
         * — so a find engine, a find bar and a regex dialect belong to
         * the app (docs/ranges-plan.md §3). What no app can write for
         * itself is this half: colouring a run of a native text view.
         * The search that feeds it is five lines of
         * {@link String#indexOf}, and {@link TextRange#in} is where
         * those five lines meet kaya's unit:
         *
         * <pre>{@code
         * List<KayaApp.TextRange> hits = new ArrayList<>();
         * for (int at = doc.indexOf(needle); at >= 0;
         *         at = doc.indexOf(needle, at + needle.length())) {
         *     hits.add(KayaApp.TextRange.in(doc, at, at + needle.length()));
         * }
         * tx.highlightRanges(editor, hits);
         * }</pre>
         *
         * <p>APP-OWNED AND NEVER TRACKED. A declared set is bound to
         * the text it was declared against: the first edit of any kind
         * — a keystroke, a programmatic write, a native undo — drops
         * the whole set with nothing said, and the app re-declares from
         * the fold its change handler already keeps. Nothing in kaya
         * adjusts a range across an edit, which is the same
         * uncontrolled contract the text itself has (D2).
         *
         * <p>TEXTAREA ONLY this milestone; an entry refuses, naming
         * itself (docs/deferred.md carries the measured per-platform
         * reasons).
         */
        public void highlightRanges(Widget w, List<TextRange> ranges) {
            Object[] flat = new Object[ranges.size() * 2];
            for (int i = 0; i < ranges.size(); i++) {
                flat[i * 2] = ranges.get(i).start;
                flat[i * 2 + 1] = ranges.get(i).stop;
            }
            emit(KayaWire.txHighlightRanges(w.id, ranges.size(), flat));
        }

        /**
         * Put the textarea's selection at one range; an empty range
         * ({@code start == stop}) is a caret. Same offsets and the same
         * validation as {@link #highlightRanges}.
         *
         * <p>REFUSED WHILE THE USER IS COMPOSING through an input
         * method, in every backend, because honouring it commits the
         * composition mid-word — measured on macOS, where the
         * half-typed kana land in the document and in the app's own
         * model. The refusal is a NO-OP AND NOT AN EXCEPTION:
         * composition state is on no kaya channel, so the same app code
         * is correct one millisecond and racing the next, and an app
         * cannot be blamed for the user's typing rhythm. The selection
         * is still worth asking for after the next change occurrence,
         * which is what ends a composition anyway.
         */
        public void selectRange(Widget w, TextRange range) {
            emit(KayaWire.txSelectRange(w.id, range.start, range.stop));
        }

        /**
         * Scroll the textarea so a range is inside the viewport. A pure
         * effect: it moves no state, leaves the selection alone, and
         * undo does not put the scroll position back — undo restores
         * state, not where you were looking.
         *
         * <p>How much context lands around the range is the platform's
         * own scroll-to-range behaviour. What kaya fixes is
         * containment, which is the only part every platform agrees on.
         */
        public void revealRange(Widget w, TextRange range) {
            emit(KayaWire.txRevealRange(w.id, range.start, range.stop));
        }

        public Collection collection() {
            Collection c = new Collection(++collections, java.util.Collections.emptyList());
            registerCollection(c.id);
            emit(KayaWire.txCreateCollection(c.id, new int[][] { { KayaWire.VALUE_STR } }));
            return c;
        }

        /**
         * A For over {@code c}: the body declares the template; the For
         * itself (a live container) is returned.
         */
        public Widget forEach(Collection c, Consumer<Tpl> body) {
            return forEach(c, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        /**
         * A For whose body returns the handles it declared — they come
         * back alongside the For itself.
         */
        public <R> Stamped<Widget, R> forEach(
                Collection c, java.util.function.Function<Tpl, R> body) {
            c.assertRoot();
            Widget w = new Widget(++widgets, this);
            // The For parents into the enclosing scope, but the record
            // must land after template_end — an addChild inside the
            // blueprint would cross zones.
            long parent = currentParent();
            emit(KayaWire.txCreateFor(w.id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            // try/finally: a throwing body abandons the tx but the app
            // survives, and a stuck counter would poison later reads.
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(this));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            openFors.remove(openFors.size() - 1);
            emit(KayaWire.txTemplateEnd());
            if (parent != 0) {
                emit(KayaWire.txAddChild(parent, w.id));
            }
            return new Stamped<>(w, out);
        }

        /** Open a For template for a generated row trace; the trace
         * hands the loop body the Tpl once, then close() ends the
         * template and parents the For into the enclosing scope. A
         * break leaves the trace open — caught at submit.
         * The For rides the zone it opens in: the widget id space in
         * the live zone, the node space inside an enclosing template
         * (a nested trace) — the Go BeginRowTrace twin. */
        RowTrace beginRowTrace(Collection c) {
            c.assertRoot();
            long id = tplDepth > 0 ? ++nodes : ++widgets;
            long parent = currentParent();
            emit(KayaWire.txCreateFor(id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            openTraces++;
            // The counter drops in close(); a break leaves it armed
            // alongside openTraces, and submitIfAny resets both.
            tplDepth++;
            return new RowTrace(new Tpl(this), () -> {
                tplDepth--;
                parents.remove(parents.size() - 1);
                openFors.remove(openFors.size() - 1);
                emit(KayaWire.txTemplateEnd());
                openTraces--;
                if (parent != 0) {
                    emit(KayaWire.txAddChild(parent, id));
                }
            });
        }

        /** A When over a Bool signal: stamps on true, unstamps on false. */
        public Widget when(Signal<Boolean> s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Widget, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Widget w = new Widget(++widgets, this);
            long parent = currentParent();
            emit(KayaWire.txCreateWhen(w.id, s.id));
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(this));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            emit(KayaWire.txTemplateEnd());
            if (parent != 0) {
                emit(KayaWire.txAddChild(parent, w.id));
            }
            return new Stamped<>(w, out);
        }

        /**
         * The untyped insert: one value, one wire field. Delegates to
         * the record path so the binding has exactly ONE insert — which
         * is what lets absorption sit on a single line and cover every
         * explicit key, typed or not (see {@link #insertFresh}).
         */
        public void insert(Collection c, Object key, Object value) {
            insertRecordRaw(c, key, value, 0, new Object[] { value });
        }

        /**
         * Insert a value under a key the binding authors, and hand the
         * key back — {@code long key = tx.insertFresh(todos, draft)}.
         * The typed twins are
         * {@code KayaRecords.Collection.insertFresh} and
         * {@code KayaSums.SumCollection.insertFresh}.
         *
         * <p>FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain
         * identity and guest-chosen (DESIGN.md, the update algebra), so
         * anything that already HAS a name passes it to
         * {@link #insert} — today and always. This is the other case,
         * and it is the common one in a form: the app has a title and
         * nothing else, and the alternative is a hand-spelled counter
         * beside the collection, which in Java is a mutable static
         * reached from every handler that adds, and whose safety rests
         * on a never-rewind rule nobody wrote down.
         *
         * <p>ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the
         * minted key is I64 and is counter+1. An instance is a table —
         * the live-zone collection, or one stamped copy selected by
         * {@code at(...)} — and keys are unique within one, so that is
         * what the counter is per.
         *
         * <p>MIXING IS SAFE BY ABSORPTION: an explicit insert whose key
         * is an I64 at or above the counter carries it up, so a later
         * mint clears every hand-chosen numeric key already in the
         * table. A String key cannot collide with an I64 at all and
         * moves nothing.
         *
         * <p>NO DECREMENT IS EXPRESSIBLE, and that is the whole safety
         * argument. Undo and redo replay captured keys inside the core
         * and never re-enter this path ({@link KayaApp#absorbUndo}
         * writes the model directly), so a history walk never moves the
         * counter; an abandoned transaction does not move it back
         * either — {@link #rollback} restores the model, not the
         * counters, so a key can never be handed out twice. A fresh key
         * is fresh forever.
         */
        public long insertFresh(Collection c, Object value) {
            long key = mintKeyFor(c);
            insert(c, key, value);
            return key;
        }

        /** The minted key for one instance, for the typed surfaces'
         * own insertFresh: they encode their record themselves and go
         * on to insertRecordRaw, so they need the mint alone. */
        long mintKeyFor(Collection c) {
            alive();
            return mintKey(c.id, c.path);
        }

        public void update(Collection c, Object key, Object value) {
            modelSet(c.id, c.path, key, value);
            emit(KayaWire.txCollectionUpdate(c.id, c.path.toArray(), key, 0, new Object[] { value }));
            recomputeDerived(c);
        }

        // The raw record paths KayaRecords builds on: the model keeps
        // the record object itself; only the wire fields travel.
        Collection collectionWithSchema(int[] schema) {
            return collectionWithVariants(new int[][] { schema });
        }

        Collection collectionWithVariants(int[][] variants) {
            Collection c = new Collection(++collections, java.util.Collections.emptyList());
            registerCollection(c.id);
            emit(KayaWire.txCreateCollection(c.id, variants));
            return c;
        }

        void emitVariantCase(int variant) {
            emit(KayaWire.txVariantCase(variant));
        }

        void insertRecordRaw(Collection c, Object key, Object model, int variant, Object[] fields) {
            // ABSORPTION, on the one path every explicit key travels
            // (the untyped insert delegates here): a numeric key at or
            // above the minter's counter carries it up, so hand-chosen
            // and minted keys share one space safely and in either
            // order (insertFresh's contract).
            absorbKey(c.id, c.path, key);
            modelSet(c.id, c.path, key, model);
            emit(KayaWire.txCollectionInsert(c.id, c.path.toArray(), key, variant, fields));
            recomputeDerived(c);
        }

        void updateRecordRaw(Collection c, Object key, Object model, int variant, Object[] fields) {
            modelSet(c.id, c.path, key, model);
            emit(KayaWire.txCollectionUpdate(c.id, c.path.toArray(), key, variant, fields));
            recomputeDerived(c);
        }

        void updateFieldRaw(Collection c, Object key, Object model, int variant, int field, Object value) {
            modelSet(c.id, c.path, key, model);
            emit(KayaWire.txCollectionUpdateField(c.id, c.path.toArray(), key, field, variant, value));
            recomputeDerived(c);
        }

        /**
         * Repositions an entry before another's: order is collection
         * data, so the model reorders and the wire carries the same
         * keys-only delta. Keys, never indices. A missing key or
         * anchor throws here, at the call site — the same check the
         * scene makes; moving an entry before itself is a no-op, and
         * nothing travels.
         */
        public void moveBefore(Collection c, Object key, Object anchor) {
            moveEntry(c, key, new Object[] { anchor });
        }

        /** Repositions an entry at the end of its collection. */
        public void moveToEnd(Collection c, Object key) {
            moveEntry(c, key, new Object[0]);
        }

        /**
         * Repositions an entry at the front: sugar for moveBefore the
         * current first key, lowering to the same wire op.
         */
        public void moveToFront(Collection c, Object key) {
            List<Object> keys = keysOf(c);
            if (keys.isEmpty()) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            moveEntry(c, key, new Object[] { keys.get(0) });
        }

        /**
         * Repositions an entry directly after another's: sugar for
         * moveBefore the anchor's successor (moveToEnd when the anchor
         * is last), lowering to the same wire op.
         */
        public void moveAfter(Collection c, Object key, Object anchor) {
            List<Object> keys = keysOf(c);
            if (!keys.contains(key)) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            int at = keys.indexOf(anchor);
            if (at < 0) {
                throw new IllegalStateException("kaya: move after missing key " + anchor);
            }
            if (java.util.Objects.equals(key, anchor)) {
                return;
            }
            if (at + 1 == keys.size()) {
                moveEntry(c, key, new Object[0]);
                return;
            }
            if (java.util.Objects.equals(keys.get(at + 1), key)) {
                return; // already directly after the anchor
            }
            moveEntry(c, key, new Object[] { keys.get(at + 1) });
        }

        private void moveEntry(Collection c, Object key, Object[] before) {
            if (before.length > 0 && java.util.Objects.equals(before[0], key)) {
                // Moving before itself: order unchanged and nothing
                // travels — but the key must exist, the check the
                // scene would make.
                if (!keysOf(c).contains(key)) {
                    throw new IllegalStateException("kaya: move of missing key " + key);
                }
                return;
            }
            modelMove(c.id, c.path, key, before);
            emit(KayaWire.txCollectionMove(c.id, c.path.toArray(), key, before));
            recomputeDerived(c);
        }

        public void remove(Collection c, Object key) {
            modelRemove(c.id, c.path, key);
            emit(KayaWire.txCollectionRemove(c.id, c.path.toArray(), key));
            recomputeDerived(c);
        }

        // The record-time mirror-read guard: the template records once
        // and replays, so a read inside a template body is one snapshot
        // baked into every stamp — silently dead data. The typed
        // surfaces (KayaRecords, KayaSums) route through items, so this
        // is the single choke point.
        private void guardMirrorRead() {
            if (tplDepth > 0) {
                throw new IllegalStateException(
                        "kaya: model read inside a template body — the template records once"
                                + " and replays; bind a signal, use the element's field, or"
                                + " derive() for computed values");
            }
        }

        /**
         * The model: what this guest wrote, exactly — the fold of every
         * patch so far (this transaction's included), in insertion
         * order.
         */
        public List<Entry> items(Collection c) {
            guardMirrorRead();
            Instance instance = instanceOf(c.id, c.path);
            return instance == null
                    ? java.util.Collections.emptyList()
                    : new ArrayList<>(instance.entries);
        }

        public int count(Collection c) {
            guardMirrorRead();
            Instance instance = instanceOf(c.id, c.path);
            return instance == null ? 0 : instance.entries.size();
        }

        /**
         * Mount into the default window; per-window targets arrive with
         * the window vocabulary.
         */
        public void mount(Widget root) {
            emit(KayaWire.txMount(0, root.id));
        }

        /**
         * Create an auxiliary window (capability-gated: phone hosts
         * reject at the root); materializes hidden, mountIn presents.
         * Chains are the Java spelling:
         * tx.createWindow(1).title("inspector").size(480, 320).vetoClose(true).
         */
        /**
         * Request a modal alert (the request/result grammar), the
         * chain spelling:
         * tx.showAlert().title("delete item?").message("…")
         *     .action("Delete").action("Archive").cancel("Keep")
         *     .onResult((tx, choice) -> …).show().
         * The result handler rides the REQUEST (the widget-handler
         * precedent) and retires with its one answer — choice is an
         * action index (0 or 1) or KayaWire.ALERT_CHOICE_CANCEL (-1
         * in java-int terms), every platform-native dismissal. Ids
         * are binding-allocated; show() returns the id. Up to two
         * actions (the platform floor); the cancel label is required.
         * One alert may be live per process; show the next from the
         * handler.
         */
        public AlertRef showAlert() {
            return new AlertRef(this, KayaApp.this, ++nextAlert);
        }

        /**
         * Ask the platform for files. THE PICK, NOT THE OPEN — the
         * result carries handles you redeem later, so the name says
         * pick (DESIGN.md, File dialogs).
         *
         * A chain that ends in show, like showAlert:
         * tx.pickFiles().filter("Text", "txt").onResult((tx, files) ->
         * { … }).show(). CANCEL IS THE EMPTY LIST. One dialog may be
         * live per process; show the next from the handler.
         */
        public FileDialogRef pickFiles() {
            return new FileDialogRef(this, KayaApp.this, ++nextFileDialog, true);
        }

        /** The single-file spelling: the floor always returns a LIST,
         * this only asks the platform for one. */
        public FileDialogRef pickFile() {
            return new FileDialogRef(this, KayaApp.this, ++nextFileDialog, false);
        }

        /**
         * Ask the platform WHERE TO SAVE — the picker's twin, on the
         * same request/result grammar, out of the same one-live-dialog
         * slot (docs/save-plan.md D2):
         * tx.saveFile("notes").onResult((tx, file) -> { … }).show().
         * CANCEL IS null, and the id retires with the answer.
         *
         * <p>The suggested name is the one the dialog OPENS with, and
         * every platform treats it the way it treats a filter: it takes
         * it and guarantees nothing. The user renames it; Android may
         * append an extension matching the mime type. READ THE NAME YOU
         * GOT — and on the phones read the file through the handle,
         * since localPath is empty there.
         *
         * <p>WHAT YOU GET BACK OPENS EMPTY. A save destination may not
         * exist yet (macOS, GTK and Windows answer with a name for a
         * file nobody has made — measured), so the handle's open
         * CREATES: opening it for {@link KayaWire#FILE_MODE_WRITE}
         * succeeds and yields an empty file on every platform
         * (docs/save-plan.md D1).
         */
        public SaveDialogRef saveFile(String suggestedName) {
            return new SaveDialogRef(
                    this, KayaApp.this, ++nextFileDialog, suggestedName);
        }

        // --- The clipboard (DESIGN.md, Clipboard) ------------------
        //
        // A clip is not a string: every host models it as ONE item
        // available in several types, with the consumer taking the
        // richest it understands. So COPY TAKES A RECORD — spelled as a
        // chain here, where a second text() replaces the field rather
        // than needing a duplicate check — and the two answers are a
        // SUM.

        /** Begin a clip: fill in as many representations as the app
         * wants to offer, and send() puts it on the system clipboard. */
        public CopyRef copy() {
            return new CopyRef(this);
        }

        /** Begin the privileged read — THE ONE NAMED FOR WHAT IT IS
         * rather than for pasting.
         *
         * <p>A user's paste arrives at the widget's hook and costs
         * nothing; this asks without a gesture, which the platforms
         * have deliberately made expensive: iOS 16 PROMPTS when the
         * content came from another app and blocks until the user
         * answers, Android returns nothing unless the app has focus,
         * and Wayland delivers no offer to an unfocused client. Reach
         * for this to detect a URL or import from the clipboard, never
         * to implement Paste — that is the Paste command, and it is
         * free. */
        public ClipReadRef readClipboard() {
            return new ClipReadRef(this, KayaApp.this, ++nextClipboardRead);
        }

        /** Declare what a widget takes from a paste — the dynamic path;
         * the declarative spelling is the accepts chain at
         * construction. */
        public void setAccepts(Widget w, String... kinds) {
            emit(KayaWire.txSetAccepts(w.id, acceptList(kinds)));
        }

        /**
         * REQUEST the app's brand accent (docs/styling-plan.md D1/D2):
         * one packed sRGB hex ({@code 0xRRGGBB}) is the whole call, and
         * for most apps the only one they ever write — kaya derives
         * every other number from it.
         *
         * <p>THE APP NEVER WRITES A FOREGROUND and never writes
         * contrast variants: the core derives fill, on-fill,
         * standalone and a hover/pressed ramp per appearance, and hands
         * every backend VALUES. An app-supplied foreground could be
         * illegible with nothing to catch it, and three of four
         * platforms compute or hard-code theirs anyway, so honoring one
         * would mean honoring it on some platforms and ignoring it on
         * others.
         *
         * <p>A REQUEST, NOT A COMMAND, uniformly in all eight
         * languages: a platform may let its user override the app's
         * accent. macOS is the one that does today (an app accent
         * applies only while the system accent is multicolor), and the
         * semantics does not change if another grows the preference.
         *
         * <p>SET ONCE, BEFORE THE FIRST MOUNT — brand is identity, not
         * state. The root refuses a second write and a late one, so a
         * slot that could flip at runtime never promises the
         * theme-switching surface the vocabulary deliberately does not
         * have.
         */
        public void brandAccent(int seed) {
            brandAccent(seed, null, null);
        }

        /**
         * The per-appearance form: {@code light} and {@code dark} are
         * for a brand book that specifies its own dark variant, and
         * either may be {@code null} — {@code seed} fills whatever they
         * leave unstated. Overrides are clamped like anything else; an
         * authored color does not get to sit in the band where the
         * platforms' foreground rules disagree.
         *
         * <p>Boxed {@code Integer} because unstated is a real state and
         * Java has no other way to say it in argument position — the
         * {@code null} handler the constructors already take.
         */
        public void brandAccent(int seed, Integer light, Integer dark) {
            // The mask says which overrides ride along; the wire
            // carries 0 for an unstated one (spec.rs's set_brand_accent
            // — bit 0 light, bit 1 dark). Values, never per-platform
            // code: what a platform is allowed to differ on is the
            // NUMBER, and the resolution would happen here, in the
            // binding.
            int mask = (light != null ? BRAND_MASK_LIGHT : 0)
                    | (dark != null ? BRAND_MASK_DARK : 0);
            emit(KayaWire.txSetBrandAccent(
                    seed, mask, light != null ? light : 0, dark != null ? dark : 0));
        }

        public WindowRef createWindow(long id) {
            emit(KayaWire.txCreateWindow(id));
            return new WindowRef(this, KayaApp.this, id);
        }

        /** The prop chain for an existing window (0 = the primary). */
        public WindowRef window(long id) {
            return new WindowRef(this, KayaApp.this, id);
        }

        /**
         * Close and forget an auxiliary window — also the veto
         * grammar's confirmation and the reconciliation after a
         * chrome close.
         */
        public void destroyWindow(long id) {
            emit(KayaWire.txDestroyWindow(id));
        }

        /** Mount a root into a specific window; mounting presents. */
        public void mountIn(long window, Widget root) {
            emit(KayaWire.txMount(window, root.id));
        }

        /**
         * Push a navigation entry onto the primary surface's stack
         * (entry ids are guest-allocated in the shared surface
         * namespace, the createWindow discipline); materializes
         * covered, mountIn presents it. Chains are the JVM spelling:
         * tx.pushEntry(7).title("detail").interceptBack(true).
         */
        public EntryRef pushEntry(long id) {
            emit(KayaWire.txPushEntry(0, id));
            return new EntryRef(this, KayaApp.this, id);
        }

        /** Push onto another window's stack (the System Settings
         * shape: a stack inside a desktop auxiliary). */
        public EntryRef pushEntryIn(long window, long id) {
            emit(KayaWire.txPushEntry(window, id));
            return new EntryRef(this, KayaApp.this, id);
        }

        /**
         * Pop the primary stack's top entry and forget its tree —
         * also the back-veto grammar's confirmation after
         * onBackRequested. Popping an empty stack is a scene error.
         */
        public void popEntry() {
            emit(KayaWire.txPopEntry(0));
        }

        public void popEntryIn(long window) {
            emit(KayaWire.txPopEntry(window));
        }

        /**
         * Append a section to the primary window's section set
         * (section ids are guest-allocated in the shared surface
         * namespace); the set is append-only — sections have no
         * destruction grammar, and every section's root is retained
         * while covered (switching is SELECTION, not lifecycle).
         * mountIn fills its pane. Chains are the JVM spelling:
         * tx.addSection(7).title("Feed").onSelected(tx -> …).
         */
        public SectionRef addSection(long id) {
            emit(KayaWire.txAddSection(0, id));
            return new SectionRef(this, KayaApp.this, id);
        }

        /** Append onto another window's section set. */
        public SectionRef addSectionIn(long window, long id) {
            emit(KayaWire.txAddSection(window, id));
            return new SectionRef(this, KayaApp.this, id);
        }

        /** Select a section programmatically: configuration, never
         * echoes onSelected (the echo doctrine). */
        public void selectSection(long id) {
            emit(KayaWire.txSelectSection(0, id));
        }

        public void selectSectionIn(long window, long id) {
            emit(KayaWire.txSelectSection(window, id));
        }

        // --- Menus: the command vocabulary (DESIGN.md, Menus) --------

        /** Create one item in the menu-item id space. Menu records are
         * live-zone only: a template body records a blueprint, and
         * items are live and shared across stamped copies — build the
         * catalog outside (tx.contextCatalog) and attach it inside the
         * template with Tpl.contextMenu. */
        MenuItem newMenuItem(int kind, String label, boolean ctx) {
            if (tplDepth > 0) {
                throw new IllegalStateException(
                        "kaya: menu items are live — build the context catalog in the"
                                + " live zone (tx.contextCatalog) and attach it inside the"
                                + " template with Tpl.contextMenu");
            }
            MenuItem m = new MenuItem(++menuItems, this, KayaApp.this, ctx);
            emit(KayaWire.txMenuItemCreate(m.id, kind));
            if (label != null) {
                emit(KayaWire.txSetMenuLabel(m.id, label));
            }
            return m;
        }

        /**
         * Reopen a RETAINED menu item — the append-at-any-time
         * discipline: tx.menu(file).label("Document").item("Publish").
         * Props mutate freely on every kind the prop applies to; the
         * root judges a misapplied prop (kind and anchor rules)
         * exactly as at construction.
         */
        public MenuItem menu(MenuItem item) {
            return new MenuItem(item.id, this, KayaApp.this, false);
        }

        /**
         * A context menu on a LIVE widget: the same item vocabulary
         * scoped to a NOUN, with the platform's own gesture
         * (right-click, long-press). Calling it again appends more
         * roots. The editable text controls (entry, textarea) reject
         * attachment at the root; context items take no shortcuts.
         */
        public ContextRef contextMenu(Widget target) {
            return new ContextRef(this, target.id);
        }

        /**
         * Build a context catalog UNANCHORED — free root items for a
         * template-node anchor (menu items are live and shared across
         * stamped copies): Tpl.contextMenu attaches it inside the
         * template, and each activation carries the copy's key path.
         */
        public ContextCatalog contextCatalog() {
            return new ContextCatalog(this);
        }

        /**
         * Set the primary surface's title (the title bar on the
         * desktops, the switcher label on iOS, the task label on
         * Android).
         */
        public void windowTitle(String title) {
            emit(KayaWire.txSetWindowTitle(0, title));
        }

    }

    /**
     * A template body: the same declaration vocabulary with
     * template-node ids, plus element bindings.
     */
    public final class Tpl {
        private final Tx tx;

        Tpl(Tx tx) {
            this.tx = tx;
        }

        public Node widget(int kind) {
            Node n = new Node(++nodes);
            tx.emit(KayaWire.txCreateWidget(n.id, kind));
            tx.autoParent(n.id);
            return n;
        }

        // PRIVATE, AND THE ONLY PROP WRITE IN THIS ZONE THAT IS. Java
        // spells the live TEXT VERB — Tx.setText(Widget, String), the
        // "open a document into the editor" write every scene script
        // reaches for — and this blueprint prop write with ONE name, and
        // the sweep that keeps example guests off the explicit tier
        // reads lines rather than types: `.setText(` cannot tell which
        // receiver it found. Rust never had the problem, keeping the two
        // as `set` and `set_text`. Hiding is the stronger half of that
        // split: no guest can reach the floor spelling at all, so the
        // compiler holds the rule where a regex would have had to, and
        // nothing is lost — every kind that carries text is constructed
        // with it (label, button, entry, textarea, and the option labels
        // below).
        private void setText(Node n, String text) {
            tx.emit(KayaWire.txSetText(n.id, text));
        }

        /**
         * Bind text to the element of the enclosing For, {@code level}
         * Fors up (0 = nearest).
         */
        public void bindTextElement(Node n, int level) {
            tx.emit(KayaWire.txBindTextElement(n.id, level, 0));
        }

        /** Bind a label's text to one field of the element; a String
         * field token only — the type pins it at compile time. */
        public void bindTextField(Node n, int level, KayaRecords.Field<String> f) {
            tx.emit(KayaWire.txBindTextElement(n.id, level, f.index));
        }

        /** Bind a checkbox's state to one field of the element; a
         * Boolean field token only. */
        public void bindCheckedField(Node n, int level, KayaRecords.Field<Boolean> f) {
            tx.emit(KayaWire.txBindCheckedElement(n.id, level, f.index));
        }

        /** Bind an image's source to one field of the element; a
         * byte[] field token only — the type pins it at compile time. */
        public void bindSourceField(Node n, int level, KayaRecords.Field<byte[]> f) {
            tx.emit(KayaWire.txBindSourceElement(n.id, level, f.index));
        }

        /**
         * Bind a slider's position, a progress bar's fraction or a
         * choice widget's selected index to one field of the element.
         *
         * <p>A {@code Double} token and only ever a Double one: Value is
         * an F64 property in the spec, a record component declared
         * {@code long} mints an I64 field, and the root refuses the
         * pairing by name at declaration. A row that holds an option
         * INDEX therefore declares that component {@code double} — the
         * wart is the core's prop typing, not Java's.
         */
        public void bindValueField(Node n, int level, KayaRecords.Field<Double> f) {
            tx.emit(KayaWire.txBindValueElement(n.id, level, f.index));
        }

        /**
         * A template node's flex weight within its row/column — the
         * blueprint twin of {@link Tx#setGrow(Widget, double)}, and the
         * half {@link #scroll} needs: a viewport nothing constrains hugs
         * its content and never overflows.
         *
         * <p>A Node carries no transaction, so there is no construction
         * chain to hang this on the way the live zone does; the setter
         * directly after construction is the spelling, as it is for
         * every prop below.
         */
        public void setGrow(Node n, double weight) {
            tx.emit(KayaWire.txSetGrow(n.id, weight));
        }

        // THE ACCESSIBILITY PROPS, one setter per source. They take the
        // node first for setGrow's reason — a Node holds no transaction,
        // so there is no chain — and the ARGUMENT'S TYPE picks the
        // source, the same trichotomy the constructors below use. The
        // field overload is why this zone needs its own setters at all:
        // a stamped row announcing its OWN name to assistive tech is
        // something the live zone cannot spell, because a live widget
        // has no row to read.
        //
        // A CONSTANT ID ON EVERY COPY IS LEGAL and often right: nothing
        // in the core deduplicates a11y ids, and the harness addresses a
        // copy by kind#index, never by id. Reach for the row's own key
        // field only when something outside kaya must tell the copies
        // apart.

        /** A template node's accessibility identifier, one constant for
         * every stamped copy — the blueprint twin of
         * {@link Tx#setA11yId(Widget, String)}. */
        public void setA11yId(Node n, String id) {
            tx.emit(KayaWire.txSetA11yId(n.id, id));
        }

        /** An identifier every copy takes from one signal, moving when
         * it does. */
        public void setA11yId(Node n, Signal<String> s) {
            tx.emit(KayaWire.txBindA11yId(n.id, s.id));
        }

        /** An identifier from the row's own field — a per-copy key for
         * whatever addresses these rows from outside. */
        public void setA11yId(Node n, KayaRecords.Field<String> f) {
            bindA11yIdField(n, 0, f);
        }

        /** Bind a node's identifier to one field of the element,
         * {@code level} Fors up (0 = nearest) — {@link #bindTextField}'s
         * shape, one prop over, and the only way to read an OUTER row's
         * field from a nested template. */
        public void bindA11yIdField(Node n, int level, KayaRecords.Field<String> f) {
            tx.emit(KayaWire.txBindA11yIdElement(n.id, level, f.index));
        }

        /** What an assistive client SPEAKS for every stamped copy — the
         * blueprint twin of {@link Tx#setA11yLabel(Widget, String)}. */
        public void setA11yLabel(Node n, String label) {
            tx.emit(KayaWire.txSetA11yLabel(n.id, label));
        }

        public void setA11yLabel(Node n, Signal<String> s) {
            tx.emit(KayaWire.txBindA11yLabel(n.id, s.id));
        }

        /** The row's own field as the spoken name: each copy announces
         * itself. A label whose text already comes from the row usually
         * wants the SAME field here — otherwise a screen reader is left
         * inferring the name from the layout around it. */
        public void setA11yLabel(Node n, KayaRecords.Field<String> f) {
            bindA11yLabelField(n, 0, f);
        }

        public void bindA11yLabelField(Node n, int level, KayaRecords.Field<String> f) {
            tx.emit(KayaWire.txBindA11yLabelElement(n.id, level, f.index));
        }

        /**
         * What ACTIVATING a stamped copy does — a verb phrase, the
         * blueprint twin of {@link Tx#setA11yHint(Widget, String)}.
         *
         * <p>THE ONE A11Y PROP THAT IS NOT UNIVERSAL: the root admits it
         * on the activation kinds alone (button, checkbox, select,
         * radio), because a label, an image or a container has no
         * activation to describe. There is no type here to say so, in
         * this zone or the live one — a hint on any other kind fails the
         * BUILD in the root's own words, as the prototype is recorded
         * and before a single row stamps, so the message names the
         * guest's one declaration rather than one copy per row.
         */
        public void setA11yHint(Node n, String hint) {
            tx.emit(KayaWire.txSetA11yHint(n.id, hint));
        }

        public void setA11yHint(Node n, Signal<String> s) {
            tx.emit(KayaWire.txBindA11yHint(n.id, s.id));
        }

        public void setA11yHint(Node n, KayaRecords.Field<String> f) {
            bindA11yHintField(n, 0, f);
        }

        public void bindA11yHintField(Node n, int level, KayaRecords.Field<String> f) {
            tx.emit(KayaWire.txBindA11yHintElement(n.id, level, f.index));
        }

        /**
         * Declare what every stamped copy takes from a paste — the
         * closed kinds by name ({@link KayaApp#ACCEPT_TEXT} and friends)
         * plus any custom format ids.
         *
         * <p>THE HALF {@link KayaApp#onPaste(Node, PasteHandler)} WAS
         * MISSING. Every backend gates the paste occurrence on the
         * focused widget's accept list and falls back to the platform's
         * own insertion when it is empty, so before this setter existed
         * a handler registered against a template node compiled,
         * registered, and could never fire — no binding could put an
         * accept list on a blueprint.
         *
         * <p>A CONSTANT, NOT A SOURCE, unlike the a11y props above: what
         * a control can take is a fact about the PROTOTYPE, the way a
         * slider's range and a select's options are, and every copy has
         * it by construction. On Android it is also the native
         * registration itself (the mime types on the view), which is a
         * capability rather than row data.
         */
        public void setAccepts(Node n, String... kinds) {
            tx.emit(KayaWire.txSetAccepts(n.id, acceptList(kinds)));
        }

        // The template flavor of the sugar: bindings take field
        // tokens, containers take their body.
        public Node row(Runnable body) {
            return containerOf(KayaWire.KIND_ROW, body);
        }

        public Node column(Runnable body) {
            return containerOf(KayaWire.KIND_COLUMN, body);
        }

        /** A vertical scroll viewport over EXACTLY ONE child, per
         * stamped copy (declare it in the body; the scene rejects a
         * second). Weight it with {@link #setGrow} for the reason
         * {@link Tx#scroll} states — a Node has no chain to put the
         * .grow(1) on. */
        public Node scroll(Runnable body) {
            return containerOf(KayaWire.KIND_SCROLL, body);
        }

        /**
         * A grid laying each copy's children out row-major into
         * {@code columns} columns — the template twin of
         * {@link Tx#grid(int, Runnable)}.
         *
         * <p>The count describes the PROTOTYPE, so it is a constant and
         * not a source: every stamped copy has the same shape and only
         * the values inside it vary. Alignment is per copy — a grid in a
         * template does not line its columns up ACROSS copies, since
         * each copy stamps a grid of its own.
         */
        public Node grid(int columns, Runnable body) {
            Node parent = widget(KayaWire.KIND_GRID);
            tx.emit(KayaWire.txSetColumns(parent.id, columns));
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        /** A spacer: the live zone's PURE SUGAR for an empty grown
         * column, one copy per stamp, eating the leftover main-axis
         * space between that copy's siblings. */
        public Node spacer() {
            Node n = widget(KayaWire.KIND_COLUMN);
            tx.emit(KayaWire.txSetGrow(n.id, 1.0));
            return n;
        }

        private Node containerOf(int kind, Runnable body) {
            Node parent = widget(kind);
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        // One name per widget; the argument's type picks the
        // addressable source (constant, signal, or element field).
        // That trichotomy IS the reason this zone has its own
        // constructors: a stamp makes N copies, and each copy's value
        // can come from its own row. Arguments that describe the
        // PROTOTYPE instead — a slider's range, a grid's column count,
        // a choice widget's options — stay plain constants, because
        // every copy has them.
        public Node label(String text) {
            Node n = widget(KayaWire.KIND_LABEL);
            setText(n, text);
            return n;
        }

        public Node label(Signal<String> s) {
            Node n = widget(KayaWire.KIND_LABEL);
            tx.emit(KayaWire.txBindText(n.id, s.id));
            return n;
        }

        public Node label(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_LABEL);
            bindTextField(n, 0, f);
            return n;
        }

        /**
         * A button with its caption, in the blueprint: the template
         * twin of {@link Tx#button(String)}.
         *
         * <p>Its handler is registered against the template node
         * ({@code app.onClick(node, (tx, keys) -> …)}) because a
         * stamped copy's click names the copy — the keys ARE the noun.
         * There is no caption-plus-handler overload here for that
         * reason: the live-zone {@code button(text, onClick)} takes a
         * {@code Consumer<Tx>}, and a template's handler cannot have
         * that shape.
         */
        public Node button(String text) {
            Node n = widget(KayaWire.KIND_BUTTON);
            setText(n, text);
            return n;
        }

        public Node button(Signal<String> s) {
            Node n = widget(KayaWire.KIND_BUTTON);
            tx.emit(KayaWire.txBindText(n.id, s.id));
            return n;
        }

        /** A button captioned from the row's own field — the "delete
         * <that row's title>" shape, which only this zone can spell. */
        public Node button(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_BUTTON);
            bindTextField(n, 0, f);
            return n;
        }

        /** A constant image in the blueprint: the bytes register once,
         * at record time, and every stamp shows them. */
        public Node image(byte[] source) {
            Node n = widget(KayaWire.KIND_IMAGE);
            tx.emit(KayaWire.txSetSource(n.id, KayaRing.blobRegister(source)));
            return n;
        }

        public Node image(Signal<byte[]> s) {
            Node n = widget(KayaWire.KIND_IMAGE);
            tx.emit(KayaWire.txBindSource(n.id, s.id));
            return n;
        }

        /** An image bound to one field of the element. */
        public Node image(KayaRecords.Field<byte[]> f) {
            Node n = widget(KayaWire.KIND_IMAGE);
            bindSourceField(n, 0, f);
            return n;
        }

        /**
         * Attach a live-built context catalog (tx.contextCatalog) to a
         * template node: every stamped copy shows the same catalog,
         * and each activation carries that copy's key path — the keys
         * ARE the noun (received by the *Node handler flavors). An
         * item takes exactly one anchor, so a second attach of the
         * same catalog throws here.
         */
        public void contextMenu(Node n, ContextCatalog catalog) {
            if (catalog.attached) {
                throw new IllegalStateException(
                        "kaya: a context catalog takes exactly one anchor");
            }
            catalog.attached = true;
            for (long root : catalog.roots) {
                tx.emit(KayaWire.txContextAttachNode(n.id, root));
            }
        }

        /** Register a toggle handler on a template node — the bridge
         * the typed record sugar routes through. */
        public void onToggleNode(Node n, ToggleHandler handler) {
            KayaApp.this.onToggle(n, handler);
        }

        /** A checkbox in the blueprint; register its handler with
         * app.onToggle, which hands it the stamped copy's keys. */
        public Node checkbox(boolean checked) {
            Node n = widget(KayaWire.KIND_CHECKBOX);
            tx.emit(KayaWire.txSetChecked(n.id, checked));
            return n;
        }

        public Node checkbox(Signal<Boolean> s) {
            Node n = widget(KayaWire.KIND_CHECKBOX);
            tx.emit(KayaWire.txBindChecked(n.id, s.id));
            return n;
        }

        /** A checkbox bound to one field of the element — each copy
         * showing its own row's state. */
        public Node checkbox(KayaRecords.Field<Boolean> f) {
            Node n = widget(KayaWire.KIND_CHECKBOX);
            bindCheckedField(n, 0, f);
            return n;
        }

        /**
         * A single-line text field per stamped copy, EMPTY — which is
         * why this takes nothing. The field is uncontrolled: each copy
         * owns its own text, edits arrive as a change on this node
         * carrying the copy's keys ({@code app.onChange(node, (tx, keys,
         * text) -> …)}), and the app folds them into its own state.
         *
         * <p>This is the arm a per-row note or a find bar wants; the
         * overloads below SEED a copy instead.
         */
        public Node entry() {
            return widget(KayaWire.KIND_ENTRY);
        }

        /**
         * An entry whose INITIAL text is one constant, the same in
         * every stamped copy.
         *
         * <p>ONE WRITE PER COPY, NOT A BINDING — the rule
         * {@link Tx#setText(Widget, String)} states. The seed is written
         * as the copy is stamped and the user owns the text from that
         * moment; nothing pushes into it again.
         */
        public Node entry(String text) {
            Node n = widget(KayaWire.KIND_ENTRY);
            setText(n, text);
            return n;
        }

        public Node entry(Signal<String> s) {
            Node n = widget(KayaWire.KIND_ENTRY);
            tx.emit(KayaWire.txBindText(n.id, s.id));
            return n;
        }

        /**
         * An entry seeded from the row's own field: an editable list
         * that starts filled in, which the live zone has no way to
         * spell (a live widget has no row to read).
         *
         * <p>MIND THE FOLD. Unlike a label's, this binding stays live:
         * a later {@code update_field} on that component re-pushes the
         * text into the copy. A handler that folds each keystroke back
         * into the same field it seeded from therefore rewrites the
         * field the user is typing in — spending its native undo
         * history and dropping any ranges declared over it — so fold
         * elsewhere, or seed with {@link #entry()} and keep the text in
         * the app's own state.
         */
        public Node entry(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_ENTRY);
            bindTextField(n, 0, f);
            return n;
        }

        /** A multi-line editor per stamped copy: the entry's
         * uncontrolled contract over the platform's real multi-line
         * control, empty and owned by the copy. */
        public Node textarea() {
            return widget(KayaWire.KIND_TEXTAREA);
        }

        /** A textarea seeded with one constant — {@link #entry(String)}'s
         * one-write rule, one kind over. */
        public Node textarea(String text) {
            Node n = widget(KayaWire.KIND_TEXTAREA);
            setText(n, text);
            return n;
        }

        public Node textarea(Signal<String> s) {
            Node n = widget(KayaWire.KIND_TEXTAREA);
            tx.emit(KayaWire.txBindText(n.id, s.id));
            return n;
        }

        /** A textarea seeded from the row's own field, with
         * {@link #entry(KayaRecords.Field)}'s fold warning in full. */
        public Node textarea(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_TEXTAREA);
            bindTextField(n, 0, f);
            return n;
        }

        /** A progress bar in the blueprint at a constant fraction
         * (0..=1, domain-checked at the root): display-only, like label
         * and image, so nothing here reports. */
        public Node progress(double value) {
            Node n = widget(KayaWire.KIND_PROGRESS);
            tx.emit(KayaWire.txSetValue(n.id, value));
            return n;
        }

        public Node progress(Signal<Double> s) {
            Node n = widget(KayaWire.KIND_PROGRESS);
            tx.emit(KayaWire.txBindValue(n.id, s.id));
            return n;
        }

        /** A progress bar showing the row's OWN fraction — the per-row
         * case this zone exists for. */
        public Node progress(KayaRecords.Field<Double> f) {
            Node n = widget(KayaWire.KIND_PROGRESS);
            bindValueField(n, 0, f);
            return n;
        }

        /** A progress bar in the platform's activity mode: no fraction,
         * so nothing to source. */
        public Node progressIndeterminate() {
            Node n = widget(KayaWire.KIND_PROGRESS);
            tx.emit(KayaWire.txSetIndeterminate(n.id, true));
            return n;
        }

        /**
         * A slider over {@code min..max} at a constant position: the
         * range describes the prototype and is the same in every stamped
         * copy; the position is the part a source can vary.
         *
         * <p>Its handler is registered against the template node
         * ({@code app.onValueChanged(node, (tx, keys, value) -> …)})
         * because a stamped copy's move names the copy — the keys ARE
         * the noun. There is no handler-carrying overload for the same
         * reason {@link #button(String)} has none.
         */
        public Node slider(double min, double max, double value) {
            Node n = sliderOver(min, max);
            tx.emit(KayaWire.txSetValue(n.id, value));
            return n;
        }

        public Node slider(double min, double max, Signal<Double> value) {
            Node n = sliderOver(min, max);
            tx.emit(KayaWire.txBindValue(n.id, value.id));
            return n;
        }

        /** A slider sitting where the row's own field says. */
        public Node slider(double min, double max, KayaRecords.Field<Double> value) {
            Node n = sliderOver(min, max);
            bindValueField(n, 0, value);
            return n;
        }

        // The slider's shared head: the range every copy has, before
        // the overload applies whatever source carries the position.
        private Node sliderOver(double min, double max) {
            Node n = widget(KayaWire.KIND_SLIDER);
            tx.emit(KayaWire.txSetMin(n.id, min));
            tx.emit(KayaWire.txSetMax(n.id, max));
            return n;
        }

        /**
         * A dropdown select over fixed options — each option becomes a
         * label child — at {@code selected}, the initial 0-based index,
         * the same in every stamped copy.
         *
         * <p>THE OPTIONS ARE THE PROTOTYPE'S. They are children of the
         * blueprint node, so every copy offers the same list and only
         * the choice varies; a per-row option list would need a
         * collection inside the choice widget, which the scene rejects
         * (labels only, deliberately).
         *
         * <p>Its pick handler is registered against the template node
         * ({@code app.onValueChanged(node, (tx, keys, index) -> …)}) and
         * receives each USER pick's new index — programmatic writes
         * never echo, the slider's uncontrolled contract. The index
         * arrives as a {@code double} and the app narrows it: the live
         * {@link Tx#select} narrows inside the constructor by wrapping
         * the handler it was handed, and a template constructor is
         * handed none.
         */
        public Node select(String[] options, int selected) {
            Node n = choice(KayaWire.KIND_SELECT, options);
            tx.emit(KayaWire.txSetValue(n.id, selected));
            return n;
        }

        public Node select(String[] options, Signal<Double> selected) {
            Node n = choice(KayaWire.KIND_SELECT, options);
            tx.emit(KayaWire.txBindValue(n.id, selected.id));
            return n;
        }

        /** A select remembering each row's OWN pick; the field is a
         * Double component, per {@link #bindValueField}. */
        public Node select(String[] options, KayaRecords.Field<Double> selected) {
            Node n = choice(KayaWire.KIND_SELECT, options);
            bindValueField(n, 0, selected);
            return n;
        }

        /** A radio group over fixed options — the choice contract (see
         * {@link #select(String[], int)}) in its inline presentation:
         * same option children, same 0-based index, same handler
         * registration. */
        public Node radio(String[] options, int selected) {
            Node n = choice(KayaWire.KIND_RADIO, options);
            tx.emit(KayaWire.txSetValue(n.id, selected));
            return n;
        }

        public Node radio(String[] options, Signal<Double> selected) {
            Node n = choice(KayaWire.KIND_RADIO, options);
            tx.emit(KayaWire.txBindValue(n.id, selected.id));
            return n;
        }

        public Node radio(String[] options, KayaRecords.Field<Double> selected) {
            Node n = choice(KayaWire.KIND_RADIO, options);
            bindValueField(n, 0, selected);
            return n;
        }

        // The choice kinds' shared head: the option labels, parented
        // through the same ambient stack the live zone's select uses.
        // The index is left to the caller's overload so each source
        // keeps its own type all the way to the wire.
        private Node choice(int kind, String[] options) {
            Node n = widget(kind);
            parents.add(n.id);
            for (String option : options) {
                Node o = widget(KayaWire.KIND_LABEL);
                setText(o, option);
            }
            parents.remove(parents.size() - 1);
            return n;
        }

        public void addChild(Node parent, Node child) {
            tx.emit(KayaWire.txAddChild(parent.id, child.id));
        }

        public Collection collection() {
            return tx.collection();
        }

        public Node forEach(Collection c, Consumer<Tpl> body) {
            return forEach(c, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Node, R> forEach(
                Collection c, java.util.function.Function<Tpl, R> body) {
            c.assertRoot();
            Node n = new Node(++nodes);
            long parent = tx.currentParent();
            tx.emit(KayaWire.txCreateFor(n.id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(tx));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            openFors.remove(openFors.size() - 1);
            tx.emit(KayaWire.txTemplateEnd());
            if (parent != 0) {
                tx.emit(KayaWire.txAddChild(parent, n.id));
            }
            return new Stamped<>(n, out);
        }

        public Node when(Signal<Boolean> s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Node, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Node n = new Node(++nodes);
            long parent = tx.currentParent();
            tx.emit(KayaWire.txCreateWhen(n.id, s.id));
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(tx));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            tx.emit(KayaWire.txTemplateEnd());
            if (parent != 0) {
                tx.emit(KayaWire.txAddChild(parent, n.id));
            }
            return new Stamped<>(n, out);
        }
    }

    /**
     * Run {@code build} with a fresh transaction and submit it
     * atomically. A handler that throws abandons its records, and the
     * model abandons the same writes before the exception continues.
     */
    public void build(Consumer<Tx> build) {
        build(tx -> {
            build.accept(tx);
            return null;
        });
    }

    /**
     * build whose body returns the handles it declared — the way a
     * scene's signals, collections, and buttons reach the handlers
     * without static fields.
     */
    public <R> R build(java.util.function.Function<Tx, R> build) {
        Tx tx = new Tx();
        ambient = this;
        currentTx = tx;
        R out;
        try {
            out = build.apply(tx);
        } catch (RuntimeException | Error e) {
            tx.rollback();
            throw e;
        } finally {
            // Every exit clears the ambient slot — a stale currentTx
            // would let the operator sugar reach a closed transaction
            // (the divergence the other bindings never had) — and
            // marks the transaction over, so late construction chains
            // (Widget.grow) die loudly on either exit path.
            currentTx = null;
            tx.closed = true;
        }
        tx.submitIfAny();
        return out;
    }

    /** Take pasted content at a live widget.
     *
     * <p>COSTS NOTHING ON ANY PLATFORM, unlike readClipboard: a paste
     * is a user gesture, so it is its own authorisation — iOS raises no
     * prompt and the focus rules are satisfied by construction. Only
     * fires for a widget that declared what it accepts. */
    public void onPaste(Widget w, BiConsumer<Tx, Representation> handler) {
        widgetPastes.put(w.id, handler);
    }

    /** A paste onto a stamped copy: the handler also receives the
     * copy's key path, outermost first. One record kind, the path
     * deciding — exactly as a click on a stamped row is one record with
     * a click on a live widget. */
    public void onPaste(Node n, PasteHandler handler) {
        nodePastes.put(n.id, handler);
    }

    /**
     * Fold an undo's payload into the collection model.
     *
     * <p>The rollback journal in reverse: a rolled-back Tx restores a
     * snapshot because nothing was shipped, while an undo restores a
     * delta because everything WAS — the core already moved, and the
     * model is what would otherwise be left behind. Same machinery,
     * opposite case, and the payload is core-authoritative so nothing
     * here re-derives anything.
     *
     * <p>Signals and text are not mirrored by this binding (there is no
     * read-back for either, by doctrine), so those two runs pass
     * straight to the app's own handler.
     *
     * <p>NO DERIVED RECOMPUTE HERE, DELIBERATELY — the absence is the
     * design and not an oversight. A derived signal's write rode the
     * SAME transaction as the mutation that caused it: every mutation
     * path calls {@link Tx#recomputeDerived}, which runs the registered
     * computes into that very transaction. So when the transaction was
     * a named step, the group banked the derived value in both of its
     * directions and the core has already restored it before this
     * method is reached. The compiler states it too — recomputing is a
     * {@code Tx} method and this method holds no {@code Tx}, only a
     * payload.
     *
     * <p>A recompute added here would write a value the ledger never
     * banked, in a transaction the app never asked for, landing between
     * the core's restore and the app's own {@code onUndone}. Where it
     * agreed with the banked value it would be dead code hiding the
     * mechanism; where it disagreed — a compute that reads anything
     * besides the entries, or a derive declared after that step was
     * banked (docs/deferred.md's one residual) — the screen and the
     * ledger's record of the step would drift apart, and the next walk
     * through the history would jump back to the banked value.
     */
    private void absorbUndo(UndoDelta delta) {
        for (UndoEntry entry : delta.entries()) {
            List<Instance> instances =
                    model.computeIfAbsent(entry.collection(), k -> new ArrayList<>());
            Instance instance = null;
            for (Instance candidate : instances) {
                if (candidate.path.equals(entry.path())) {
                    instance = candidate;
                    break;
                }
            }
            if (instance == null) {
                instance = new Instance(entry.path());
                instances.add(instance);
            }
            if (!entry.present()) {
                instance.entries.removeIf(e -> java.util.Objects.equals(e.key, entry.key()));
                continue;
            }
            // THE WIRE HANDS BACK WIRE FIELDS AND THE MODEL HOLDS THE
            // GUEST'S OWN OBJECT, so the entry is rebuilt through the
            // decoder the collection registered when it was declared —
            // the one place the guest's type is known. An untyped
            // collection's decoder is the identity on its single field.
            Object value = rebuildEntry(entry.collection(), entry.variant(), entry.fields());
            boolean replaced = false;
            for (int i = 0; i < instance.entries.size(); i++) {
                if (java.util.Objects.equals(instance.entries.get(i).key, entry.key())) {
                    instance.entries.set(i, new Entry(entry.key(), value));
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                instance.entries.add(new Entry(entry.key(), value));
            }
        }
        for (UndoOrder order : delta.orders()) {
            Instance instance = instanceOf(order.collection(), order.path());
            if (instance == null) {
                continue;
            }
            // Position by the payload's list, keeping anything it does
            // not name at the end: the delta describes one instance's
            // whole order, and an entry it never mentions is one this
            // undo did not touch.
            List<Entry> sorted = new ArrayList<>(instance.entries.size());
            for (Object key : order.keys()) {
                for (int i = 0; i < instance.entries.size(); i++) {
                    if (java.util.Objects.equals(instance.entries.get(i).key, key)) {
                        sorted.add(instance.entries.remove(i));
                        break;
                    }
                }
            }
            sorted.addAll(instance.entries);
            instance.entries.clear();
            instance.entries.addAll(sorted);
        }
    }

    /**
     * The decoder's taste-free shape, typed: the signals' flattened
     * (id, value) pairs become records, and the three arity-first groups
     * keep theirs. The generated parser owns the LAYOUT (counts in the
     * head, one flat Values tail cut into four runs); this owns the SUM
     * the app sees — the same split representation() already makes for
     * a clip.
     */
    static UndoDelta undoDelta(KayaWire.UndoValues values) {
        List<UndoSignal> signals = new ArrayList<>(values.signals.size() / 2);
        for (int i = 0; i + 1 < values.signals.size(); i += 2) {
            signals.add(new UndoSignal((Long) values.signals.get(i), values.signals.get(i + 1)));
        }
        List<UndoText> texts = new ArrayList<>(values.texts.size());
        for (KayaWire.UndoTextValues text : values.texts) {
            texts.add(new UndoText(text.id, text.path, text.text));
        }
        List<UndoEntry> entries = new ArrayList<>(values.entries.size());
        for (KayaWire.UndoEntryValues entry : values.entries) {
            entries.add(new UndoEntry(entry.collection, entry.path, entry.key,
                    entry.present, entry.variant, entry.fields));
        }
        List<UndoOrder> orders = new ArrayList<>(values.orders.size());
        for (KayaWire.UndoOrderValues order : values.orders) {
            orders.add(new UndoOrder(order.collection, order.path, order.keys));
        }
        return new UndoDelta(signals, texts, entries, orders);
    }

    private Object rebuildEntry(long collection, int variant, List<Object> fields) {
        java.util.function.BiFunction<Integer, List<Object>, Object> decoder =
                rebuild.get(collection);
        if (decoder != null) {
            return decoder.apply(variant, fields);
        }
        // A collection declared through the plain handle holds one
        // wire-typed value per entry, and that value IS the model's.
        return fields.isEmpty() ? null : fields.get(0);
    }

    /** Register a click handler for a live widget. */
    public void onClick(Widget w, Consumer<Tx> handler) {
        widgetHandlers.put(w.id, handler);
    }

    /**
     * Register a click handler for a template node; it also receives
     * the stamped copy's keys, outermost first.
     */
    public void onClick(Node n, BiConsumer<Tx, List<Object>> handler) {
        nodeHandlers.put(n.id, handler);
    }

    /**
     * Register a change handler for a live entry: the widget owns its
     * text and reports each edit here; the app folds the text into its
     * own state — there is no read-back, by doctrine.
     */
    public void onChange(Widget w, BiConsumer<Tx, String> handler) {
        widgetChanges.put(w.id, handler);
    }

    /**
     * Register a change handler for a template entry; it also receives
     * the stamped copy's keys, outermost first.
     */
    public void onChange(Node n, ChangeHandler handler) {
        nodeChanges.put(n.id, handler);
    }

    /**
     * Register a toggle handler for a live checkbox: the box owns its
     * checked bit and reports each flip here; the app folds it into its
     * own state.
     */
    public void onToggle(Widget w, BiConsumer<Tx, Boolean> handler) {
        widgetToggles.put(w.id, handler);
    }

    /** Register a change handler for a live slider: the bar owns its
     * position and reports each move with the new value — the entry's
     * uncontrolled contract, with a double. */
    public void onValueChanged(Widget w, BiConsumer<Tx, Double> handler) {
        widgetValues.put(w.id, handler);
    }

    /**
     * Register a toggle handler for a template checkbox; it also
     * receives the stamped copy's keys, outermost first.
     */
    public void onToggle(Node n, ToggleHandler handler) {
        nodeToggles.put(n.id, handler);
    }

    /**
     * Register a change handler for a template slider, select or radio
     * group; it also receives the stamped copy's keys, outermost first.
     *
     * <p>The core has always sent this — a stamped copy's move arrives
     * as a value change carrying the copy's identity tag — and until
     * this table existed the dispatch loop had a live arm and no node
     * arm, so the occurrence matched nothing and was dropped in
     * silence.
     */
    public void onValueChanged(Node n, ValueHandler handler) {
        nodeValues.put(n.id, handler);
    }

    // The ring consumer: Unsafe absolute loads plus explicit fences,
    // bound once as MethodHandles and invoked through invokeExact so the
    // per-record path stays free of boxing and reflection. Raw addresses
    // rather than direct ByteBuffers because of the ART VarHandle
    // truncation; see KayaRing.
    private static final MethodHandle GET_INT;
    private static final MethodHandle GET_BYTE;
    private static final MethodHandle PUT_INT;
    private static final MethodHandle LOAD_FENCE;
    private static final MethodHandle STORE_FENCE;

    static {
        try {
            Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
            Field theUnsafe = unsafeClass.getDeclaredField("theUnsafe");
            theUnsafe.setAccessible(true);
            Object unsafe = theUnsafe.get(null);
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            GET_INT = lookup.unreflect(unsafeClass.getMethod("getInt", long.class)).bindTo(unsafe);
            GET_BYTE =
                    lookup.unreflect(unsafeClass.getMethod("getByte", long.class)).bindTo(unsafe);
            PUT_INT = lookup
                    .unreflect(unsafeClass.getMethod("putInt", long.class, int.class))
                    .bindTo(unsafe);
            LOAD_FENCE = lookup.unreflect(unsafeClass.getMethod("loadFence")).bindTo(unsafe);
            STORE_FENCE = lookup.unreflect(unsafeClass.getMethod("storeFence")).bindTo(unsafe);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    /**
     * Consume the ring and dispatch until shutdown. Call on the app
     * thread after the scene is built and handlers are registered (on
     * Android, after KayaRing.attach set the core up).
     */
    public void dispatchLoop() {
        // The stale-artifact guard: this binding was generated from one
        // spec revision; the loaded library must speak the same one.
        if (KayaRing.specHash() != KayaWire.SPEC_HASH) {
            throw new IllegalStateException(String.format(
                    "kaya: library speaks spec %#x, this binding was generated from %#x"
                            + " — rebuild the library or regenerate bindings",
                    KayaRing.specHash(), KayaWire.SPEC_HASH));
        }
        try {
            loop();
        } catch (Throwable t) {
            // invokeExact declares Throwable; nothing here throws in practice.
            throw new RuntimeException(t);
        }
    }

    /**
     * One handler dispatch: an exception crosses the build boundary
     * (which rolled the model back and dropped the records), is
     * logged, and the loop moves to the next occurrence — the uniform
     * dispatch discipline across every binding. VM-fatal errors still
     * die.
     */


    /**
     * Run {@code body} as a transaction on the app thread, soon. THE ONE
     * method safe to call from another thread, and the answer to "how
     * does background work reach the UI".
     *
     * <p>{@code build} is a transaction NOW on the calling thread;
     * {@code post} is the same transaction SOON on the app thread — so a
     * background thread writes ordinary blocking Java and hands back
     * only the result:
     *
     * <pre>{@code
     * new Thread(() -> {
     *     String data = Files.readString(path);   // blocks this thread
     *     app.post(tx -> tx.write(content, data));   // back on the app thread
     * }).start();
     * }</pre>
     *
     * <p>The {@code Tx} is made where it is used and never crosses a
     * thread; ids are values and are meant to be captured. A posted body
     * runs in its OWN transaction, after whatever is running now, so
     * posting from inside a handler queues for after and never nests.
     */
    public void post(Consumer<Tx> body) {
        synchronized (postLock) {
            posted.add(body);
        }
        // The app thread may be parked in waitOccurrences. Posted work is
        // not an occurrence and never enters the ring, so this is the
        // only way it hears about it.
        KayaRing.wake();
    }

    /**
     * Run everything posted, each as its own transaction, in order.
     *
     * <p>The batch is taken and the monitor released BEFORE any of it
     * runs, so a body that posts again lands in the NEXT batch. Holding
     * the monitor across the calls would let a self-posting body drain
     * forever and starve the occurrence loop.
     */
    private void drainPosted() {
        List<Consumer<Tx>> batch;
        synchronized (postLock) {
            if (posted.isEmpty()) {
                return;
            }
            batch = posted;
            posted = new ArrayList<>();
        }
        for (Consumer<Tx> body : batch) {
            dispatch(body);
        }
    }

    private void dispatch(Consumer<Tx> handler) {
        try {
            build(handler);
        } catch (RuntimeException e) {
            System.err.println("kaya: handler threw (transaction rolled back): " + e);
        }
    }

    private void loop() throws Throwable {
        long data = KayaRing.dataAddress();
        long headAddr = KayaRing.headAddress();
        long tailAddr = KayaRing.tailAddress();
        int mask = KayaRing.capacity() - 1;

        int h = (int) GET_INT.invokeExact(headAddr);
        while (true) {
            // Posted work first, then the ring, then park. Draining at
            // the TOP is what makes a wake sufficient: whatever brought
            // this thread back, it looks here before anywhere else.
            drainPosted();
            int t = (int) GET_INT.invokeExact(tailAddr);
            LOAD_FENCE.invokeExact(); // acquire: record reads stay below the tail load
            if (h == t) {
                if (!KayaRing.waitOccurrences()) {
                    return; // shutdown
                }
                continue;
            }
            long at = data + (h & mask);
            int size = (int) GET_INT.invokeExact(at);
            byte[] rec = new byte[size];
            for (int i = 0; i < size; i++) {
                rec[i] = (byte) GET_BYTE.invokeExact(at + i);
            }
            h += size;
            STORE_FENCE.invokeExact(); // release: reads complete before the hand-back
            PUT_INT.invokeExact(headAddr, h);

            KayaWire.Occ occ = KayaWire.parseOccurrence(rec);
            if (occ == null) {
                continue;
            }
            if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED && occ.keys.isEmpty()) {
                Consumer<Tx> handler = widgetHandlers.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED) {
                BiConsumer<Tx, List<Object>> handler = nodeHandlers.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, String> handler = widgetChanges.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (String) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED) {
                ChangeHandler handler = nodeChanges.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (String) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TOGGLED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Boolean> handler = widgetToggles.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TOGGLED) {
                ToggleHandler handler = nodeToggles.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_VALUE_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Double> handler = widgetValues.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (Double) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_VALUE_CHANGED) {
                ValueHandler handler = nodeValues.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (Double) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_CLOSE_REQUESTED) {
                Consumer<Tx> handler = closeRequested.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_WINDOW_CLOSED) {
                // One-shot: the window is gone; both registrations
                // retire with it.
                closeRequested.remove(occ.id);
                Consumer<Tx> handler = windowClosed.remove(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_SECTION_SELECTED) {
                // NOT one-shot: sections never die, and the user can
                // return any number of times (id is the section; the
                // window rides as the payload). A programmatic
                // selectSection never lands here (the echo doctrine).
                Consumer<Tx> handler = sectionSelected.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_ENTRY_POPPED) {
                // One-shot: the entry is gone; both registrations
                // retire with it.
                backRequested.remove(occ.id);
                Consumer<Tx> handler = entryPopped.remove(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BACK_REQUESTED) {
                Consumer<Tx> handler = backRequested.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_ALERT_RESULT) {
                // One-shot: the registration retires with the result;
                // payload is the parsed choice (Integer).
                BiConsumer<Tx, Integer> handler = alerts.remove(occ.id);
                if (handler != null) {
                    dispatch(tx -> handler.accept(tx, (Integer) occ.payload));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_FILE_DIALOG_RESULT) {
                // One-shot like the alert, and the id retires with it.
                // EMPTY IS CANCEL — no platform can confirm an empty
                // selection, so there is no sentinel to invent.
                //
                // A SAVE DIALOG ANSWERS HERE TOO, through the same table
                // and the same id space (docs/save-plan.md D2): its
                // handler was wrapped at show() to take the one
                // destination out of the list, so cancel reaches a save
                // handler as null by the same route it reaches a picker
                // handler as an empty list. One retire, one live slot.
                BiConsumer<Tx, java.util.List<PickedFile>> handler =
                        fileDialogs.remove(occ.id);
                if (handler != null) {
                    @SuppressWarnings("unchecked")
                    java.util.List<PickedFile> files =
                            (java.util.List<PickedFile>) occ.payload;
                    dispatch(tx -> handler.accept(tx, files));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_CLIPBOARD_RESULT) {
                // One-shot like the alert, and the request retires with
                // it. EMPTY IS THE UNIVERSAL NO and arrives as null —
                // denied, unfocused, absent and nothing-we-accept
                // alike, because no platform says which.
                BiConsumer<Tx, Representation> handler = clipboardReads.remove(occ.id);
                if (handler != null) {
                    Representation clip = representation(occ.payload);
                    dispatch(tx -> handler.accept(tx, clip));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_PASTED && occ.keys.isEmpty()) {
                // A paste rides a click tag verbatim, so it arrives on
                // the ordinary widget/node split. Never empty: a paste
                // that delivered nothing is not an occurrence.
                BiConsumer<Tx, Representation> handler = widgetPastes.get(occ.id);
                Representation clip = representation(occ.payload);
                if (handler != null && clip != null) {
                    dispatch(tx -> handler.accept(tx, clip));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_PASTED) {
                PasteHandler handler = nodePastes.get(occ.id);
                Representation clip = representation(occ.payload);
                if (handler != null && clip != null) {
                    dispatch(tx -> handler.accept(tx, occ.keys, clip));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_UNDONE
                    || occ.kind == KayaWire.OCC_KIND_REDONE) {
                // kaya routed an undo: the id is the WINDOW whose ledger
                // moved. NOT one-shot — a history is walked as often as
                // the user likes.
                UndoDelta delta = undoDelta((KayaWire.UndoValues) occ.payload);
                // The model follows FIRST, and UNCONDITIONALLY: the core
                // already moved without a transaction, so an app that
                // registered no handler would otherwise read a stale
                // count from the very next one it does run.
                absorbUndo(delta);
                UndoHandler handler =
                        (occ.kind == KayaWire.OCC_KIND_UNDONE ? undone : redone).get(occ.id);
                if (handler != null) {
                    dispatch(tx -> handler.accept(tx, ((KayaWire.UndoValues) occ.payload).label,
                            delta));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_ACTIVATED && occ.keys.isEmpty()) {
                // Menu occurrences key the menu-item tables — their
                // own id space, so neither widget nor node ids can
                // collide with them. Node-anchored context items carry
                // the stamped copy's keys (the keys ARE the noun);
                // toggles carry the new state, radio groups the new
                // 0-based index.
                Consumer<Tx> handler = menuActivated.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_ACTIVATED) {
                BiConsumer<Tx, List<Object>> handler = menuActivatedNode.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_TOGGLED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Boolean> handler = menuToggled.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_TOGGLED) {
                ToggleHandler handler = menuToggledNode.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_VALUE_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Integer> handler = menuSelected.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (int) (double) (Double) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_VALUE_CHANGED) {
                MenuSelectHandler handler = menuSelectedNode.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (int) (double) (Double) occ.payload);
                    });
                }
            }
        }
    }
}
