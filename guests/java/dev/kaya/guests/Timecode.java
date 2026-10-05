package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

public final class Timecode {
    @KayaGen(key = "String")
    record FrameLine(double qty) {}

    public static void app() {
        KayaApp app = new KayaApp();
        var normal = new KayaApp.TimecodeRate(25, 1, false);
        var drop = new KayaApp.TimecodeRate(30000, 1001, true);
        int[] commits = {0};
        int[] phase = {0};
        if (KayaApp.fmt().parseTimecode("٠١:٠٢:٠٣:١٢", normal).orElseThrow() != 93087
                || KayaApp.fmt().parseTimecode("00:01:00;00", drop).isPresent()
                || KayaApp.fmt().parseTimecode("00:00:00:00\u0000ignored", normal).isPresent()) {
            throw new AssertionError("timecode parse door disagrees");
        }
        app.build(tx -> {
            tx.window(0).title("Timecode").size(440, 500);
            var status = tx.signal("commits: 0");
            var rowStatus = tx.signal("row: none");
            var playhead = tx.signal(KayaApp.fmt().timecode(93087, normal));
            var rows = FrameLineKaya.collection(tx);
            var switchingValue = tx.signal(-2.0);
            java.util.function.BiConsumer<KayaApp.Tx, Double> committed = (t, frames) -> {
                commits[0]++;
                t.write(status, "commits: " + commits[0]);
                t.write(playhead, KayaApp.fmt().timecode(frames.longValue(), normal));
            };
            tx.mount(tx.column(col -> {
                tx.label("25 fps");
                tx.label(playhead).a11yId("playhead");
                tx.numberField(93087, committed).format(KayaApp.NumberFormat.timecode(normal))
                        .a11yId("position").a11yLabel("Position");
                tx.label(status).a11yId("commits");
                tx.label("29.97 drop-frame");
                tx.numberField(1799, committed).format(KayaApp.NumberFormat.timecode(drop))
                        .a11yId("drop").a11yLabel("Drop frame");
                tx.entry().a11yId("note");
                for (var row : FrameLineKaya.rows(tx, rows)) {
                    var field = row.numberField(row.qty);
                    row.setFormat(field, KayaApp.NumberFormat.timecode(normal));
                    row.setA11yId(field, "rowtime");
                    app.onValueCommitted(field, (t, keys, frames) ->
                            t.write(rowStatus, "row " + keys.get(0) + ": " + (long) frames));
                }
                tx.label(rowStatus).a11yId("row");
                var switching = tx.numberField(switchingValue, null).a11yId("switching");
                tx.button("Switch format", t -> {
                    switch (phase[0]++ % 4) {
                        case 0 -> { t.setFormat(switching, KayaApp.NumberFormat.timecode(drop)); t.write(switchingValue, 1800.0); }
                        case 1 -> { t.write(switchingValue, -2.0); t.setFormat(switching, KayaApp.NumberFormat.NUMBER); }
                        case 2 -> { t.write(switchingValue, 1800.0); t.setFormat(switching, KayaApp.NumberFormat.timecode(drop)); }
                        case 3 -> { t.setFormat(switching, KayaApp.NumberFormat.NUMBER); t.write(switchingValue, -2.0); }
                    }
                }).a11yId("switchformat");
            }));
            rows.insert(tx, "a", new FrameLine(25));
            return null;
        });
        app.dispatchLoop();
    }
    private Timecode() {}
}
