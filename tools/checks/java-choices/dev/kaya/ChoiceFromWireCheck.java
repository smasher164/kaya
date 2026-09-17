package dev.kaya;

/**
 * AlertChoice.fromWire and NotificationOutcome.fromWire resolve every
 * wire number they define and refuse, by name, any they do not — the
 * EditSource.fromWire shape (KayaApp.java), applied to the two other
 * closed wire vocabularies that reach a guest's hands. Beside them the
 * correction slice's X2: a flag attribute is a BOOL on both sides, a
 * run and an edit carry a RANGE, and a span the CORE sent with its ends
 * out of order is refused naming the record. NO NATIVES: every one of
 * these is pure. Compiled and RUN by tools/java-typecheck.py, in
 * package dev.kaya to reach the package-private factories directly.
 */
public final class ChoiceFromWireCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("choice-from-wire: FAIL — " + what);
            System.exit(1);
        }
    }

    public static void main(String[] args) {
        check(KayaApp.AlertChoice.fromWire(0) == KayaApp.AlertChoice.ACTION0,
                "0 did not resolve to ACTION0");
        check(KayaApp.AlertChoice.fromWire(1) == KayaApp.AlertChoice.ACTION1,
                "1 did not resolve to ACTION1");
        check(KayaApp.AlertChoice.fromWire(-1) == KayaApp.AlertChoice.CANCEL,
                "-1 did not resolve to CANCEL");
        try {
            KayaApp.AlertChoice unknown = KayaApp.AlertChoice.fromWire(99);
            check(false, "an unknown alert choice (99) was accepted as " + unknown
                    + " rather than refused");
        } catch (IllegalStateException e) {
            check(e.getMessage().contains("99"),
                    "the refusal did not name the unknown number: " + e.getMessage());
        }

        check(KayaApp.NotificationOutcome.fromWire(0) == KayaApp.NotificationOutcome.ACTIVATED,
                "0 did not resolve to ACTIVATED");
        check(KayaApp.NotificationOutcome.fromWire(1) == KayaApp.NotificationOutcome.REFUSED,
                "1 did not resolve to REFUSED");
        try {
            KayaApp.NotificationOutcome unknown = KayaApp.NotificationOutcome.fromWire(7);
            check(false, "an unknown notification outcome (7) was accepted as " + unknown
                    + " rather than refused");
        } catch (IllegalStateException e) {
            check(e.getMessage().contains("7"),
                    "the refusal did not name the unknown number: " + e.getMessage());
        }

        // X2: a flag attribute is a bool on both sides, the wire's own
        // string only at the boundary; a run and an edit carry a range.
        KayaApp.Document marked = new KayaApp.Document("abcd")
                .mark(KayaApp.TextRange.ofBytes(0, 2), "italic", true)
                .link(KayaApp.TextRange.ofBytes(2, 4), "https://kaya.dev");
        check(marked.runs().size() == 2, "the bool mark left the wrong run count");
        check(marked.runs().get(0).isFlag() && marked.runs().get(0).value().equals("true"),
                "a bool mark did not reach the wire as its flag string: "
                        + marked.runs().get(0).value());
        check(!marked.runs().get(1).isFlag(), "a valued attribute read back as a flag");
        check(marked.runs().get(0).range().start == 0
                        && marked.runs().get(0).range().stop == 2,
                "a run does not carry its own span");
        check(KayaApp.Edit.replace(KayaApp.TextRange.ofBytes(1, 3), "x").range().stop == 3,
                "an edit does not carry its own span");

        // X2/S3: a reversed span is refused naming both ends. No scene
        // reaches it — the core always sends ordered spans.
        try {
            KayaApp.TextRange.ofBytes(5, 3);
            check(false, "a reversed span was accepted rather than refused");
        } catch (RuntimeException e) {
            check(e.getMessage() != null && e.getMessage().contains("5")
                            && e.getMessage().contains("3"),
                    "the reversed-span refusal did not name both ends: " + e.getMessage());
        }
        // AND ON THE DECODE SIDE, naming the RECORD — which the range's
        // own refusal cannot, and which is what a reader of this fault
        // needs.
        try {
            KayaApp.decodedSpan("text_edited", 5, 3);
            check(false, "a reversed span the core sent was accepted rather than refused");
        } catch (IllegalStateException e) {
            check(e.getMessage().contains("text_edited carries 5..3, a reversed span"),
                    "the decode-side refusal did not name the record: " + e.getMessage());
        }

        System.out.println("choice-from-wire: OK — AlertChoice and NotificationOutcome "
                + "resolve every wire number they define and refuse, by name, any "
                + "they do not; a flag attribute is a bool on both sides and a run, "
                + "an edit and a format carry a range");
    }

    private ChoiceFromWireCheck() {}
}
