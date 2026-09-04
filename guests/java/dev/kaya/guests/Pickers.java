package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.time.LocalDate;
import java.time.LocalTime;

/**
 * The pickers scene from the JVM — guests/rust/pickers.rs,
 * tools/scenes/pickers.steps, docs/datetime-plan.md.
 */
public final class Pickers {
    @KayaGen(key = "String")
    record Task(String name, LocalDate due) {}

    private static String day(LocalDate d) {
        return String.format("%04d-%02d-%02d", d.getYear(), d.getMonthValue(),
                d.getDayOfMonth());
    }

    private static String clock(LocalTime t) {
        return String.format("%02d:%02d", t.getHour(), t.getMinute());
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> dateText = tx.signal("date: none");
            KayaApp.Signal<String> timeText = tx.signal("time: none");
            KayaApp.Signal<String> rowText = tx.signal("row: none");
            KayaApp.Signal<LocalDate> dateSig = tx.signal(LocalDate.of(2026, 9, 4));
            KayaApp.Signal<LocalTime> timeSig = tx.signal(LocalTime.of(14, 30));
            var tasks = TaskKaya.collection(tx);

            tx.mount(tx.column(() -> {
                tx.label(dateText); // label#0
                tx.label(timeText); // label#1
                tx.label(rowText); // label#2
                tx.datePicker(dateSig, LocalDate.of(2026, 1, 1), LocalDate.of(2026, 12, 31),
                                (t, picked) -> t.write(dateText, "date: " + day(picked)))
                        .a11yId("when").a11yLabel("Due"); // date_picker#0
                tx.timePicker(timeSig, 15,
                                (t, picked) -> t.write(timeText, "time: " + clock(picked)))
                        .a11yId("at").a11yLabel("At"); // time_picker#0
                tx.button("reset", t -> { // button#0
                    t.write(dateSig, LocalDate.of(2026, 3, 1));
                    t.write(timeSig, LocalTime.of(9, 0));
                });
                for (var row : TaskKaya.rows(tx, tasks)) {
                    row.label(row.name);
                    var picker = row.datePicker(row.due, (t, key, picked) ->
                            t.write(rowText, "row " + key + ": " + day(picked)));
                    row.setA11yId(picker, "due");
                }
            }));

            tasks.insert(tx, "a", new Task("a", LocalDate.of(2026, 10, 1)));
            tasks.insert(tx, "b", new Task("b", LocalDate.of(2026, 11, 20)));
            return null;
        });

        app.dispatchLoop();
    }

    private Pickers() {}
}
