package dev.kaya;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

public final class AsyncCheck {
    static final String SENTENCE = "kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed";
    static KayaApp app;
    static Thread owner;
    static int reports;
    static final CountDownLatch reported = new CountDownLatch(1);
    static final ByteArrayOutputStream errors = new ByteArrayOutputStream();
    static final List<KayaApp.PickedFile> FILES = List.of(
            new KayaApp.PickedFile(901, "first", null), new KayaApp.PickedFile(902, "second", null));
    record Request(int kind, long id, CompletableFuture<?> answer) {}

    static void require(boolean ok, String why) {
        if (!ok) throw new AssertionError("java-async: " + why);
    }

    static void refuse(String sentence, Runnable body) {
        try { body.run(); }
        catch (IllegalStateException error) {
            require(error.getMessage().contains(sentence), "wrong refusal: " + error);
            return;
        }
        throw new AssertionError("java-async: missing refusal: " + sentence);
    }

    static long id(Object request) {
        try {
            Class<?> type = request.getClass();
            if (type.getSimpleName().startsWith("Future")) type = type.getSuperclass();
            Field field = type.getDeclaredField("id");
            field.setAccessible(true);
            return field.getLong(request);
        } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
    }

    static int registrations() {
        try {
            int count = 0;
            for (String name : List.of("alerts", "fileDialogs", "clipboardReads")) {
                Field field = KayaApp.class.getDeclaredField(name);
                field.setAccessible(true);
                count += ((Map<?, ?>) field.get(app)).size();
            }
            return count;
        } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
    }

    static Request request(KayaApp.Tx tx, int kind) {
        return switch (kind) {
            case 0 -> {
                var ref = tx.showAlert().action("yes").cancel("no");
                yield new Request(kind, id(ref), ref.showFuture());
            }
            case 1, 2 -> {
                var ref = kind == 1 ? tx.pickFile() : tx.pickFiles();
                yield new Request(kind, id(ref), ref.showFuture());
            }
            case 3 -> {
                var ref = tx.saveFile("copy");
                yield new Request(kind, id(ref), ref.showFuture());
            }
            case 4 -> {
                var ref = tx.readClipboard().text();
                yield new Request(kind, id(ref), ref.sendFuture());
            }
            default -> throw new AssertionError(kind);
        };
    }

    static Request request(int kind) {
        return app.build(tx -> { return request(tx, kind); });
    }

    static void answer(Request request, boolean cancel) {
        switch (request.kind()) {
            case 0 -> app.alertResult(request.id(), cancel ? KayaApp.AlertChoice.CANCEL : KayaApp.AlertChoice.ACTION0);
            case 1, 2, 3 -> app.fileDialogResult(request.id(), cancel ? List.of() : FILES);
            case 4 -> app.clipboardResult(request.id(), cancel ? null : new KayaApp.Representation.Text("hello"));
            default -> throw new AssertionError(request.kind());
        }
    }

    static void drain() { app.drainAsync(); app.drainAsync(); }

    static void forms() {
        for (int kind = 0; kind < 5; kind++) {
            for (boolean cancel : new boolean[]{false, true}) {
                Request request = request(kind);
                require(!request.answer().isDone(), "request completed before result");
                int[] calls = {0};
                var terminal = request.answer().thenAccept(value -> {
                    require(Thread.currentThread() == owner, "continuation changed threads");
                    require(app.transactionDepth == 0, "continuation inherited a transaction");
                    calls[0]++;
                });
                answer(request, cancel);
                require(!request.answer().isDone(), "completion was not deferred");
                require(registrations() == 0, "result registration did not retire");
                require(app.liveAlert == 0 && app.liveFileDialog == 0, "result slot did not retire");
                drain();
                require(request.answer().isDone(), "completion did not resolve");
                terminal.join();
                Object expected = switch (kind) {
                    case 0 -> cancel ? KayaApp.AlertChoice.CANCEL : KayaApp.AlertChoice.ACTION0;
                    case 1, 2 -> cancel ? List.of() : FILES;
                    case 3 -> cancel ? null : FILES.get(0);
                    case 4 -> cancel ? null : new KayaApp.Representation.Text("hello");
                    default -> throw new AssertionError(kind);
                };
                require(java.util.Objects.equals(request.answer().join(), expected), "result value changed");
                answer(request, cancel);
                drain();
                require(calls[0] == 1, "duplicate result completed twice");
            }
        }
        System.out.println("java-async: five result forms, cancellation and duplicate retirement passed");
    }

    static void scopes() {
        for (String mode : List.of("before", "after", "inside", "caught", "recovered", "parent", "bare")) {
            KayaApp.Collection rows = app.build(tx -> { return tx.collection(); });
            Request request = request(0);
            int oldReports = reports;
            CompletableFuture<Void> terminal = request.answer().thenAccept(choice -> {
                require(app.transactionDepth == 0, "continuation inherited a transaction");
                if (mode.equals("before")) throw new IllegalStateException("before scope");
                app.build(tx -> { tx.insert(rows, "first", 1); });
                if (mode.equals("inside") || mode.equals("caught")) {
                    Consumer<KayaApp.Tx> throwing = tx -> {
                        tx.insert(rows, "second", 2);
                        throw new IllegalStateException("inside scope");
                    };
                    try { app.build(throwing); }
                    catch (IllegalStateException error) {
                        if (!mode.equals("caught")) throw error;
                    }
                } else throw new IllegalStateException("after completed scope");
            });
            if (mode.equals("recovered")) terminal = terminal.exceptionally(error -> null);
            if (mode.equals("parent")) app.observe(request.answer());
            else if (!mode.equals("bare")) app.observe(terminal);
            answer(request, false);
            drain();
            int first = app.build(tx -> (int) tx.items(rows).stream().filter(row -> row.key.equals("first")).count());
            int second = app.build(tx -> (int) tx.items(rows).stream().filter(row -> row.key.equals("second")).count());
            require(first == (mode.equals("before") ? 0 : 1), "completed scope changed");
            require(second == 0, "throwing scope committed");
            int expected = List.of("before", "after", "inside").contains(mode) ? 1 : 0;
            require(reports - oldReports == expected, "report count mismatch: " + mode);
            require(terminal.isCompletedExceptionally() == !List.of("caught", "recovered").contains(mode), "terminal fault changed");
        }
        System.out.println("java-async: seven scope and ownership cases passed");
    }

    static void lifetimes() {
        Request alert = request(0);
        refuse("another alert", () -> request(0));
        require(app.liveAlert == alert.id(), "overlap changed first alert");
        answer(alert, true);
        drain();
        for (int kind : new int[]{1, 3}) {
            Request file = request(kind);
            refuse("another file dialog", () -> request(kind == 1 ? 3 : 1));
            require(app.liveFileDialog == file.id(), "overlap changed first file dialog");
            answer(file, true);
            drain();
        }
        Request a = request(4), b = request(4);
        answer(b, false);
        drain();
        require(b.answer().isDone() && !a.answer().isDone(), "clipboard reads were coupled");
        answer(a, true);
        drain();
        for (int kind = 0; kind < 5; kind++) {
            final int form = kind;
            Request[] aborted = {null};
            Consumer<KayaApp.Tx> body = tx -> {
                aborted[0] = request(tx, form);
                throw new IllegalStateException("request aborted");
            };
            refuse("request aborted", () -> app.build(body));
            require(registrations() == 0, "aborted request kept registration");
            require(app.liveAlert == 0 && app.liveFileDialog == 0, "aborted request kept slot");
            require(!aborted[0].answer().isDone(), "aborted request completed inside rollback");
            drain();
            require(aborted[0].answer().isCompletedExceptionally(), "aborted request left future pending");
            answer(aborted[0], false);
            drain();
        }
        app.build(tx -> {
            refuse("cancel slot", () -> tx.showAlert().showFuture());
            require(registrations() == 0 && app.liveAlert == 0, "invalid request kept registration or slot");
            var alertRef = tx.showAlert().cancel("no");
            alertRef.onResult((t, choice) -> {});
            refuse("callback or a future", () -> alertRef.showFuture());
            var pick = tx.pickFile();
            pick.onResult((t, files) -> {});
            refuse("callback or a future", () -> pick.showFuture());
            var save = tx.saveFile("copy");
            save.onResult((t, file) -> {});
            refuse("callback or a future", () -> save.showFuture());
            var clip = tx.readClipboard();
            clip.onResult((t, value) -> {});
            refuse("callback or a future", () -> clip.sendFuture());
            require(registrations() == 0, "mixed callback/future registered");
            var one = tx.readClipboard().text();
            one.sendFuture();
            refuse("already sent", () -> one.sendFuture());
            app.clipboardResult(id(one), null);
            refuse("inside a transaction", () -> app.drainAsync());
        });
        drain();
        System.out.println("java-async: overlap, abort cleanup, invalid requests and alias walls passed");
    }

    static void callbacks() {
        for (int form = 0; form < 5; form++) {
            int kind = form;
            int[] calls = {0};
            Consumer<KayaApp.Tx> body = tx -> {
                require(app.transactionDepth == 1, "callback lost its transaction");
                calls[0]++;
            };
            long id = app.build(tx -> { return switch (kind) {
                case 0 -> tx.showAlert().onResult((t, v) -> body.accept(t)).cancel("no").show();
                case 1, 2 -> (kind == 1 ? tx.pickFile() : tx.pickFiles()).onResult((t, v) -> body.accept(t)).filter("Text", "txt").show();
                case 3 -> tx.saveFile("copy").onResult((t, v) -> body.accept(t)).filter("Text", "txt").show();
                case 4 -> tx.readClipboard().onResult((t, v) -> body.accept(t)).text().send();
                default -> throw new AssertionError(kind);
            }; });
            Request callback = new Request(kind, id, null);
            answer(callback, true);
            answer(callback, true);
            require(calls[0] == 1 && registrations() == 0, "callback did not retire exactly once");
        }
        long[] discarded = new long[3];
        Consumer<KayaApp.Tx> abort = tx -> {
            discarded[0] = tx.showAlert().cancel("no").onResult((t, v) -> { throw new AssertionError("aborted callback ran"); }).show();
            discarded[1] = tx.pickFile().onResult((t, v) -> { throw new AssertionError("aborted callback ran"); }).show();
            discarded[2] = tx.readClipboard().onResult((t, v) -> { throw new AssertionError("aborted callback ran"); }).send();
            throw new IllegalStateException("callback registration aborted");
        };
        refuse("callback registration aborted", () -> app.build(abort));
        require(registrations() == 0 && app.liveAlert == 0 && app.liveFileDialog == 0, "aborted callback kept registration or slot");
        app.alertResult(discarded[0], KayaApp.AlertChoice.CANCEL);
        app.fileDialogResult(discarded[1], List.of());
        app.clipboardResult(discarded[2], null);
        System.out.println("java-async: five callback forms still dispatch transactionally");
    }

    static void boundaries() throws Exception {
        Request[] request = {null};
        KayaApp.Tx[] retained = {null};
        app.build(tx -> { retained[0] = tx; request[0] = request(tx, 0); });
        var stale = request[0].answer().thenAccept(value -> retained[0].label("late"));
        answer(request[0], false);
        drain();
        require(stale.isCompletedExceptionally(), "retained transaction accepted write");
        AtomicReference<CompletableFuture<?>> foreign = new AtomicReference<>();
        Thread worker = new Thread(() -> {
            foreign.set(request[0].answer().thenAccept(value -> app.build(tx -> { tx.label("foreign"); })));
        }, "foreign");
        worker.start(); worker.join();
        require(foreign.get().isCompletedExceptionally(), "foreign continuation accepted write");
        require(foreign.get().handle((v, e) -> e.toString()).join().contains("belongs to the app thread"), "foreign refusal changed");
        app.tplDepth++;
        try {
            refuse("template body", () -> app.observe(CompletableFuture.completedFuture(null)));
            refuse("template body", () -> app.drainAsync());
            app.build(tx -> { refuse("template body", () -> tx.pickFile().showFuture()); });
        } finally { app.tplDepth--; }
        int previous = reports;
        app.build(tx -> {
            app.observe(CompletableFuture.failedFuture(new IllegalStateException("already failed")));
            require(reports == previous, "observe reported inside caller transaction");
        });
        drain();
        require(reports == previous + 1, "already-failed stage was not reported");
        Error fatal = new AssertionError("fatal async error");
        app.observe(CompletableFuture.failedFuture(fatal));
        try { app.drainAsync(); throw new IllegalStateException("fatal error was swallowed"); }
        catch (Error got) { require(got == fatal, "fatal error identity changed"); }
        System.out.println("java-async: stale transaction, foreign thread, template and fatal-error walls passed");
    }

    static void installReporter() {
        System.setErr(new PrintStream(errors, true, StandardCharsets.UTF_8) {
            @Override public void println(String text) {
                if (text.equals(SENTENCE)) {
                    require(Thread.currentThread() == owner && app.transactionDepth == 0, "reporter inherited a transaction or foreign thread");
                    reports++;
                    reported.countDown();
                }
                super.println(text);
            }
        });
    }

    public static void main(String[] args) throws Exception {
        PrintStream original = System.err;
        try { run(args); }
        finally {
            System.setErr(original);
            System.out.print(errors.toString(StandardCharsets.UTF_8));
        }
    }

    static void run(String[] args) throws Exception {
        System.load(System.getenv("KAYA_LIB"));
        KayaRing.attach();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        CountDownLatch ready = new CountDownLatch(1);
        CompletableFuture<Void> foreign = new CompletableFuture<>();
        owner = new Thread(() -> {
            try {
                KayaApp.claimAppThread();
                app = new KayaApp();
                installReporter();
                if (args.length != 0 && args[0].equals("loop")) {
                    app.build(tx -> { app.observe(foreign); });
                    ready.countDown();
                    app.dispatchLoop();
                } else {
                    forms(); scopes(); lifetimes(); callbacks(); boundaries();
                    require(reports == 4, "total report count changed");
                    require(!errors.toString(StandardCharsets.UTF_8).contains("handler threw (transaction rolled back)"), "async failure used synchronous reporter");
                    System.out.println("java-async: all checks passed");
                }
            } catch (Throwable error) { failure.set(error); ready.countDown(); }
        }, "kaya-async-check");
        owner.setDaemon(true);
        owner.start();
        if (args.length != 0 && args[0].equals("loop")) {
            require(ready.await(5, TimeUnit.SECONDS), "loop did not become ready");
            boolean parked = false;
            for (int i = 0; i < 500 && !parked; i++) {
                parked = java.util.Arrays.stream(owner.getStackTrace()).anyMatch(frame -> frame.getMethodName().equals("waitOccurrences"));
                if (!parked) Thread.sleep(10);
            }
            require(parked, "loop never parked in waitOccurrences");
            foreign.completeExceptionally(new IllegalStateException("foreign final stage"));
            require(reported.await(5, TimeUnit.SECONDS), "async queue did not wake and drain");
            require(reports == 1, "foreign final stage report count changed");
            System.out.println("java-async: real parked occurrence loop woke and reported outside a transaction");
        } else {
            owner.join(10000);
            require(!owner.isAlive(), "checks did not finish");
        }
        if (failure.get() != null) throw new AssertionError("java-async checks failed", failure.get());
    }
}
