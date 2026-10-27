package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.util.ArrayList;
import java.util.List;

/**
 * The code surface scene from the JVM: guests/rust/codesurface.rs,
 * tools/scenes/codesurface.steps (docs/code-surface-plan.md). A textarea that
 * numbers its lines, the platform's monospaced face, a family picked from the
 * platform's list, a family the platform lacks, a label at twice the size.
 */
public final class Codesurface {
    /** Forty lines; the third wraps at every lane's width. */
    static String document() {
        List<String> lines = new ArrayList<>(List.of(
                "// codesurface",
                "fn main() {",
                "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row "
                        + "and the gutter has a continuation to leave unnumbered, the way every editor does\";"));
        for (int i = 4; i < 40; i++) {
            lines.add(String.format("    let value_%02d = %d * 2;", i, i));
        }
        lines.add("}");
        return String.join("\n", lines);
    }

    public static void app() {
        KayaApp app = new KayaApp();
        String doc = document();
        KayaApp.Widget[] widgets = new KayaApp.Widget[2];
        List<KayaApp.Signal<String>> listed = new ArrayList<>();

        app.onFontFamilies((t, families) -> {
            boolean ordered = true;
            for (int i = 1; i < families.size(); i++) {
                if (families.get(i - 1).compareTo(families.get(i)) >= 0) {
                    ordered = false;
                }
            }
            t.write(listed.get(0), families.isEmpty() ? "families: none"
                    : ordered ? "families: listed, unique, in order" : "families: out of order");
            if (!families.isEmpty()) {
                t.setFamily(widgets[1], families.get(0));
            }
        });

        app.build(tx -> {
            tx.window(0).title("codesurface");
            listed.add(tx.signal("families: -"));
            tx.mount(tx.column(col -> {
                KayaApp.Widget code = tx.textarea().lineNumbers(true).monospaced(true).a11yId("code");
                widgets[0] = code;
                tx.setText(code, doc);
                KayaApp.Widget plain = tx.textarea().a11yId("plain");
                tx.setText(plain, "plain text\nin the app's face");
                tx.label("let x = 1;").monospaced(true).a11yId("mono");
                KayaApp.Widget monoEntry = tx.entry().monospaced(true).a11yId("mono_entry");
                tx.setText(monoEntry, "let y = 2;");
                tx.label("missing").family("Kaya No Such Family").monospaced(true).a11yId("missing");
                tx.label("Big").textScale(2).a11yId("big");
                tx.label("Plain").a11yId("plain_label");
                tx.label(listed.get(0)).a11yId("families");
                widgets[1] = tx.label("picked").a11yId("picked");
                tx.row(r -> {
                    tx.button("end", t -> {
                        KayaApp.TextRange end = KayaApp.TextRange.in(doc, doc.length(), doc.length());
                        t.focus(widgets[0]);
                        t.selectRange(widgets[0], end);
                        t.revealRange(widgets[0], end);
                    }).a11yId("end");
                    tx.button("fonts", t -> t.listFontFamilies()).a11yId("fonts");
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Codesurface() {}
}
