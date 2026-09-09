package dev.kaya;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The process-level notification handler's DISPATCH ORDER
 * (docs/tasks-s9-plan.md R1), run rather than read. A tap on a reminder
 * after the app has exited relaunches the process, and THAT process never
 * called show, so the one-shot table is empty for the id that started it.
 * The ring loop's switch has no seam a test can reach — the ring is raw
 * memory — so these drive KayaApp.notificationResult, which the arm calls
 * and tools/check-sugar-surface.py holds it to calling. IN PACKAGE
 * dev.kaya so the package-private decision is reachable, exactly as
 * IdSpaceCheck is. Compiled and RUN by tools/java-typecheck.py.
 */
public final class NotifyOrderCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("notify-order: FAIL — " + what);
            System.exit(1);
        }
    }

    public static void main(String[] args) {
        // WITH THE NATIVES, unlike AbortCheck's ring stub: the decision
        // dispatches through a real transaction, and a submit that
        // throws UnsatisfiedLinkError would leave every case red for a
        // reason that has nothing to do with the order. tools/java-typecheck.py
        // hands KAYA_LIB in, Main.java's own bootstrap.
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();

        KayaApp app = new KayaApp();
        List<Integer> oneShot = new ArrayList<>();
        List<long[]> process = new ArrayList<>();
        app.onNotificationActivation((tx, id, outcome) -> process.add(new long[] {id, outcome}));
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx ->
                tx.showNotification(12)
                        .title("bound at the show")
                        .onResult((inner, outcome) -> oneShot.add(outcome))
                        .show());

        // CASE 1: an id WITH a one-shot handler is answered by it, and the
        // process-level handler is not consulted at all.
        app.notificationResult(12, KayaWire.NOTIFICATION_OUTCOME_ACTIVATED);
        check(oneShot.size() == 1
                        && oneShot.get(0) == KayaWire.NOTIFICATION_OUTCOME_ACTIVATED,
                "the one-shot handler did not answer: " + oneShot);
        check(process.isEmpty(),
                "the process-level handler answered an id that HAD a one-shot handler");

        // CASE 2: an id this process never showed — the relaunch case.
        app.notificationResult(77, KayaWire.NOTIFICATION_OUTCOME_ACTIVATED);
        check(process.size() == 1 && process.get(0)[0] == 77
                        && process.get(0)[1] == KayaWire.NOTIFICATION_OUTCOME_ACTIVATED,
                "a result with no one-shot handler did not reach the process-level one");

        // CASE 3: it does NOT retire.
        app.notificationResult(78, KayaWire.NOTIFICATION_OUTCOME_REFUSED);
        check(process.size() == 2 && process.get(1)[0] == 78
                        && process.get(1)[1] == KayaWire.NOTIFICATION_OUTCOME_REFUSED,
                "the process-level handler retired after its first result");

        // AND THE DROP IS ANNOUNCED, compared in full: a drop nobody
        // announced is R5's defect class, and this sentence is the only
        // signal a relaunched process's author gets that nothing listened.
        // ONE APP PER PROCESS is a latch (BuildOnceCheck), so the drop
        // case clears this app's registration rather than building a
        // second one.
        app.onNotificationActivation(null);
        ByteArrayOutputStream said = new ByteArrayOutputStream();
        PrintStream real = System.err;
        System.setErr(new PrintStream(said, true, StandardCharsets.UTF_8));
        try {
            app.notificationResult(41, KayaWire.NOTIFICATION_OUTCOME_REFUSED);
        } finally {
            System.setErr(real);
        }
        String want = "kaya: notification 41 outcome refused reached no handler — "
                + "none was bound at the show and no process-level handler is "
                + "registered (KayaApp.onNotificationActivation)";
        String got = said.toString(StandardCharsets.UTF_8).trim();
        check(got.equals(want), "the drop was announced as \"" + got + "\", wanted \"" + want + "\"");

        System.out.println("notify-order: OK — the one-shot wins, an unknown id "
                + "reaches the process handler, it does not retire, and an "
                + "unclaimed result announces its drop");
    }

    private NotifyOrderCheck() {}
}
