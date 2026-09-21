package dev.kaya;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

public final class Probe {
    static int reports;
    static final String SENTENCE = "kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed";

    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    static void observe(CompletionStage<?> stage) {
        stage.whenComplete((value, error) -> {
            if (error != null) {
                reports++;
                System.err.println("probe error: " + error);
                System.err.println(SENTENCE);
            }
        });
    }

    @SuppressWarnings("unchecked")
    static void measure(String mode) throws Exception {
        KayaApp.claimAppThread();
        Thread owner = Thread.currentThread();
        KayaApp app = new KayaApp();
        KayaApp.Collection rows = app.build(tx -> { return tx.collection(); });
        CompletableFuture<KayaApp.AlertChoice> request = new CompletableFuture<>();
        ArrayDeque<Runnable> jobs = new ArrayDeque<>();
        KayaApp.Tx[] resultTx = {null};
        boolean[] inherited = {false};
        long id = app.build(tx -> { return tx.showAlert().cancel("keep").onResult((answerTx, choice) -> {
            resultTx[0] = answerTx;
            Runnable complete = () -> request.complete(choice);
            if (mode.equals("inline")) complete.run();
            else jobs.add(complete);
        }).show(); });
        CompletableFuture<Void> terminal = request.thenAccept(choice -> {
            require(Thread.currentThread() == owner, "continuation changed threads");
            inherited[0] = !resultTx[0].closed;
            if (mode.equals("inline") || mode.equals("late")) return;
            require(!inherited[0], "continuation inherited the result transaction");
            if (mode.equals("before")) throw new IllegalStateException("before scope");
            app.build(tx -> { tx.insert(rows, "first", 1); });
            if (mode.equals("inside") || mode.equals("caught")) {
                Consumer<KayaApp.Tx> throwing = tx -> {
                    tx.insert(rows, "second", 2);
                    throw new IllegalStateException("inside scope");
                };
                try {
                    app.build(throwing);
                } catch (IllegalStateException error) {
                    if (!mode.equals("caught")) throw error;
                }
                return;
            }
            throw new IllegalStateException("after completed scope");
        });
        if (mode.equals("parent")) observe(request);
        if (mode.equals("owned") || mode.equals("inside") || mode.equals("before")) observe(terminal);

        Field field = KayaApp.class.getDeclaredField("alerts");
        field.setAccessible(true);
        Map<Long, BiConsumer<KayaApp.Tx, KayaApp.AlertChoice>> alerts =
                (Map<Long, BiConsumer<KayaApp.Tx, KayaApp.AlertChoice>>) field.get(app);
        BiConsumer<KayaApp.Tx, KayaApp.AlertChoice> handler = alerts.remove(id);
        require(handler != null && alerts.isEmpty(), "result registration did not retire");
        Method dispatch = KayaApp.class.getDeclaredMethod("dispatch", Consumer.class);
        dispatch.setAccessible(true);
        dispatch.invoke(app, (Consumer<KayaApp.Tx>) tx -> handler.accept(tx, KayaApp.AlertChoice.ACTION0));
        require(resultTx[0].closed, "result transaction did not close");
        while (!jobs.isEmpty()) jobs.remove().run();
        require(request.join() == KayaApp.AlertChoice.ACTION0, "request itself failed");

        if (mode.equals("late")) {
            AtomicReference<CompletableFuture<Void>> late = new AtomicReference<>();
            Thread foreign = new Thread(() -> late.set(request.thenAccept(choice -> {
                require(Thread.currentThread() != owner, "late chain unexpectedly moved to app thread");
                app.build(tx -> { tx.insert(rows, "foreign", 1); });
            })), "foreign");
            foreign.start();
            foreign.join();
            require(late.get().isCompletedExceptionally(), "foreign write was accepted");
            String failure = late.get().handle((value, error) -> error.toString()).join();
            require(failure.contains("belongs to the app thread"), "foreign write lost its refusal");
            System.out.println("late chain: " + failure);
        }
        int first = app.build(tx -> (int) tx.items(rows).stream()
                .filter(entry -> entry.key.equals("first")).count());
        int second = app.build(tx -> (int) tx.items(rows).stream()
                .filter(entry -> entry.key.equals("second")).count());
        int wantedFirst = mode.equals("before") || mode.equals("inline") || mode.equals("late") ? 0 : 1;
        int wantedReports = mode.equals("owned") || mode.equals("inside") || mode.equals("before") ? 1 : 0;
        require(inherited[0] == mode.equals("inline"), "completion boundary changed");
        require(first == wantedFirst, "completed scope changed");
        require(second == 0, "throwing scope committed");
        require(reports == wantedReports, "report count mismatch");
        boolean failed = !mode.equals("inline") && !mode.equals("late") && !mode.equals("caught");
        require(terminal.isCompletedExceptionally() == failed, "terminal fault state changed");
        System.out.printf("java-async-probe: %s inherited=%s first=%d second=%d reports=%d terminal-failed=%s%n",
                mode, inherited[0], first, second, reports, failed);
    }

    public static void main(String[] args) throws Exception {
        System.load(args[1]);
        KayaRing.attach();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread app = new Thread(() -> {
            try { measure(args[0]); }
            catch (Throwable error) { failure.set(error); }
        }, "kaya-measure");
        app.start();
        app.join();
        if (failure.get() != null) throw new AssertionError("measurement failed", failure.get());
    }
}
