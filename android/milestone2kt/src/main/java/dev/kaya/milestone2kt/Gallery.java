package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The gallery scene from the JVM: a row container laying a checkbox and
 * the status label side by side. The box owns its checked bit and
 * reports each flip through onToggle; the app answers by writing the
 * status signal — the same uncontrolled contract as the entry, with a
 * bool.
 */
final class Gallery {
    /** The scene's handles, returned by the build body. */
    private static final class Scene {
        final KayaApp.Signal status;
        final KayaApp.Widget urgent;

        Scene(KayaApp.Signal status, KayaApp.Widget urgent) {
            this.status = status;
            this.urgent = urgent;
        }
    }

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal status = tx.signal("urgent: false");

            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);
            KayaApp.Widget row = tx.widget(KayaWire.KIND_ROW);
            KayaApp.Widget urgent = tx.widget(KayaWire.KIND_CHECKBOX);
            tx.setText(urgent, "urgent");
            KayaApp.Widget statusLabel = tx.widget(KayaWire.KIND_LABEL);
            tx.bindText(statusLabel, status);

            tx.addChild(row, urgent);
            tx.addChild(row, statusLabel);
            tx.addChild(column, row);
            tx.mount(column);
            return new Scene(status, urgent);
        });

        app.onToggle(scene.urgent, (tx, checked) ->
            tx.write(scene.status, "urgent: " + checked));

        app.dispatchLoop();
    }

    private Gallery() {}
}
