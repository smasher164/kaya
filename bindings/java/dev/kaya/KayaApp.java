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
 * kaya's idiomatic surface for the JVM: id allocation, template scoping
 * and occurrence dispatch, layered over KayaRing (the JNI ring access)
 * and the generated wire vocabulary (KayaWire). See DESIGN.md's binding
 * conventions.
 *
 * <p>The ring is read with Unsafe fenced access on raw addresses, which
 * is the one formulation ART does not break (docs/traps.md).
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
    // A NAMED VOCABULARY FOR THE CLOSED HALF of the accept list, because
    // A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
    // clipboard will ever offer, so Paste stays dead and the paste hook
    // never fires, with nothing to see anywhere.
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
     * the widget knows what is selected. copy() and readClipboard() are
     * for overriding that default and for targets with no native
     * behaviour. */
    public static final String ROLE_CUT = "cut";

    public static final String ROLE_COPY = "copy";

    public static final String ROLE_PASTE = "paste";

    /** Undo asks the FOCUSED widget first — a text widget whose native
     * stack has something to give answers before the core's ledger does
     * — and works out its own enablement (docs/undo-plan.md D6). An app
     * that declares them writes nothing else for undo except
     * {@link Tx#undoable}. */
    public static final String ROLE_UNDO = "undo";

    public static final String ROLE_REDO = "redo";

    /**
     * A container's cross-axis child placement. Baseline is rows-only —
     * the root rejects it on columns.
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
     * never how it looks. Each variant fits one kind, and the ROOT
     * refuses the misfits at declare time.
     *
     * <p>Not to be confused with the {@code ROLE_*} string constants
     * above: those are the MENU role vocabulary, a different tier with a
     * different wire prop.
     */
    public enum Role {
        /** An action whose press destroys something — buttons. */
        DESTRUCTIVE(KayaWire.ROLE_DESTRUCTIVE),
        /** THE primary action — buttons. */
        PROMINENT(KayaWire.ROLE_PROMINENT),
        /** A text hierarchy heading — labels. The platform's heading
         * text style AND the accessibility heading trait. */
        HEADING(KayaWire.ROLE_HEADING);

        final long wire;

        Role(long wire) {
            this.wire = wire;
        }
    }

    /**
     * THE SEMANTIC ICON VOCABULARY (spec enum "symbol";
     * docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
     * An app names a CONCEPT and each backend draws its own platform's
     * glyph. The blob {@code icon} slot stays for app-specific art.
     *
     * <p>Growing the set is a spec change, never a per-app escape hatch,
     * and THE WIRE VALUES ARE APPEND-ONLY: renumbering silently redraws
     * every shipped app's menus.
     */
    public enum Symbol {
        ADD(KayaWire.SYMBOL_ADD),
        REMOVE(KayaWire.SYMBOL_REMOVE),
        /** Destroying something, the wastebasket idiom — distinct from
         * {@link #REMOVE}, which takes an item out of a list. */
        DELETE(KayaWire.SYMBOL_DELETE),
        EDIT(KayaWire.SYMBOL_EDIT),
        /** Confirmation, the checkmark idiom. */
        DONE(KayaWire.SYMBOL_DONE),
        /** Dismissal, the ✕ idiom — not {@link #DELETE}. */
        CLOSE(KayaWire.SYMBOL_CLOSE),
        SEARCH(KayaWire.SYMBOL_SEARCH),
        SETTINGS(KayaWire.SYMBOL_SETTINGS),
        REFRESH(KayaWire.SYMBOL_REFRESH),
        INFO(KayaWire.SYMBOL_INFO),
        WARNING(KayaWire.SYMBOL_WARNING),
        /** The direction-relative pair: every platform mirrors these
         * under a right-to-left layout, so they mean BACKWARD and
         * FORWARD in reading order, never "left" and "right". */
        BACK(KayaWire.SYMBOL_BACK),
        FORWARD(KayaWire.SYMBOL_FORWARD),
        /** The overflow affordance (the ellipsis idiom). */
        MORE(KayaWire.SYMBOL_MORE),
        COPY(KayaWire.SYMBOL_COPY),
        PASTE(KayaWire.SYMBOL_PASTE),
        /** Favourite. */
        STAR(KayaWire.SYMBOL_STAR),
        LOCK(KayaWire.SYMBOL_LOCK),
        /** A person or account. */
        PERSON(KayaWire.SYMBOL_PERSON),
        HOME(KayaWire.SYMBOL_HOME);

        final long wire;

        Symbol(long wire) {
            this.wire = wire;
        }
    }

    /**
     * WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
     * "platform"; docs/styling-plan.md Slice 2b).
     *
     * <p>AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
     * {@code Platform.current()} and there will not be — and Java is the
     * binding that proves why: the JVM reports {@code os.name = Linux}
     * on Android, so a guest resolving its own platform here would
     * silently ship the linux family to every phone. Every row travels
     * to every backend, and each backend picks its own.
     */
    public enum Platform {
        MAC(KayaWire.PLATFORM_MAC),
        IOS(KayaWire.PLATFORM_IOS),
        LINUX(KayaWire.PLATFORM_LINUX),
        WINDOWS(KayaWire.PLATFORM_WINDOWS),
        ANDROID(KayaWire.PLATFORM_ANDROID);

        final long wire;

        Platform(long wire) {
            this.wire = wire;
        }
    }

    // The brand/identity record mask bits. HAND-WRITTEN, because they are
    // the one part of those records the generator emits no constant for,
    // so they are named once here rather than left as bare numbers in the
    // calls. Each says a slot in the record's tail means something (an
    // empty string rides there when it does not, so the field count never
    // varies with the payload).
    private static final int BRAND_MASK_LIGHT = 1;
    private static final int BRAND_MASK_DARK = 2;
    private static final int TYPEFACE_MASK_FONT = 1;
    private static final int IDENTITY_MASK_ICON = 1;

    private long signals, widgets, collections, nodes, menuItems;
    private final Map<Long, Consumer<Tx>> widgetHandlers = new HashMap<>();
    // Table sort requests, keyed by the For container's widget id
    // (docs/tables-plan.md): the handler receives the 0-based column.
    private final Map<Long, BiConsumer<Tx, Integer>> sortHandlers = new HashMap<>();
    // Menu dispatch tables, keyed by MENU ITEM id — their own id space,
    // separate from every widget/node table. The node flavors receive
    // the stamped copy's key path.
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
    // Undo/redo handlers, keyed by WINDOW because the ledger is. NOT
    // one-shot, unlike the alert's: a history is walked as often as the
    // user likes.
    private final java.util.Map<Long, UndoHandler> undone = new java.util.HashMap<>();
    private final java.util.Map<Long, UndoHandler> redone = new java.util.HashMap<>();
    // How to rebuild a collection entry's model value from the wire
    // fields an undo hands back. Registered where the collection is
    // declared, the only place the guest's type is known.
    final Map<Long, java.util.function.BiFunction<Integer, List<Object>, Object>> rebuild =
            new HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> windowClosed = new java.util.HashMap<>();
    private final Map<Long, ToggleHandler> nodeToggles = new HashMap<>();
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel. The ambient app/tx pair exists for the generated row
    // traces — an Iterable is static code (one app per guest process).
    static KayaApp ambient;
    Tx currentTx;
    final java.util.List<Long> parents = new java.util.ArrayList<>();
    int openTraces;
    // >0 while a template body is being declared (a For body, a When
    // body, or an open row trace); openFors tracks Fors only. The
    // template records once and replays, so a model read inside its body
    // would bake one snapshot into every stamp — mirror reads throw
    // while this is armed; live-zone, handler and build reads stay legal.
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
     * the one representation that arrived. */
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
     * Value as an F64. */
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

    /** One field's restored text: an EMPTY {@code path} means {@code id}
     * is a live widget's, and a non-empty one means it is the template
     * node of a stamped copy, at that key path.
     *
     * <p>THE DELTA IS THE ONLY NOTIFICATION: restoring a typing episode
     * is a programmatic write and never echoes, so an app folding
     * {@code onChange} into its own model would go stale on exactly this
     * step if the payload did not carry it (docs/undo-plan.md D5). */
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
     * binding diffs anything of its own.
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
     * VALUE_I64, so a guest that writes {@code insert(tx, 7, ...)} has
     * put a numeric key in the same space the minter draws from.
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

    /** The alert chain: accumulates the one atomic SHOW_ALERT record and
     * sends it at show(). A chain that never calls show() sends
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

    /** One representation, arriving — the sum a copy is the record of.
     * YOU OFFER MANY AND YOU RECEIVE ONE, which is why this is a sealed
     * interface and not a record of optional fields. */
    public sealed interface Representation {
        record Text(String value) implements Representation {}

        record Html(String value) implements Representation {}

        /** Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE —
         * the hosts convert freely between image types — so compare
         * what the image IS, never the bytes it arrived in. */
        record Image(byte[] bytes) implements Representation {}

        /** Files, plural INSIDE one representation — the same nesting
         * text/uri-list and CF_HDROP already have. */
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
     * <p>A LIST AND NOT A MASK, because half the set is open-ended. Ids
     * reach every platform's registry verbatim, so they carry no spaces
     * — which is what makes the join unambiguous. */
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

    /** One file the picker answered with. localPath is a RE-OPENABLE
     * NAME, empty unless re-opening actually works — the three desktops
     * and neither phone (DESIGN.md, File dialogs). */
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
     * <p>JAVA IS THE ONE LANGUAGE THAT NEEDS TWO OBJECTS HERE, and this
     * is the whole of the carve-out (DESIGN.md, Binding conventions;
     * docs/save-plan.md D3). Every other binding hands back ONE duplex
     * object whose permitted operations follow the mode. Java's stream
     * types are unidirectional and no public API wraps a descriptor in a
     * duplex object at all ({@code RandomAccessFile} takes a path, and a
     * channel from either stream carries that stream's one direction),
     * so read-write hands
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

        public boolean seekable() {
            return seekable;
        }

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

    /**
     * WHAT THIS HOST CAN DO — crates/kaya/src/app.rs carries the
     * canonical note. Named booleans, never the bits.
     *
     * <p>CAPABILITIES INFORM; WALLS REFUSE: a false here is not what
     * makes a call illegal, it lets a guest ask before it walks into the
     * wall.
     *
     * <p>THE JVM TIER NEEDS THIS MOST: one source is compiled twice
     * (javac for the desktops, gradle for Android) and Java has no
     * conditional compilation, so a guest here cannot spell a platform
     * predicate the way Rust's {@code #[cfg]} and Go's build tags do.
     *
     * @param auxWindows the host can materialize a surface beside the
     *     primary one ({@code tx.createWindow}, {@code tx.mountIn}).
     *     False on Android, whose system owns surface geometry; there
     *     {@code createWindow} aborts at the root.
     */
    public record Capabilities(boolean auxWindows) {}

    /**
     * The core's number written again — there is no header on this tier
     * to read {@code KAYA_CAP_AUX_WINDOWS} out of, the way Go's cgo and
     * Swift's bridging header do. tools/check-sugar-surface.sh reads the
     * authoritative value out of crates/kaya/src/scene.rs and fails if
     * this line disagrees, so the copy cannot go stale in silence.
     */
    private static final long CAP_AUX_WINDOWS = 1;

    /**
     * This host's capabilities. Constant for the life of the process,
     * so asking once and remembering is fine.
     */
    public static Capabilities capabilities() {
        long bits = KayaRing.capabilities();
        return new Capabilities((bits & CAP_AUX_WINDOWS) != 0);
    }

    /**
     * OPEN AN ASSET — a file this app's own BUILD put where the running
     * program can find it (docs/assets-plan.md).
     *
     * <p>{@code name} is a relative path under the asset root, spelled
     * with {@code /} — {@code KayaApp.asset("fonts/sora-wght.ttf")}. The
     * root is kaya's problem and not an app's; no guest reads an asset
     * environment variable or carries a repo-relative default
     * (tools/check-assets.sh).
     *
     * <p>A MISS THROWS, with the core's sentence and nothing added, so
     * every language names the same fault in the same words. An
     * {@link IllegalStateException} because a name the build did not
     * ship is a declaration bug and the answer never changes on a retry.
     *
     * <p>TWO REDEMPTIONS. {@link Tx#brandTypeface(String, Map, Asset)},
     * {@link Tx#appIdentity(String, Asset)} and {@link Tx#image(Asset)}
     * take the handle itself and the bytes never enter the JVM's heap;
     * {@link Asset#bytes()} is for a guest that is ITSELF the consumer,
     * and copies once.
     *
     * <p>READ-ONLY, STRUCTURALLY: no mode argument, no descriptor.
     *
     * <p>EACH CALL READS. No cache, no watch, no reload.
     */
    public static Asset asset(String name) {
        byte[] wire = name.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Asset.sweep();
        long handle = KayaRing.assetOpen(wire);
        if (handle == 0) {
            throw new IllegalStateException(new String(
                    KayaRing.assetMissSentence(wire),
                    java.nio.charset.StandardCharsets.UTF_8));
        }
        return new Asset(handle);
    }

    /**
     * Why {@link #asset(String)} would throw — the sentence it would
     * carry, handed over without throwing. {@code ""} means the name
     * resolves.
     *
     * <p>Line 1 (name, rule, census) is the same on every platform and is
     * the line a scene freezes; line 2 names the resolved place, which
     * three platforms spell three ways.
     *
     * <p>Why a query and not just the throw: docs/deferred.md, the assets
     * entry. The sentence has one author, {@code asset_why_not} in
     * crates/kaya/src/assets.rs.
     */
    public static String assetMissSentence(String name) {
        byte[] wire = name.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        return new String(
                KayaRing.assetMissSentence(wire),
                java.nio.charset.StandardCharsets.UTF_8);
    }

    /**
     * An open asset: the bytes kaya read, held by the core until this is
     * released.
     *
     * <p>RELEASE IS EXPLICIT — {@link #close()}, and it is
     * {@link AutoCloseable} so try-with-resources spells it — AND a
     * guest that forgets still leaks nothing, because an unreachable
     * Asset's handle is released the next time any asset is opened or
     * closed.
     *
     * <p>WHY A PHANTOM REFERENCE AND NOT A FINALIZER: {@code
     * Object.finalize} is deprecated for removal (JEP 421), and its
     * replacement {@code java.lang.ref.Cleaner} arrived on Android at
     * API 33 while this file compiles at minSdk 26
     * (android/kaya/build.gradle.kts) — a Cleaner would link on the
     * desktops and die at first use on a phone. The reference holds the
     * HANDLE NUMBER, never the Asset, which a finalizer closing over its
     * own subject would keep alive forever.
     */
    public static final class Asset implements AutoCloseable {
        private static final java.lang.ref.ReferenceQueue<Asset> DEAD =
                new java.lang.ref.ReferenceQueue<>();

        /** The live phantoms, kept reachable: a PhantomReference nobody
         * holds is collected itself, and then it never enqueues. */
        private static final java.util.Set<Tomb> TRACKED =
                java.util.Collections.synchronizedSet(new java.util.HashSet<>());

        private static final class Tomb extends java.lang.ref.PhantomReference<Asset> {
            private final long handle;

            Tomb(Asset asset, long handle) {
                super(asset, DEAD);
                this.handle = handle;
            }
        }

        /** Release every asset the collector has already reclaimed.
         * Called at each open and each close. */
        static void sweep() {
            java.lang.ref.Reference<? extends Asset> dead;
            while ((dead = DEAD.poll()) != null) {
                Tomb tomb = (Tomb) dead;
                TRACKED.remove(tomb);
                KayaRing.assetRelease(tomb.handle);
            }
        }

        private final long handle;
        private final Tomb tomb;
        private boolean open = true;

        Asset(long handle) {
            this.handle = handle;
            this.tomb = new Tomb(this, handle);
            TRACKED.add(this.tomb);
        }

        /**
         * THE BYTES REDEMPTION: this asset's bytes, copied out of core
         * memory, a fresh array each call.
         */
        public byte[] bytes() {
            alive();
            return KayaRing.assetBytes(handle);
        }

        /**
         * The same bytes as a stream, for the java.io consumers that
         * want one. IN-MEMORY AND NOT A FILE: a
         * {@link java.io.ByteArrayInputStream} over {@link #bytes()},
         * with no descriptor anywhere.
         */
        public java.io.ByteArrayInputStream stream() {
            return new java.io.ByteArrayInputStream(bytes());
        }

        /**
         * THE BLOB REDEMPTION, for the consumers inside this binding:
         * register these bytes into the pending table and answer with
         * the handle the record carries. The bytes never enter the JVM's
         * heap. Package-private on purpose.
         */
        long blob() {
            alive();
            return KayaRing.assetBlob(handle);
        }

        /**
         * Let the core drop these bytes. Idempotent, and the sweep that
         * runs here retires anything the collector reclaimed since the
         * last open.
         */
        @Override
        public void close() {
            if (open) {
                open = false;
                KayaRing.assetRelease(handle);
            }
            sweep();
        }

        private void alive() {
            if (!open) {
                throw new IllegalStateException(
                        "kaya: this asset is closed — an asset's bytes live in "
                        + "the core until close(), and a use after that has "
                        + "nothing to read; open it again with KayaApp.asset");
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
     * <p>ONE ID SPACE AND ONE TABLE with the picker: the answer comes
     * back as a file_dialog_result and one dialog of either kind is live
     * per process. The narrowing to at-most-one file happens HERE rather
     * than in every app. */
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
     * <p>A RECORD AND NOT A LIST: at most one per kind is structural,
     * since a second text() replaces the field. */
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

        /** Offer a picked file: the bytes never move through kaya. */
        public CopyRef file(PickedFile f) {
            files.add(f.handle());
            return this;
        }

        /** An app-defined format, round-tripped verbatim. The id reaches
         * every platform's own registry unchanged — a UTI on Apple,
         * RegisterClipboardFormat on Windows, a target atom on X11 and
         * Wayland, a MIME type on Android — so it carries no spaces. */
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
         * FIRST, in the order named. */
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
         * Binds the undone handler to THIS window: fires each time kaya
         * routes an undo here, with the group's authored label (EMPTY
         * for a typing episode) and what the core put back.
         *
         * <p>NOT ONE-SHOT: a history is walked as often as the user
         * likes, and the registration outlives every step.
         *
         * <p>THE DELTA IS THE ONLY NOTIFICATION. Applying an inverse is
         * a programmatic write, so the echo doctrine silences every
         * occurrence it would cause. The binding's own model is already
         * folded before the handler runs; this is where an app folds it
         * into ITS model.
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
         * platform's own affordance (docs/dirty-plan.md D2/D4).
         *
         * <p>STATE, NOT CHROME: the title you declared is left alone. It
         * ARMS NOTHING either — "unsaved changes, close anyway?" is
         * {@link #vetoClose} plus a dialog, yours to compose.
         */
        public WindowRef dirty(boolean on) {
            tx.emit(KayaWire.txSetWindowDirty(id, on));
            return this;
        }

        /**
         * The window CONTENT INSET, in layout units — LAYOUT, not
         * appearance (docs/styling-plan.md D3). 16 unless you say
         * otherwise; 0 is full bleed.
         *
         * <p>A platform's SAFE AREA is a separate fact and is not
         * removed by it: content extends to the safe-area edge, not past
         * it. Negative is refused at the root.
         */
        public WindowRef inset(double units) {
            tx.emit(KayaWire.txSetWindowInset(id, units));
            return this;
        }

        /**
         * The CEILING on how many of this window's stack entries present
         * side by side: 1 is the serial stack, 2 and 3 are columns on a
         * window wide enough, the shallowest shed first as it narrows
         * (docs/multicolumn-plan.md carries the ruling and the measured
         * mechanics).
         *
         * <p>There is deliberately no argument for WHICH entries show —
         * the stack's order is the priority order — and the live count is
         * the platform's own judgment where it has one. The root refuses
         * 0 and anything above 3.
         */
        public WindowRef panes(int ceiling) {
            tx.emit(KayaWire.txSetWindowPanes(id, ceiling));
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
         * A top-level menu in this window's command catalog (DESIGN.md,
         * Menus): tx.window(0).menu("File") returns the retained
         * grouping handle, whose creators append the children —
         * file.item("Save").shortcut("primary+s").onActivate(fn).
         */
        public MenuItem menu(String label) {
            MenuItem m = tx.newMenuItem(KayaWire.MENU_KIND_MENU, label, false);
            tx.emit(KayaWire.txMenubarAppend(id, m.id));
            return m;
        }

        /**
         * A BAR-LEVEL radio group. Declare only option() children and
         * chain value() AFTER them (the selected 0-based index;
         * programmatic writes are quiet).
         */
        public MenuItem radioGroup(String label) {
            MenuItem m = tx.newMenuItem(KayaWire.MENU_KIND_RADIO_GROUP, label, false);
            tx.emit(KayaWire.txMenubarAppend(id, m.id));
            return m;
        }
    }

    /**
     * A live menu item. The id alone is the item's durable name; the
     * chain methods ride the transaction that minted the value and die
     * with it, and tx.menu(item) reopens a retained handle in a later
     * transaction (append-at-any-time; nothing is removed in v1).
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
         * menu_activated occurrence for a click OR its shortcut. */
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

        /** The item's SEMANTIC ICON ({@link Symbol}): the closed concept
         * vocabulary each backend maps to its own platform's symbol set.
         * Beside {@link #icon(byte[])}, not instead of it — app-specific
         * art still rides the blob. Const-only. */
        public MenuItem symbol(Symbol symbol) {
            chain().emit(KayaWire.txSetMenuSymbol(id, symbol.wire));
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
         * root-checked). PLACEMENT is each host's business. One item per
         * role, and a role never invents a chord — spell shortcut() too
         * if the app wants one. Const-only. */
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
         * one option of a group (window-anchored only). Canonicalized by
         * KayaWire.canonicalizeShortcut; it fires the SAME occurrence a
         * click does. Const-only. */
        public MenuItem shortcut(String spelling) {
            if (ctx) {
                throw new IllegalStateException(
                        "kaya: a context item takes no shortcut — a shortcut needs"
                                + " a window catalog as its native dispatch home");
            }
            chain().emit(KayaWire.txSetMenuShortcut(id, spelling));
            return this;
        }

        /** Binds this action's handler; a click and its shortcut are ONE
         * occurrence, so it covers both. */
        public MenuItem onActivate(Consumer<Tx> fn) {
            chain();
            app.menuActivated.put(id, fn);
            return this;
        }

        /** The template-node flavor: an item attached to a stamped copy
         * reports the copy's key path, outermost first. */
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

        public MenuItem menu(String label) {
            return root(KayaWire.MENU_KIND_MENU, label);
        }

        /** Collects a radio-group root; chain onSelectNode. */
        public MenuItem radioGroup(String label) {
            return root(KayaWire.MENU_KIND_RADIO_GROUP, label);
        }

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

        /** The switcher item's SEMANTIC ICON ({@link Symbol}): a concept
         * each backend draws in its own platform's symbol set — a tab bar
         * without icons is not the platform's real thing, and a blob is
         * the wrong primitive for a STANDARD one. */
        public SectionRef symbol(Symbol symbol) {
            tx.emit(KayaWire.txSetSectionSymbol(id, symbol.wire));
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

    /**
     * The header bar's sort indicator (docs/tables-plan.md): which
     * column shows it, in which direction — the GUEST's declaration,
     * re-sent with the new state after it handles a sort request. The
     * platform never sorts; a header click only asks.
     */
    public static final class Sort {
        final int sorted;
        final int direction;

        private Sort(int sorted, int direction) {
            this.sorted = sorted;
            this.direction = direction;
        }

        /** The no-indicator bar. */
        public static Sort none() {
            return new Sort(0xFFFFFFFF, 0);
        }

        /** Ascending on {@code column} (0-based, declared order). */
        public static Sort asc(int column) {
            return new Sort(column, 0);
        }

        /** Descending on {@code column}. */
        public static Sort desc(int column) {
            return new Sort(column, 1);
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
         * Weight this widget within its row/column at construction.
         *
         * <p>THE DISCIPLINE EVERY CHAIN METHOD BELOW SHARES: it appends
         * to the transaction that minted the widget, so it belongs in
         * the build body and fails loudly on a Widget that outlived its
         * build. Use the Tx.set* verb for a dynamic change.
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

        /** This container's inter-child gap at construction:
         * tx.column(() -> {...}).spacing(12). */
        public Widget spacing(double gap) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: spacing on a widget outside its build transaction"
                    + " — use Tx.setSpacing inside a live transaction");
            }
            tx.setSpacing(this, gap);
            return this;
        }

        /** This container's own padding at construction:
         * tx.row(() -> {...}).inset(8) — the window inset one level
         * down, so a full-bleed window can still hold an inset row. */
        public Widget inset(double pad) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: inset on a widget outside its build transaction"
                    + " — use Tx.setInset inside a live transaction");
            }
            tx.setInset(this, pad);
            return this;
        }

        /** This container's cross-axis child placement at construction:
         * tx.row(() -> {...}).align(Align.BASELINE). */
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
         * This widget's SEMANTIC EMPHASIS at construction:
         * tx.button("Delete").role(Role.DESTRUCTIVE). What the widget
         * MEANS, never how it looks; the root refuses a role on a kind
         * it does not fit, at declare time.
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

        /** This widget's accessibility identifier at construction:
         * tx.entry().a11yId("name"). */
        public Widget a11yId(String id) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: a11yId on a widget outside its build transaction"
                    + " — use Tx.setA11yId inside a live transaction");
            }
            tx.setA11yId(this, id);
            return this;
        }

        /** This widget's accessibility hint at construction. */
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
         * registration (setOnReceiveContentListener takes the mime types
         * on the view).
         *
         * <p>DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget
         * that declares nothing gets the platform's own insertion and
         * reports it through the ordinary change path. */
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
     * converts before a backend sees it (docs/ranges-units.md).
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
         * different amount: docs/ranges-units.md §4). Neither
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
     * key per enclosing For.
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

        // A For binds the collection itself, so handing it an at(...)
        // handle is a bug.
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
         * once over the scalar row surface, a break is caught at submit,
         * and the trace rides the zone it opens in, so statement traces
         * nest. The record twin is the generated {@code <Type>Kaya.rows}.
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
     * <p>ONE FORWARDING LIST, WHICH IS THE POINT: the forwards live here
     * once and both façades inherit them, so no surface can hand-list a
     * subset of the zone. The annotation processor emits tokens and
     * typed handlers, never a constructor list. tools/tpl-surfaces.py
     * holds the two level.
     *
     * <p>Handlers register the way they do everywhere in this zone —
     * {@code app.onClick(node, (tx, keys) -> …)} — because a stamped
     * copy's event names the copy.
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

        // THE LEVEL-TAKING BINDS. The constructors above bind at level
        // 0 — this row's own element — so these are the only way to read
        // an OUTER row's field from a nested template, and the a11y
        // three below (bindA11yIdField and its siblings) were forwarded
        // while these five were not. That left one mechanism half
        // present: a guest inside a nested for-statement could name the
        // outer row's field for a stamped node's accessibility id and
        // not for its text, its checked state, its image source or its
        // value. The asymmetry was drift, not design.

        /** Bind this row's copy of that node's text to the element of an
         * enclosing For, {@code level} Fors up (0 = nearest)
         * ({@link Tpl#bindTextElement}). */
        public void bindTextElement(Node n, int level) {
            t.bindTextElement(n, level);
        }

        /** …and to one FIELD of that element, the String token pinning
         * the pairing at compile time ({@link Tpl#bindTextField}). */
        public void bindTextField(Node n, int level, KayaRecords.Field<String> f) {
            t.bindTextField(n, level, f);
        }

        /** An outer row's Boolean field as this copy's checked state
         * ({@link Tpl#bindCheckedField}). */
        public void bindCheckedField(Node n, int level, KayaRecords.Field<Boolean> f) {
            t.bindCheckedField(n, level, f);
        }

        /** An outer row's byte[] field as this copy's image source
         * ({@link Tpl#bindSourceField}). */
        public void bindSourceField(Node n, int level, KayaRecords.Field<byte[]> f) {
            t.bindSourceField(n, level, f);
        }

        /** An outer row's Double field as this copy's slider position,
         * progress fraction or selected index — a Double token and only
         * ever a Double one ({@link Tpl#bindValueField} states why). */
        public void bindValueField(Node n, int level, KayaRecords.Field<Double> f) {
            t.bindValueField(n, level, f);
        }

        /** One of this row's nodes' flex weight — a Node carries no
         * transaction, so a setter after construction is the spelling
         * rather than a chain ({@link Tpl#setGrow}). */
        public void setGrow(Node n, double weight) {
            t.setGrow(n, weight);
        }

        /** What this row's copy of that node MEANS — semantic emphasis,
         * a constant describing the prototype ({@link Tpl#setRole}).
         * The "delete <that row's title>" button is this zone's forcing
         * case: a stamped destructive action was declarable in no
         * language until the template zone could spell the prop. */
        public void setRole(Node n, Role role) {
            t.setRole(n, role);
        }

        /** How far this row's copy of that container holds its children
         * off its own edge ({@link Tpl#setInset}) — a constant, and
         * container kinds only. */
        public void setInset(Node n, double pad) {
            t.setInset(n, pad);
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

        /**
         * A When inside this row's template: the subtree stamps when the
         * signal is true and unstamps when it goes false
         * ({@link Tpl#when(Signal, Consumer)}).
         *
         * <p>FORWARDED BECAUSE THE WRONG ONE IS IN REACH: a When has no
         * statement-level spelling, and the {@code tx.when} a guest
         * would reach for instead mints a LIVE widget id where this zone
         * needs a template node id, with nothing to say so.
         */
        public Node when(Signal<Boolean> s, Consumer<Tpl> body) {
            return t.when(s, body);
        }

        /** A When whose body returns the handles it declared, for the
         * same reason {@link Tpl#forEach} has that arity: a Java lambda
         * cannot assign a captured local. */
        public <R> Stamped<Node, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            return t.when(s, body);
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

    /**
     * A stamped template: the For/When handle in the enclosing zone plus
     * whatever the body chose to return — the way handles declared
     * inside the template reach the handlers, since Java lambdas cannot
     * assign captured locals.
     */
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
         * transaction, so the liveness check cannot be forgotten at a
         * new callsite. A write through a Tx that outlived its build
         * vanishes with no error (tools/check-tx-liveness.sh).
         */
        private void emit(byte[] record) {
            alive();
            records.add(record);
        }

        /**
         * The head-of-batch undo marker, or null. Held apart from
         * {@code records} rather than inserted at index 0, because
         * {@link #emit} must stay the one and only append (a second
         * append would skip the liveness check — see
         * tools/check-tx-liveness.sh). Prepended by {@link #submitIfAny}.
         */
        private byte[] undoGroup;

        /**
         * Make this transaction ONE undoable step, under {@code label}.
         * Opt-in per transaction (docs/undo-plan.md D2, D8).
         *
         * <p>CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides
         * at the head of the batch.
         *
         * <p>WHAT A GROUP MAY HOLD is the reactive half — signal writes
         * and collection deltas. Focus is permitted and not restored.
         * Anything else (a const property write, creating a widget,
         * clear, showing a dialog) fails at apply, naming the op. The app
         * hears the result through {@link WindowRef#onUndone}.
         */
        public void undoable(String label) {
            undoableIn(0, label);
        }

        /**
         * {@link #undoable} against an auxiliary window's ledger: each
         * window has its own history.
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
            requireAppThread();
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
         * A container's own padding: DIP between its bounds and its
         * children, uniform on all four sides — the window inset one
         * level down (docs/styling-plan.md D3). Containers only — the
         * scene rejects it anywhere else. The dynamic path; the
         * declarative spelling is the inset chain at construction.
         */
        public void setInset(Widget w, double pad) {
            emit(KayaWire.txSetInset(w.id, pad));
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

        public Widget image(Signal<byte[]> s) {
            Widget w = widget(KayaWire.KIND_IMAGE);
            bindSource(w, s);
            return w;
        }

        /**
         * The ASSET form of the source slot: the same image, showing the
         * picture named rather than read — {@code
         * tx.image(KayaApp.asset("icons/kaya-mark.png"))}.
         *
         * <p>THE BYTES NEVER ENTER THE JVM'S HEAP: the core hands its own
         * buffer to the blob table, so a picture costs one refcount here
         * and no array. {@link #appIdentity(String, Asset)}'s route,
         * verbatim.
         */
        public Widget image(Asset source) {
            if (source == null) {
                throw new IllegalArgumentException(
                        "kaya: image got no asset — open one with "
                        + "KayaApp.asset(\"icons/...\"), or pass encoded bytes");
            }
            Widget w = widget(KayaWire.KIND_IMAGE);
            emit(KayaWire.txSetSource(w.id, source.blob()));
            return w;
        }

        public void addChild(Widget parent, Widget child) {
            emit(KayaWire.txAddChild(parent.id, child.id));
        }

        /**
         * Drop the widget's owned content — a one-shot command riding
         * this transaction, so the insert and the clear beside it commit
         * together or not at all. The widget answers through its normal
         * occurrence path: a clear arrives back as a text change with
         * empty text.
         */
        public void clear(Widget w) {
            emit(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_CLEAR));
        }

        /** Give the widget keyboard focus — a one-shot command riding
         * the transaction like clear. */
        public void focus(Widget w) {
            emit(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_FOCUS));
        }

        /**
         * DECLARE the decorated ranges of a textarea, replacing
         * whatever was declared before; an empty list is the clear.
         *
         * <p>kaya ships no search — finding the hits is the app's, and
         * {@link TextRange#in} is where its indices meet kaya's unit
         * (docs/ranges-plan.md §3).
         *
         * <p>APP-OWNED AND NEVER TRACKED. The first edit of any kind —
         * a keystroke, a programmatic write, a native undo — drops the
         * whole set with nothing said, and the app re-declares from the
         * fold its change handler already keeps. Nothing in kaya adjusts
         * a range across an edit (D2).
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
         * model (docs/ranges-plan.md D4). The refusal is a NO-OP AND NOT
         * AN EXCEPTION: composition state is on no kaya channel. Ask
         * again after the next change occurrence, which is what ends a
         * composition.
         */
        public void selectRange(Widget w, TextRange range) {
            emit(KayaWire.txSelectRange(w.id, range.start, range.stop));
        }

        /**
         * Scroll the textarea so a range is inside the viewport. A pure
         * effect: it moves no state, leaves the selection alone, and
         * undo does not put the scroll position back. How much context
         * lands around the range is the platform's own behaviour; kaya
         * fixes containment.
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
        /**
         * Declare the column header bar on a For's container — the
         * Widget forEach returns. One title per column; the row
         * template's root must be a Row of exactly one cell per
         * column, refused loudly otherwise. Re-call after sorting to
         * move the indicator (docs/tables-plan.md).
         */
        public void columns(Widget w, String[] titles, Sort sort) {
            Object[] values = new Object[titles.length];
            System.arraycopy(titles, 0, values, 0, titles.length);
            emit(KayaWire.txSetColumnHeaders(
                w.id, sort.sorted, sort.direction, titles.length, values));
        }

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

        /** Open a For template for a generated row trace. A break leaves
         * the trace open — caught at submit. The For rides the zone it
         * opens in: the widget id space in the live zone, the node space
         * inside an enclosing template. */
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
         * <p>FOR DATA THAT HAS NO IDENTITY OF ITS OWN; anything that
         * already HAS a name passes it to {@link #insert}
         * (docs/fresh-key-plan.md).
         *
         * <p>ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the
         * minted key is I64 and is counter+1. An instance is a table —
         * the live-zone collection, or one stamped copy selected by
         * {@code at(...)}.
         *
         * <p>MIXING IS SAFE BY ABSORPTION: an explicit insert whose key
         * is an I64 at or above the counter carries it up. A String key
         * cannot collide with an I64 and moves nothing.
         *
         * <p>NO DECREMENT IS EXPRESSIBLE: undo and redo replay captured
         * keys inside the core and never re-enter this path, and
         * {@link #rollback} restores the model but not the counters. A
         * fresh key is fresh forever.
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
            // ABSORPTION, on the one path every explicit key travels: a
            // numeric key at or above the minter's counter carries it up
            // (insertFresh's contract).
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
         * Repositions an entry before another's. Keys, never indices. A
         * missing key or anchor throws here, at the call site; moving an
         * entry before itself is a no-op and nothing travels.
         */
        public void moveBefore(Collection c, Object key, Object anchor) {
            moveEntry(c, key, new Object[] { anchor });
        }

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
         * Request a modal alert (the request/result grammar):
         * tx.showAlert().title("delete item?").message("…")
         *     .action("Delete").action("Archive").cancel("Keep")
         *     .onResult((tx, choice) -> …).show().
         * The result handler rides the REQUEST and retires with its one
         * answer — choice is an action index (0 or 1) or
         * KayaWire.ALERT_CHOICE_CANCEL, every platform-native dismissal.
         * Up to two actions (the platform floor); the cancel label is
         * required. One alert may be live per process; show the next
         * from the handler.
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
        // A clip is ONE item available in several types, so copy takes a
        // record (a chain here, where a second text() replaces the
        // field) and the two answers are a sum.

        /** Begin a clip: fill in as many representations as the app
         * wants to offer, and send() puts it on the system clipboard. */
        public CopyRef copy() {
            return new CopyRef(this);
        }

        /** Begin the privileged read. Asking without a gesture is
         * expensive on every platform: iOS 16 PROMPTS when the content
         * came from another app and blocks until the user answers,
         * Android returns nothing unless the app has focus, and Wayland
         * delivers no offer to an unfocused client. Never implement
         * Paste with this — that is the Paste command, and it is
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
         * kaya derives every other number from it.
         *
         * <p>THE APP NEVER WRITES A FOREGROUND and never writes contrast
         * variants: the core derives fill, on-fill, standalone and a
         * hover/pressed ramp per appearance.
         *
         * <p>A REQUEST, NOT A COMMAND: a platform may let its user
         * override the app's accent (macOS does today).
         *
         * <p>SET ONCE, BEFORE THE FIRST MOUNT. The root refuses a second
         * write and a late one.
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
            // The mask says which overrides ride along; the wire carries
            // 0 for an unstated one (spec.rs's set_brand_accent — bit 0
            // light, bit 1 dark).
            int mask = (light != null ? BRAND_MASK_LIGHT : 0)
                    | (dark != null ? BRAND_MASK_DARK : 0);
            emit(KayaWire.txSetBrandAccent(
                    seed, mask, light != null ? light : 0, dark != null ? dark : 0));
        }

        /**
         * REQUEST the app's brand typeface (docs/styling-plan.md D6,
         * Slice 2b): one family name is the whole call, and every
         * platform that has that family installed uses it.
         *
         * <p>THE FAMILY, NEVER THE SCALE. Sizes, weights, metrics and
         * the whole type ramp stay the platform's.
         *
         * <p>A FAMILY A PLATFORM DOES NOT HAVE leaves that platform's
         * own typeface in place, deliberately: each lowering gates on
         * the family being installed, because every font API renders
         * SOMETHING for a name it cannot match.
         *
         * <p>SET ONCE, BEFORE THE FIRST MOUNT — the accent's wall
         * verbatim.
         */
        public void brandTypeface(String family) {
            // The cast picks the bytes overload rather than the Asset
            // one: two reference types in the same slot make a bare
            // `null` ambiguous, and javac says so at this line rather
            // than in a guest.
            brandTypeface(family, null, (byte[]) null);
        }

        /**
         * The per-platform form, plus the font-BYTES form: {@code
         * family} is the default, {@code platforms} overrides it for the
         * platforms that name themselves, and {@code font} ships a font
         * file whose bytes the backend registers with its platform's
         * app-font API — taking the family that registration names in
         * preference to any name above. Either may be {@code null}, the
         * unstated spelling {@link #brandAccent(int, Integer, Integer)}
         * already uses.
         *
         * <p>THE PAIRS TRAVEL UNRESOLVED, unlike the accent's
         * per-platform values, and that asymmetry is the design: a
         * colour is a number this binding could resolve anywhere, a
         * family name is a lookup only the platform can do. Java is the
         * binding that shows why it must not try — the JVM reports
         * {@code os.name = Linux} on Android — so every row rides the
         * wire and each backend picks its own ({@link Platform}).
         *
         * <p>A {@code Map} rather than a list of pairs. THE WIRE ORDER
         * IS THE ENUM'S, not the map's, so a {@code HashMap} and an
         * {@code EnumMap} of the same rows emit the same record. A
         * {@code null} family travels as the empty string it means, so
         * the refusal comes from the root in the words every other
         * language gets.
         */
        public void brandTypeface(String family, Map<Platform, String> platforms, byte[] font) {
            java.util.List<Object> pairs = new java.util.ArrayList<>();
            if (platforms != null) {
                for (Platform platform : Platform.values()) {
                    if (!platforms.containsKey(platform)) {
                        continue;
                    }
                    String row = platforms.get(platform);
                    // A Long and a String, in that order: read in twos by
                    // the root.
                    pairs.add(platform.wire);
                    pairs.add(row == null ? "" : row);
                }
            }
            // ONE COPY INTO CORE MEMORY, the handle consumed by this
            // transaction's submit — setSource's registration semantics.
            emit(KayaWire.txSetBrandTypeface(
                    font != null ? TYPEFACE_MASK_FONT : 0,
                    family == null ? "" : family,
                    pairs.toArray(),
                    font != null
                            ? new KayaWire.BlobHandle(KayaRing.blobRegister(font))
                            : ""));
        }

        /**
         * The ASSET form of the font slot: the same call, with the font
         * named rather than read — {@code tx.brandTypeface("Sora", null,
         * KayaApp.asset("fonts/sora-wght.ttf"))}.
         *
         * <p>THE BYTES NEVER ENTER THE JVM'S HEAP: this hands the core's
         * own buffer to the blob table, so a font file costs one
         * refcount and no array.
         *
         * <p>Everything else is
         * {@link #brandTypeface(String, Map, byte[])}'s, verbatim.
         */
        public void brandTypeface(String family, Map<Platform, String> platforms, Asset font) {
            java.util.List<Object> pairs = new java.util.ArrayList<>();
            if (platforms != null) {
                for (Platform platform : Platform.values()) {
                    if (!platforms.containsKey(platform)) {
                        continue;
                    }
                    String row = platforms.get(platform);
                    pairs.add(platform.wire);
                    pairs.add(row == null ? "" : row);
                }
            }
            emit(KayaWire.txSetBrandTypeface(
                    font != null ? TYPEFACE_MASK_FONT : 0,
                    family == null ? "" : family,
                    pairs.toArray(),
                    font != null
                            ? new KayaWire.BlobHandle(font.blob())
                            : ""));
        }

        /**
         * DECLARE the app's identity (docs/app-identity-plan.md): the
         * name it goes by and the picture that stands for it, as the
         * bytes of one image file.
         *
         * <p>ONE PICTURE, FIVE PLATFORMS. The same bytes become the
         * macOS Dock tile, the Windows taskbar/alt-tab icon and the
         * caption's mark, and an X11 window's icon; the same FILE, read
         * at build time, becomes the Android launcher icon and the iOS
         * Home Screen icon. Send a PNG: each lowering converts, and no
         * platform-specific artwork rides the wire.
         *
         * <p>SET ONCE, BEFORE THE FIRST MOUNT — the brand's wall
         * verbatim. The root refuses a second write, a late one and an
         * empty name; an app that wants the platform's own identity
         * declares none at all.
         *
         * <p>THE BYTES ARE NEVER INSPECTED between here and the
         * platform's own decoder, so bytes that are not an image leave
         * every platform's default in place.
         */
        public void appIdentity(String name, byte[] icon) {
            // ONE COPY INTO CORE MEMORY, the handle consumed by this
            // transaction's submit — setSource's registration semantics.
            emit(KayaWire.txSetAppIdentity(
                    IDENTITY_MASK_ICON, name,
                    new KayaWire.BlobHandle(KayaRing.blobRegister(icon))));
        }

        /**
         * The ASSET form of the icon slot: the same declaration, with
         * the mark named rather than read — {@code
         * tx.appIdentity("Aurora Notes",
         * KayaApp.asset("icons/kaya-mark.png"))}.
         *
         * <p>THE BYTES NEVER ENTER THE JVM'S HEAP: the core hands its
         * own buffer to the blob table, so a picture costs one refcount
         * here and no array. Everything else is
         * {@link #appIdentity(String, byte[])}'s, verbatim.
         */
        public void appIdentity(String name, Asset icon) {
            emit(KayaWire.txSetAppIdentity(
                    IDENTITY_MASK_ICON, name,
                    new KayaWire.BlobHandle(icon.blob())));
        }

        /**
         * The NAME-ONLY form, for an app that has a name and no mark
         * yet. Its identity still reaches every surface a name reaches,
         * and every icon surface keeps the platform's own default.
         */
        public void appIdentity(String name) {
            // The icon slot rides either way and the mask says whether it
            // means anything, so the record's field count never varies
            // with the payload.
            emit(KayaWire.txSetAppIdentity(0, name, ""));
        }

        /**
         * Create an auxiliary window (capability-gated: phone hosts
         * reject at the root); materializes hidden, mountIn presents.
         */
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

        // PRIVATE, AND THE ONLY PROP WRITE IN THIS ZONE THAT IS: both
        // zones spell this `.setText(` and the sweep that keeps example
        // guests off the explicit tier reads lines rather than types, so
        // it cannot tell which receiver it found. Hiding this one lets
        // the compiler hold the rule a regex could not. KEEP IT PRIVATE.
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
         * INDEX therefore declares that component {@code double}.
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
         * chain here; the setter directly after construction is the
         * spelling, as it is for every prop below.
         */
        public void setGrow(Node n, double weight) {
            tx.emit(KayaWire.txSetGrow(n.id, weight));
        }

        /**
         * What a stamped copy MEANS — semantic emphasis, never
         * appearance, the blueprint twin of
         * {@link Tx#setRole(Widget, Role)}.
         *
         * <p>A CONSTANT, not a source, for {@link #setAccepts}'s reason.
         * The root refuses a role on a kind it does not fit at DECLARE
         * time, before a single row stamps, so there is no type here to
         * say so.
         */
        public void setRole(Node n, Role role) {
            tx.emit(KayaWire.txSetRole(n.id, role.wire));
        }

        /**
         * A stamped CONTAINER's own padding, in DIP — the window inset
         * one level down, the same number {@link Tx#setInset} spells in
         * the live zone.
         *
         * <p>Const for {@link #setRole}'s reason, and container kinds
         * only, which the root says at declare time.
         */
        public void setInset(Node n, double pad) {
            tx.emit(KayaWire.txSetInset(n.id, pad));
        }

        // THE ACCESSIBILITY PROPS, one setter per source: the ARGUMENT'S
        // TYPE picks the source, the same trichotomy the constructors
        // below use.
        //
        // A CONSTANT ID ON EVERY COPY IS LEGAL and nothing catches the
        // collision. Reach for the row's own field only when something
        // outside kaya must tell the copies apart.

        /** A template node's accessibility identifier, one constant for
         * every stamped copy — the blueprint twin of
         * {@link Tx#setA11yId(Widget, String)}. */
        public void setA11yId(Node n, String id) {
            tx.emit(KayaWire.txSetA11yId(n.id, id));
        }

        public void setA11yId(Node n, Signal<String> s) {
            tx.emit(KayaWire.txBindA11yId(n.id, s.id));
        }

        /** An identifier from the row's own field — a per-copy key for
         * whatever addresses these rows from outside. */
        public void setA11yId(Node n, KayaRecords.Field<String> f) {
            bindA11yIdField(n, 0, f);
        }

        /** Bind a node's identifier to one field of the element,
         * {@code level} Fors up (0 = nearest) — the only way to read an
         * OUTER row's field from a nested template. */
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
         * itself. */
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
         * radio). There is no type here to say so — a hint on any other
         * kind fails the BUILD in the root's own words, before a single
         * row stamps.
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
         * <p>WITHOUT THIS {@link KayaApp#onPaste(Node, PasteHandler)}
         * NEVER FIRES: every backend gates the paste occurrence on the
         * focused widget's accept list and falls back to the platform's
         * own insertion when it is empty.
         *
         * <p>A CONSTANT, NOT A SOURCE, unlike the a11y props above: what
         * a control can take is a fact about the PROTOTYPE. On Android
         * it is also the native registration itself (the mime types on
         * the view).
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
         * <p>THE OPTIONS ARE THE PROTOTYPE'S: they are children of the
         * blueprint node, so every copy offers the same list and only
         * the choice varies.
         *
         * <p>Its pick handler is registered against the template node
         * ({@code app.onValueChanged(node, (tx, keys, index) -> …)}) and
         * receives each USER pick's new index; programmatic writes never
         * echo. The index arrives as a {@code double} and the app
         * narrows it, since a template constructor is handed no handler
         * to narrow inside.
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

        /** A radio group over fixed options — {@link #select(String[],
         * int)}'s contract in its inline presentation. */
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

        // The choice kinds' shared head: the option labels. The index is
        // left to the caller's overload so each source keeps its own
        // type all the way to the wire.
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
        requireAppThread();
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

    /** A paste onto a stamped copy: the handler also receives the copy's
     * key path, outermost first. */
    public void onPaste(Node n, PasteHandler handler) {
        nodePastes.put(n.id, handler);
    }

    /**
     * Fold an undo's payload into the collection model.
     *
     * <p>The payload is core-authoritative, so nothing here re-derives
     * anything. Signals and text are not mirrored by this binding (there
     * is no read-back for either), so those two runs pass straight to
     * the app's own handler.
     *
     * <p>NO DERIVED RECOMPUTE HERE, DELIBERATELY. A derived signal's
     * write rode the SAME transaction as the mutation that caused it, so
     * a named step banked the derived value and the core has already
     * restored it. A recompute added here would write a value the ledger
     * never banked, outside any transaction, and the next walk through
     * the history would jump back to the banked one.
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
            // decoder the collection registered when it was declared.
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
            // not name at the end.
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
     * The decoder's shape, typed: the generated parser owns the LAYOUT
     * (counts in the head, one flat Values tail cut into four runs);
     * this owns what the app sees.
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

    /**
     * Register the table's header-click handler at its For — the
     * handler receives the 0-based column of a sort REQUEST: nothing
     * has changed on screen; reorder the collection by key and
     * re-declare the header with columns (docs/tables-plan.md).
     */
    public void onSort(Widget w, BiConsumer<Tx, Integer> handler) {
        sortHandlers.put(w.id, handler);
    }

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
     * text and reports each edit here. There is no read-back.
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
     * checked bit and reports each flip here.
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
        // From here on this thread IS the app thread, and every
        // transaction gate compares against it.
        claimAppThread();
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
     * The app thread, claimed by {@link #dispatchLoop} and read at every
     * transaction gate. Null until then, which is what lets the guest's
     * opening build run on the main thread before run().
     */
    static volatile Thread appThread;

    /** Called by {@link #dispatchLoop} on the way in: from here on that
     * thread IS the app thread. */
    static void claimAppThread() {
        appThread = Thread.currentThread();
    }

    /**
     * The other half of the rule {@code Tx.alive} states: OPEN is not
     * enough, a transaction also belongs to the app thread. {@code
     * closed} cannot see a thread spawned inside a handler writing
     * through the transaction the handler still holds, nor a background
     * build opening one of its own — both race the app thread's model.
     * tools/check-tx-liveness.sh holds it.
     */
    static void requireAppThread() {
        Thread owner = appThread;
        if (owner == null) {
            return;
        }
        Thread here = Thread.currentThread();
        if (here != owner) {
            throw new IllegalStateException(String.format(
                    "kaya: a transaction belongs to the app thread — this is thread %s, "
                            + "the app thread is %s. To mutate from a background thread use "
                            + "App.post, which runs your function as a transaction over there.",
                    here.getName(), owner.getName()));
        }
    }

    /**
     * Run {@code body} as a transaction on the app thread, soon. THE ONE
     * method safe to call from another thread:
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
     * runs, so a body that posts again lands in the NEXT batch — holding
     * the monitor across the calls would let a self-posting body starve
     * the occurrence loop.
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

    /**
     * One handler dispatch: an exception crosses the build boundary
     * (which rolled the model back and dropped the records), is logged,
     * and the loop moves to the next occurrence. VM-fatal errors still
     * die.
     */
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
            if (occ.kind == KayaWire.OCC_KIND_SORT_REQUESTED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Integer> handler = sortHandlers.get(occ.id);
                if (handler != null) {
                    int column = occ.payload instanceof Integer i ? i : 0;
                    dispatch(tx -> {
                        handler.accept(tx, column);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED && occ.keys.isEmpty()) {
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
                // EMPTY IS CANCEL.
                //
                // A SAVE DIALOG ANSWERS HERE TOO, through the same table
                // and id space (docs/save-plan.md D2): its handler was
                // wrapped at show() to take the one destination out of
                // the list. One retire, one live slot.
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
                // The model follows FIRST, and UNCONDITIONALLY: an app
                // that registered no handler would otherwise read a
                // stale count from the next one it does run.
                absorbUndo(delta);
                UndoHandler handler =
                        (occ.kind == KayaWire.OCC_KIND_UNDONE ? undone : redone).get(occ.id);
                if (handler != null) {
                    dispatch(tx -> handler.accept(tx, ((KayaWire.UndoValues) occ.payload).label,
                            delta));
                }
            } else if (occ.kind == KayaWire.OCC_KIND_MENU_ACTIVATED && occ.keys.isEmpty()) {
                // Menu occurrences key the menu-item tables — their own
                // id space. Node-anchored context items carry the
                // stamped copy's keys; toggles carry the new state,
                // radio groups the new 0-based index.
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
