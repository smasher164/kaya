package dev.kaya;

/**
 * AlertChoice.fromWire and NotificationOutcome.fromWire resolve every
 * wire number they define and refuse, by name, any they do not — the
 * EditSource.fromWire shape (KayaApp.java), applied to the two other
 * closed wire vocabularies that reach a guest's hands. NO NATIVES: both
 * factories are pure. Compiled and RUN by tools/java-typecheck.py, in
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

        System.out.println("choice-from-wire: OK — AlertChoice and NotificationOutcome "
                + "resolve every wire number they define and refuse, by name, any "
                + "they do not");
    }

    private ChoiceFromWireCheck() {}
}
