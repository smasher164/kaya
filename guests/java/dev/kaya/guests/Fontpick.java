package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * The font picker scene from the JVM: guests/rust/fontpick.rs,
 * tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).
 */
public final class Fontpick {
    static final List<String> MONO = List.of("Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas",
            "Courier New", "Droid Sans Mono", "monospace");
    static final String DOC = "bold run, italic run, plain run";

    static String words(int weight, boolean italic, int width) {
        return weight + " " + (italic ? "italic" : "upright") + " " + width;
    }

    static int[] lightFamily(List<KayaApp.FontFace> faces) {
        List<Integer> upright = new ArrayList<>();
        List<Integer> italic = new ArrayList<>();
        for (KayaApp.FontFace f : faces) {
            if (f.width() != 5) continue;
            (f.italic() ? italic : upright).add(f.weight());
        }
        if (upright.size() < 3 || !upright.contains(700)) return null;
        Integer light = null;
        for (int w : upright) {
            if (w < 400 && italic.contains(w)) {
                light = w;
                break;
            }
        }
        if (light == null) return null;
        for (int i = 1; i < upright.size(); i++) {
            int a = upright.get(i - 1);
            int b = upright.get(i);
            if (a >= 500 && b > a + 1) return new int[] {light, a, b};
        }
        return null;
    }

    static Integer uprightOnly(List<KayaApp.FontFace> faces) {
        if (faces.isEmpty()) return null;
        for (KayaApp.FontFace f : faces) {
            if (f.italic()) return null;
        }
        for (KayaApp.FontFace f : faces) {
            if (f.width() == 5) return f.weight();
        }
        return null;
    }

    static final class State {
        final List<String> queue = new ArrayList<>();
        String lightFamily;
        int[] light;
        String plainFamily;
        Integer plain;
        String mono;
        KayaApp.FontChoice asked;
        KayaApp.Signal<String> ready;
        KayaApp.Signal<String> pick;
        KayaApp.Signal<String> picked;
        final List<KayaApp.Signal<String>> want = new ArrayList<>();
        KayaApp.Widget exact;
        KayaApp.Widget between;
        KayaApp.Widget synth;
        KayaApp.Widget doc;
        KayaApp.Widget chosen;

        void next(KayaApp.Tx t) {
            t.listFontFaces(queue.remove(queue.size() - 1));
        }
    }

    public static void app() {
        KayaApp app = new KayaApp();
        State s = new State();

        app.onFontFamilies((t, families) -> {
            s.mono = MONO.stream().filter(families::contains).findFirst().orElse(null);
            s.queue.clear();
            s.queue.addAll(families);
            Collections.reverse(s.queue);
            if (s.mono != null) s.queue.add(s.mono);
            if (!s.queue.isEmpty()) s.next(t);
        });

        app.onFontFaces((t, family, faces) -> {
            if (family.equals(s.mono) && s.asked == null) {
                KayaApp.FontFace face = faces.stream()
                        .filter(f -> f.weight() == 700 && !f.italic() && f.width() == 5)
                        .findFirst().orElse(faces.isEmpty() ? null : faces.get(0));
                if (face != null) {
                    s.asked = new KayaApp.FontChoice(family, face.weight(), face.italic(), face.width());
                }
            }
            if (s.light == null) {
                s.light = lightFamily(faces);
                if (s.light != null) s.lightFamily = family;
            }
            if (s.plain == null) {
                s.plain = uprightOnly(faces);
                if (s.plain != null) s.plainFamily = family;
            }
            if (s.light == null || s.plain == null) {
                if (!s.queue.isEmpty()) {
                    s.next(t);
                } else {
                    t.write(s.ready, "faces: none suit");
                }
                return;
            }
            int lw = s.light[0];
            int a = s.light[1];
            int b = s.light[2];
            int pw = s.plain;
            t.setFamily(s.exact, s.lightFamily);
            t.setFontWeight(s.exact, lw);
            t.setFamily(s.between, s.lightFamily);
            t.setFontWeight(s.between, a + (b - a) / 2);
            t.setFamily(s.synth, s.plainFamily);
            t.setFontWeight(s.synth, pw);
            t.setFontItalic(s.synth, true);
            t.setFamily(s.doc, s.lightFamily);
            t.setFontWeight(s.doc, lw);
            t.setDocument(s.doc, new KayaApp.Document(DOC)
                    .bold(KayaApp.TextRange.in(DOC, 0, 4))
                    .italic(KayaApp.TextRange.in(DOC, 10, 16)));
            t.write(s.want.get(0), words(lw, false, 5));
            t.write(s.want.get(1), words(b, false, 5));
            t.write(s.want.get(2), words(pw, true, 5) + " synthesized");
            t.write(s.want.get(3), words(700, false, 5));
            t.write(s.want.get(4), words(lw, true, 5));
            KayaApp.FontChoice c = s.asked;
            if (c != null) {
                t.write(s.pick, words(c.weight(), c.italic(), c.width()) + " " + c.family());
                t.write(s.want.get(5), words(c.weight(), c.italic(), c.width()));
            }
            t.write(s.ready, "faces: found");
        });

        app.build(tx -> {
            tx.window(0).title("fontpick");
            s.ready = tx.signal("faces: -");
            for (int i = 0; i < 6; i++) s.want.add(tx.signal("-"));
            s.pick = tx.signal("-");
            s.picked = tx.signal("picked: -");
            tx.mount(tx.column(col -> {
                tx.label(s.ready).a11yId("ready");
                s.exact = tx.label("Exact").a11yId("exact");
                s.between = tx.label("Between").a11yId("between");
                s.synth = tx.label("Slanted").a11yId("synth");
                s.doc = tx.textarea().rich().a11yId("doc");
                s.chosen = tx.label("Chosen").a11yId("chosen");
                List<String> ids = List.of("want_exact", "want_between", "want_synth", "want_bold",
                        "want_italic", "want_pick");
                for (int i = 0; i < ids.size(); i++) tx.label(s.want.get(i)).a11yId(ids.get(i));
                tx.label(s.pick).a11yId("pick");
                tx.label(s.picked).a11yId("picked");
                tx.row(r -> {
                    tx.button("faces", t -> t.listFontFamilies()).a11yId("faces");
                    tx.button("pick", t -> {
                        KayaApp.FontDialogRef request = t.chooseFont().codeOnly(true).faces(true);
                        if (s.asked != null) request.initial(s.asked);
                        request.onResult((t2, c) -> {
                            if (c == null) {
                                t2.write(s.picked, "picked: cancelled");
                                return;
                            }
                            t2.setFamily(s.chosen, c.family());
                            t2.setFontWeight(s.chosen, c.weight());
                            t2.setFontItalic(s.chosen, c.italic());
                            t2.setFontWidth(s.chosen, c.width());
                            t2.write(s.picked, c.equals(s.asked) ? "picked: as asked"
                                    : "picked: " + words(c.weight(), c.italic(), c.width()) + " " + c.family());
                        }).show();
                    }).a11yId("pick_button");
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Fontpick() {}
}
