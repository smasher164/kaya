package dev.kaya;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.Consumer;

/**
 * The Java binding's emission check (docs/deferred.md, per-binding emission
 * checks), run by tools/java-typecheck.py. IN PACKAGE dev.kaya so the
 * transaction's records are reachable; every probe transaction aborts.
 */
public final class EmissionCheck {
    private static final List<String> FAILURES = new ArrayList<>();

    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("emission-check: FAIL — " + what);
            FAILURES.add(what);
        }
    }

    @SuppressWarnings("unchecked")
    private static List<byte[]> records(KayaApp.Tx tx) {
        try {
            Field f = KayaApp.Tx.class.getDeclaredField("records");
            f.setAccessible(true);
            return (List<byte[]>) f.get(tx);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    private static ByteBuffer le(byte[] r) {
        return ByteBuffer.wrap(r).order(ByteOrder.LITTLE_ENDIAN);
    }

    private static short kind(byte[] r) {
        return le(r).getShort(4);
    }

    private static final class Abort extends RuntimeException {
        Abort() {
            super("emission-check abort");
        }
    }

    /** Run {@code body} in a build that never commits. */
    private static void staged(KayaApp app, Consumer<KayaApp.Tx> body) {
        try {
            app.build((Consumer<KayaApp.Tx>) tx -> {
                body.accept(tx);
                throw new Abort();
            });
        } catch (Abort expected) {
            return;
        }
    }

    /** What a chain method must stage: a set_property of {@code prop} on
     * its widget, or a record of {@code kind} carrying the widget's id. */
    private record Want(short kind, int prop) {}

    private static Want prop(int prop) {
        return new Want(KayaWire.TX_KIND_SET_PROPERTY, prop);
    }

    private static Want record(short kind) {
        return new Want(kind, -1);
    }

    private static final Map<String, Want> CHAIN = new TreeMap<>();

    static {
        CHAIN.put("a11yHint(Signal)", prop(KayaWire.PROP_A11Y_HINT));
        CHAIN.put("a11yHint(String)", prop(KayaWire.PROP_A11Y_HINT));
        CHAIN.put("a11yId(Signal)", prop(KayaWire.PROP_A11Y_ID));
        CHAIN.put("a11yId(String)", prop(KayaWire.PROP_A11Y_ID));
        CHAIN.put("a11yLabel(Signal)", prop(KayaWire.PROP_A11Y_LABEL));
        CHAIN.put("a11yLabel(String)", prop(KayaWire.PROP_A11Y_LABEL));
        CHAIN.put("accepts(String[])", prop(KayaWire.PROP_ACCEPTS));
        CHAIN.put("align(Align)", prop(KayaWire.PROP_ALIGN));
        CHAIN.put("alpha(boolean)", prop(KayaWire.PROP_ALPHA));
        CHAIN.put("aspect(int,int)", prop(KayaWire.PROP_ASPECT));
        CHAIN.put("axis(Axis)", prop(KayaWire.PROP_AXIS));
        CHAIN.put("bleed()", prop(KayaWire.PROP_BLEED));
        CHAIN.put("columnsAuto(double)", prop(KayaWire.PROP_MIN_COLUMN_WIDTH));
        CHAIN.put("columnsWhen(SizeClass,int)", record(KayaWire.TX_KIND_CREATE_BREAKPOINT));
        CHAIN.put("contentType(ContentType)", prop(KayaWire.PROP_CONTENT_TYPE));
        CHAIN.put("expanded(boolean)", prop(KayaWire.PROP_EXPANDED));
        CHAIN.put("family(String)", prop(KayaWire.PROP_FAMILY));
        CHAIN.put("fill(boolean)", prop(KayaWire.PROP_FILL));
        CHAIN.put("filled(Tint)", prop(KayaWire.PROP_FILLED));
        CHAIN.put("fit(Fit)", prop(KayaWire.PROP_FIT));
        CHAIN.put("fixed()", record(KayaWire.TX_KIND_SET_SIZE_POLICY));
        CHAIN.put("followsEnd()", prop(KayaWire.PROP_FOLLOWS_END));
        CHAIN.put("format(NumberFormat)", prop(KayaWire.PROP_FORMAT));
        CHAIN.put("groundGradient(Color)", prop(KayaWire.PROP_GROUND));
        CHAIN.put("groundGradient(Signal)", prop(KayaWire.PROP_GROUND));
        CHAIN.put("groundImage(byte[])", prop(KayaWire.PROP_GROUND));
        CHAIN.put("groundImage(Signal)", prop(KayaWire.PROP_GROUND));
        CHAIN.put("grow(double)", prop(KayaWire.PROP_GROW));
        CHAIN.put("help(Signal)", prop(KayaWire.PROP_HELP));
        CHAIN.put("help(String)", prop(KayaWire.PROP_HELP));
        CHAIN.put("hidden(Signal)", prop(KayaWire.PROP_HIDDEN));
        CHAIN.put("hidden(boolean)", prop(KayaWire.PROP_HIDDEN));
        CHAIN.put("highLabel(String)", prop(KayaWire.PROP_HIGH_LABEL));
        CHAIN.put("href(Signal)", prop(KayaWire.PROP_HREF));
        CHAIN.put("href(String)", prop(KayaWire.PROP_HREF));
        CHAIN.put("inset(double)", prop(KayaWire.PROP_INSET));
        CHAIN.put("lineNumbers(boolean)", prop(KayaWire.PROP_LINE_NUMBERS));
        CHAIN.put("lowLabel(String)", prop(KayaWire.PROP_LOW_LABEL));
        CHAIN.put("max(double)", prop(KayaWire.PROP_MAX));
        CHAIN.put("maxHeight(double)", prop(KayaWire.PROP_MAX_HEIGHT));
        CHAIN.put("maxLines(int)", prop(KayaWire.PROP_MAX_LINES));
        CHAIN.put("maxWidth(double)", prop(KayaWire.PROP_MAX_WIDTH));
        CHAIN.put("min(double)", prop(KayaWire.PROP_MIN));
        CHAIN.put("minGap(double)", prop(KayaWire.PROP_MIN_GAP));
        CHAIN.put("monospaced(boolean)", prop(KayaWire.PROP_MONOSPACED));
        CHAIN.put("onActivate(Consumer)", prop(KayaWire.PROP_ACTIVATABLE));
        CHAIN.put("onDraw(DrawHandler)", record(KayaWire.TX_KIND_SET_SIZE_POLICY));
        CHAIN.put("onSelect(Consumer)", prop(KayaWire.PROP_ACTIVATABLE));
        CHAIN.put("onTick(TickHandler)", record(KayaWire.TX_KIND_SET_SIZE_POLICY));
        CHAIN.put("ownUndo()", prop(KayaWire.PROP_OWN_UNDO));
        CHAIN.put("phase(ImagePhase)", prop(KayaWire.PROP_PHASE));
        CHAIN.put("phase(Signal)", prop(KayaWire.PROP_PHASE));
        CHAIN.put("placeholder(Signal)", prop(KayaWire.PROP_PLACEHOLDER));
        CHAIN.put("placeholder(String)", prop(KayaWire.PROP_PLACEHOLDER));
        CHAIN.put("revealable()", prop(KayaWire.PROP_REVEALABLE));
        CHAIN.put("revealed(boolean)", prop(KayaWire.PROP_REVEALED));
        CHAIN.put("rich()", prop(KayaWire.PROP_RICH));
        CHAIN.put("role(Role)", prop(KayaWire.PROP_ROLE));
        CHAIN.put("selected(Signal)", prop(KayaWire.PROP_SELECTED));
        CHAIN.put("selected(boolean)", prop(KayaWire.PROP_SELECTED));
        CHAIN.put("shape(Shape)", prop(KayaWire.PROP_SHAPE));
        CHAIN.put("spacing(double)", prop(KayaWire.PROP_SPACING));
        CHAIN.put("stackWhen(SizeClass)", record(KayaWire.TX_KIND_CREATE_BREAKPOINT));
        CHAIN.put("step(double)", prop(KayaWire.PROP_STEP));
        CHAIN.put("submits()", prop(KayaWire.PROP_SUBMITS));
        CHAIN.put("summary(String)", prop(KayaWire.PROP_SUMMARY));
        CHAIN.put("symbol(Symbol)", prop(KayaWire.PROP_SYMBOL));
        CHAIN.put("textScale(double)", prop(KayaWire.PROP_TEXT_SCALE));
        CHAIN.put("fontWeight(int)", prop(KayaWire.PROP_FONT_WEIGHT));
        CHAIN.put("fontItalic(boolean)", prop(KayaWire.PROP_FONT_ITALIC));
        CHAIN.put("fontWidth(int)", prop(KayaWire.PROP_FONT_WIDTH));
        CHAIN.put("tickSpacing(double)", prop(KayaWire.PROP_TICK_SPACING));
        CHAIN.put("tint(Signal)", prop(KayaWire.PROP_TINT));
        CHAIN.put("tint(Tint)", prop(KayaWire.PROP_TINT));
        CHAIN.put("wrap(boolean)", prop(KayaWire.PROP_WRAP));
    }

    private static String signature(Method m) {
        StringBuilder s = new StringBuilder(m.getName()).append('(');
        Class<?>[] ps = m.getParameterTypes();
        for (int i = 0; i < ps.length; i++) {
            s.append(i == 0 ? "" : ",").append(ps[i].getSimpleName());
        }
        return s.append(')').toString();
    }

    /** A value of each parameter type; distinctive where the record can
     * be searched for it. */
    private static Object argument(Class<?> t, KayaApp.Tx tx) {
        if (t == double.class) {
            return 13.25;
        }
        if (t == int.class) {
            return 3;
        }
        if (t == boolean.class) {
            return true;
        }
        if (t == String.class) {
            return "emission";
        }
        if (t == String[].class) {
            return new String[] { "emission" };
        }
        if (t == byte[].class) {
            return new byte[] { 1, 2, 3 };
        }
        if (t == KayaApp.Color.class) {
            return KayaApp.Color.rgb(1, 2, 3);
        }
        if (t == KayaApp.NumberFormat.class) {
            return KayaApp.NumberFormat.NUMBER;
        }
        if (t == KayaApp.Signal.class) {
            return tx.signal("emission");
        }
        if (t.isEnum()) {
            Object[] all = t.getEnumConstants();
            return all[all.length - 1];
        }
        if (t.isInterface()) {
            return Proxy.newProxyInstance(t.getClassLoader(), new Class<?>[] { t }, (p, m, a) -> null);
        }
        throw new IllegalStateException("emission-check: no argument for a " + t.getName()
                + " parameter; teach argument() the type");
    }

    private static boolean carries(byte[] r, long id) {
        ByteBuffer b = le(r);
        for (int at = 8; at + 8 <= r.length; at += 8) {
            if (b.getLong(at) == id) {
                return true;
            }
        }
        return false;
    }

    private static boolean carriesDouble(byte[] r, double v) {
        ByteBuffer b = le(r);
        for (int at = 8; at + 8 <= r.length; at += 4) {
            if (b.getDouble(at) == v) {
                return true;
            }
        }
        return false;
    }

    private static String describe(List<byte[]> got) {
        StringBuilder s = new StringBuilder();
        for (byte[] r : got) {
            ByteBuffer b = le(r);
            s.append(s.length() == 0 ? "" : ", ").append("kind ").append(kind(r));
            if (kind(r) == KayaWire.TX_KIND_SET_PROPERTY) {
                s.append(" on ").append(b.getLong(8)).append(" prop ").append(b.getInt(16));
            }
        }
        return s.length() == 0 ? "nothing" : s.toString();
    }

    private static void chain(KayaApp app) {
        Method[] methods = KayaApp.Widget.class.getMethods();
        Arrays.sort(methods, Comparator.comparing(EmissionCheck::signature));
        int held = 0;
        for (Method m : methods) {
            if (m.getReturnType() != KayaApp.Widget.class || Modifier.isStatic(m.getModifiers())) {
                continue;
            }
            String sig = signature(m);
            Want want = CHAIN.get(sig);
            if (want == null) {
                check(false, "the chain method Widget." + sig + " has no expectation here: name the "
                        + "record it must stage in EmissionCheck's CHAIN");
                continue;
            }
            held++;
            staged(app, tx -> {
                KayaApp.Widget w = tx.column(c -> { });
                Object[] args = new Object[m.getParameterCount()];
                for (int i = 0; i < args.length; i++) {
                    args[i] = argument(m.getParameterTypes()[i], tx);
                }
                int before = records(tx).size();
                try {
                    m.invoke(w, args);
                } catch (InvocationTargetException e) {
                    check(false, "Widget." + sig + " threw " + e.getCause());
                    return;
                } catch (IllegalAccessException e) {
                    throw new IllegalStateException(e);
                }
                List<byte[]> got = new ArrayList<>(records(tx).subList(before, records(tx).size()));
                boolean found = false;
                for (byte[] r : got) {
                    if (kind(r) != want.kind()) {
                        continue;
                    }
                    if (want.prop() >= 0) {
                        ByteBuffer b = le(r);
                        if (b.getLong(8) != w.id || b.getInt(16) != want.prop()) {
                            continue;
                        }
                    } else if (!carries(r, w.id)) {
                        continue;
                    }
                    if (args.length == 1 && args[0] instanceof Double d && !carriesDouble(r, d)) {
                        check(false, "Widget." + sig + " staged its record without the value " + d);
                    }
                    found = true;
                }
                check(found, "Widget." + sig + " staged " + describe(got) + ", wanted "
                        + (want.prop() >= 0 ? "set_property prop " + want.prop() + " on its widget"
                                : "a kind " + want.kind() + " record naming its widget"));
            });
        }
        check(held == CHAIN.size(), "CHAIN names " + CHAIN.size() + " methods and Widget has "
                + held + " of them: a renamed or removed chain method leaves a stale row");
        System.out.println("emission-check: " + held + " construction-chain methods staged their records");
    }

    private static int count(List<byte[]> got, short k) {
        int n = 0;
        for (byte[] r : got) {
            n += kind(r) == k ? 1 : 0;
        }
        return n;
    }

    private static void menus(KayaApp app) {
        KayaApp.MenuItem[] file = new KayaApp.MenuItem[1];
        staged(app, tx -> {
            int before = records(tx).size();
            KayaApp.WindowRef win = tx.window(0);
            file[0] = win.menu("File");
            file[0].item("Save").shortcut("PRIMARY+S");
            KayaApp.MenuItem sort = win.radioGroup("Sort");
            sort.option("Name");
            sort.option("Date");
            KayaApp.Widget noun = tx.label("noun");
            tx.contextMenu(noun).item("Rename");
            List<byte[]> got = records(tx).subList(before, records(tx).size());
            // File, Save, Sort, Name, Date, Rename.
            check(count(got, KayaWire.TX_KIND_MENU_ITEM_CREATE) == 6,
                    "menu constructors staged " + count(got, KayaWire.TX_KIND_MENU_ITEM_CREATE)
                            + " menu_item_create records, wanted 6");
            check(count(got, KayaWire.TX_KIND_MENUBAR_APPEND) == 2,
                    "bar anchors staged " + count(got, KayaWire.TX_KIND_MENUBAR_APPEND)
                            + " menubar_append records, wanted 2");
            check(count(got, KayaWire.TX_KIND_MENU_ITEM_APPEND) == 3,
                    "children staged " + count(got, KayaWire.TX_KIND_MENU_ITEM_APPEND)
                            + " menu_item_append records, wanted 3");
            check(count(got, KayaWire.TX_KIND_CONTEXT_ATTACH) == 1,
                    "the context anchor staged " + count(got, KayaWire.TX_KIND_CONTEXT_ATTACH)
                            + " context_attach records, wanted 1");
            boolean canonical = false;
            for (byte[] r : got) {
                canonical |= new String(r, StandardCharsets.UTF_8).contains("primary+s");
            }
            check(canonical, "the shortcut PRIMARY+S did not reach the records canonicalized");
        });
        // Append-at-any-time: the retained handle reopens in a later
        // transaction, one create plus one append under the RETAINED
        // parent, and never a new bar anchor.
        staged(app, tx -> {
            int before = records(tx).size();
            tx.menu(file[0]).item("Publish");
            List<byte[]> got = records(tx).subList(before, records(tx).size());
            check(count(got, KayaWire.TX_KIND_MENU_ITEM_CREATE) == 1,
                    "the reopen staged " + count(got, KayaWire.TX_KIND_MENU_ITEM_CREATE)
                            + " menu_item_create records, wanted 1");
            check(count(got, KayaWire.TX_KIND_MENUBAR_APPEND) == 0, "the reopen re-anchored the bar");
            boolean under = false;
            for (byte[] r : got) {
                under |= kind(r) == KayaWire.TX_KIND_MENU_ITEM_APPEND && le(r).getLong(8) == file[0].id;
            }
            check(under, "the reopen did not seat its item under the retained parent");
        });
    }

    private static byte[] only(KayaApp.Tx tx, int before, String what) {
        List<byte[]> got = records(tx).subList(before, records(tx).size());
        check(got.size() == 1, what + " staged " + got.size() + " records, wanted one format_text");
        return got.isEmpty() ? new byte[48] : got.get(0);
    }

    private static void formats(KayaApp app) {
        staged(app, tx -> {
            KayaApp.Widget editor = tx.textarea().rich();
            Object[][] acts = {
                { "format", (Consumer<KayaApp.Tx>) t -> t.format(editor, "bold", true), 0, 0, 0L, 0L },
                { "unformat", (Consumer<KayaApp.Tx>) t -> t.unformat(editor, "bold"), 1, 0, 0L, 0L },
                { "formatRange", (Consumer<KayaApp.Tx>) t ->
                        t.formatRange(editor, KayaApp.TextRange.ofBytes(2, 7), "bold", true), 0, 1, 2L, 7L },
            };
            for (Object[] act : acts) {
                int before = records(tx).size();
                @SuppressWarnings("unchecked")
                Consumer<KayaApp.Tx> body = (Consumer<KayaApp.Tx>) act[1];
                body.accept(tx);
                byte[] r = only(tx, before, (String) act[0]);
                ByteBuffer b = le(r);
                String got = kind(r) + " " + b.getInt(16) + " " + b.getInt(20) + " " + b.getLong(24) + " "
                        + b.getLong(32);
                String want = KayaWire.TX_KIND_FORMAT_TEXT + " " + act[2] + " " + act[3] + " " + act[4] + " "
                        + act[5];
                check(got.equals(want), act[0] + " staged (kind, removed, ranged, start, stop) " + got
                        + ", wanted " + want);
            }
            // The named acts are format with their own name: each stages
            // the bytes format stages.
            Object[][] named = {
                { "bold", (Consumer<KayaApp.Tx>) t -> t.bold(editor), "bold", "true" },
                { "italic", (Consumer<KayaApp.Tx>) t -> t.italic(editor), "italic", "true" },
                { "underline", (Consumer<KayaApp.Tx>) t -> t.underline(editor), "underline", "true" },
                { "strike", (Consumer<KayaApp.Tx>) t -> t.strike(editor), "strike", "true" },
                { "code", (Consumer<KayaApp.Tx>) t -> t.code(editor), "code", "true" },
                { "link", (Consumer<KayaApp.Tx>) t -> t.link(editor, "https://kaya.dev"), "link",
                        "https://kaya.dev" },
            };
            for (Object[] act : named) {
                int before = records(tx).size();
                @SuppressWarnings("unchecked")
                Consumer<KayaApp.Tx> body = (Consumer<KayaApp.Tx>) act[1];
                body.accept(tx);
                byte[] got = only(tx, before, (String) act[0]);
                before = records(tx).size();
                tx.format(editor, (String) act[2], (String) act[3]);
                byte[] want = only(tx, before, "format " + act[2]);
                check(Arrays.equals(got, want), act[0] + " staged other bytes than format(\"" + act[2]
                        + "\", \"" + act[3] + "\") stages");
            }
        });
    }

    public static void main(String[] args) {
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();
        KayaApp app = new KayaApp();
        KayaApp.claimAppThread();
        chain(app);
        menus(app);
        formats(app);
        if (!FAILURES.isEmpty()) {
            System.out.println("emission-check: " + FAILURES.size() + " failure(s)");
            System.exit(1);
        }
        System.out.println("emission-check: OK");
    }
}
