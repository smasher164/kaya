package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.time.LocalDate;
import java.time.LocalTime;
import java.util.Map;

/**
 * The format scene from the JVM — guests/rust/format.rs,
 * tools/scenes/format.steps (and formatde, formatar through KAYA_LOCALE).
 */
public final class Format {
    public static void app() {
        KayaApp app = new KayaApp();
        KayaApp.catalog("format");
        LocalDate d = LocalDate.of(2026, 9, 7);
        LocalTime t = LocalTime.of(8, 30);
        KayaApp.Fmt fmt = KayaApp.fmt();

        app.build(tx -> {
            tx.window(0).title("format").size(540.0, 560.0);
            tx.mount(tx.column(col -> {
                tx.label(tx.signal(fmt.date(d, KayaApp.Length.SHORT))); // label#0
                tx.label(tx.signal(fmt.date(d, KayaApp.Length.MEDIUM))); // label#1
                tx.label(tx.signal(fmt.date(d, KayaApp.Length.LONG))); // label#2
                tx.label(tx.signal(fmt.time(t, KayaApp.Length.SHORT))); // label#3
                tx.label(tx.signal(fmt.dateTime(d, t, KayaApp.Length.MEDIUM))); // label#4
                tx.label(tx.signal(fmt.number(1234567.891))); // label#5
                tx.label(tx.signal(fmt.percent(0.256))); // label#6
                tx.label(tx.signal(fmt.currency(1234567.89, "USD"))); // label#7
                tx.label(tx.signal(KayaApp.tr("items", Map.of("count", 1)))); // label#8
                tx.label(tx.signal(KayaApp.tr("items", Map.of("count", 3)))); // label#9
                tx.label(tx.signal(KayaApp.tr("greeting", Map.of("name", "Ada")))); // label#10
                tx.row(row -> {
                    tx.label(tx.signal("first")); // label#11
                    tx.spacer();
                    tx.label(tx.signal("last")); // label#12
                }); // row#0
                tx.label(tx.signal(fmt.locale().tag())); // label#13
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Format() {}
}
