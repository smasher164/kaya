using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

static class AsyncDialogCheck
{
    const string Failure = "kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed";

    static void Check(bool ok, string message)
    {
        if (!ok) throw new InvalidOperationException("async-dialog check: " + message);
    }

    static void Refused(Action body, string sentence)
    {
        try { body(); }
        catch (Exception e) when (e.Message.Contains(sentence)) { return; }
        throw new InvalidOperationException("async-dialog check: missing refusal: " + sentence);
    }

    public static void Run(KayaApp app)
    {
        KayaApp.ClaimAppThread();
        var previous = SynchronizationContext.Current;
        app.InstallAsyncContext();
        try
        {
            ScopeCases(app);
            Results(app);
            InvalidRequests(app);
            Lifetimes(app);
            Boundaries(app);
        }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
        Console.WriteLine("async-dialog: C# scope, completion, lifetime and thread checks OK");
    }

    static void ScopeCases(KayaApp app)
    {
        int owner = Environment.CurrentManagedThreadId;
        foreach (string mode in new[] { "ambient", "explicit", "inside", "raw" })
        {
            var signal = app.Build(tx => tx.Signal("initial"));
            var answer = new TaskCompletionSource<int>();
            bool resumed = false, empty = false, stale = false, noAmbient = false;
            var errors = new StringWriter();
            var stderr = Console.Error;
            Console.SetError(errors);
            try
            {
                app.Post(async tx =>
                {
                    tx.Write(signal, "before");
                    await answer.Task;
                    resumed = Environment.CurrentManagedThreadId == owner;
                    empty = app.CurrentTx == null;
                    try { tx.Write(signal, "stale"); }
                    catch (ObjectDisposedException) { stale = true; }
                    try { KayaApp.AmbientTx("async write").Write(signal, "ambient"); }
                    catch (InvalidOperationException) { noAmbient = true; }
                    if (mode != "ambient") app.Build(next =>
                    {
                        next.Write(signal, "after");
                        if (mode == "inside") throw new Exception("scope failure");
                    });
                    throw new Exception("outside failure");
                });
                app.DrainPosted();
                Check(Equals(app.SignalMirrors[signal.Id], "before"), "pre-await commit lost");
                var worker = new Thread(() => answer.SetResult(1));
                worker.Start();
                Check(worker.Join(5000), "answer worker stalled");
                app.DrainAsync();
                Check(errors.ToString() == "", "async failure was not separately queued");
                app.DrainAsync();
            }
            finally { Console.SetError(stderr); }
            Check(resumed, "continuation did not resume on owner thread");
            Check(empty && noAmbient, "continuation had an ambient transaction");
            Check(stale, "retained transaction was not refused");
            string expected = mode is "ambient" or "inside" ? "before" : "after";
            Check(Equals(app.SignalMirrors[signal.Id], expected), "explicit scope rollback/commit mismatch");
            string said = errors.ToString();
            Check(said.Contains(Failure) && !said.Contains("(transaction rolled back)"),
                "async reporter claimed rollback or lost its sentence");
            Check(said.Contains(mode == "inside" ? "scope failure" : "outside failure"),
                "async reporter lost the exception");
            Console.WriteLine($"async-dialog: scope {mode} final={expected}, owner=True, ambient=False, stale refused");
        }
    }

    static void Results(KayaApp app)
    {
        var first = app.ShowAlertAsync(cancel: "Keep");
        ulong alert = app.liveAlert;
        Refused(() => app.ShowAlertAsync(cancel: "Keep"), "another alert");
        bool resumed = false, empty = false;
        async void Observe()
        {
            Check(await first == AlertChoice.Cancel, "alert cancellation changed");
            resumed = true;
            empty = app.CurrentTx == null;
        }
        Observe();
        app.AlertResult(alert, AlertChoice.Cancel);
        Check(app.liveAlert == 0 && app.alerts.Count == 0, "alert id did not retire");
        Check(!first.IsCompleted && !resumed, "future completed inside result dispatch");
        app.DrainAsync();
        Check(first.IsCompletedSuccessfully && resumed && empty, "alert completion did not run outside a transaction");
        app.AlertResult(alert, AlertChoice.Action0);
        app.DrainAsync();
        Check(first.Result == AlertChoice.Cancel, "duplicate result changed the answer");

        foreach (bool multiple in new[] { false, true })
        {
            var picked = multiple ? app.PickFilesAsync() : app.PickFileAsync();
            Refused(() => app.SaveFileAsync("blocked"), "another file dialog");
            app.FileDialogResult(app.liveFileDialog, new List<PickedFile>());
            Check(!picked.IsCompleted, "picker completed inside result dispatch");
            app.DrainAsync();
            Check(picked.IsCompletedSuccessfully && picked.Result.Count == 0 && app.fileDialogs.Count == 0, "picker cancel or retirement changed");
        }
        var saved = app.SaveFileAsync("copy");
        Refused(() => app.PickFileAsync(), "another file dialog");
        app.FileDialogResult(app.liveFileDialog, new List<PickedFile>());
        app.DrainAsync();
        Check(saved.IsCompletedSuccessfully && saved.Result == null, "save cancellation changed");

        foreach (Representation? value in new Representation?[] { null, new Representation.Text("hello") })
        {
            var read = app.ReadClipboardAsync(Tx.AcceptText);
            app.ClipboardResult(app.nextClipboardRead, value);
            Check(!read.IsCompleted, "clipboard completed inside result dispatch");
            app.DrainAsync();
            Check(read.IsCompletedSuccessfully && Equals(read.Result, value) && app.clipboardReads.Count == 0, "clipboard result or retirement changed");
        }
        _ = app.ShowAlertAsync(cancel: "Keep");
        app.AlertResult(app.liveAlert, AlertChoice.Action1);
        app.DrainAsync();
        Check(app.alerts.Count == 0 && app.liveAlert == 0, "unawaited dialog leaked its slot");
        Console.WriteLine("async-dialog: all five result forms, cancellation, duplicate and dropped answers OK");
    }

    static void InvalidRequests(KayaApp app)
    {
        Refused(() => app.ShowAlertAsync(title: null!, cancel: "Keep"), "value must be");
        Refused(() => app.PickFileAsync(filters: new[] { ("Text", (string)null!) }), "value must be");
        Refused(() => app.PickFilesAsync(filters: new[] { ("Text", (string)null!) }), "value must be");
        Refused(() => app.SaveFileAsync(null!), "value must be");
        Refused(() => app.ReadClipboardAsync("invalid format"), "not an accept-list entry");
        Check(app.alerts.Count == 0 && app.fileDialogs.Count == 0 && app.clipboardReads.Count == 0
            && app.liveAlert == 0 && app.liveFileDialog == 0,
            "invalid request leaked a registration");
        Console.WriteLine("async-dialog: five invalid request inputs refused without registration leaks");
    }

    static void Lifetimes(KayaApp app)
    {
        foreach (string kind in new[] { "alert", "file", "save", "clip" })
        {
            Task? pending = null;
            Refused(() => app.Build(tx =>
            {
                pending = kind switch
                {
                    "alert" => app.ShowAlertAsync(cancel: "Keep"),
                    "file" => app.PickFileAsync(),
                    "save" => app.SaveFileAsync("copy"),
                    _ => app.ReadClipboardAsync(Tx.AcceptText),
                };
                throw new Exception("abandon request");
            }), "abandon request");
            Check(app.liveAlert == 0 && app.liveFileDialog == 0 && app.alerts.Count == 0
                && app.fileDialogs.Count == 0 && app.clipboardReads.Count == 0,
                "abandoned request leaked a registration");
            app.DrainAsync();
            Check(pending != null && pending.IsFaulted
                && pending.Exception!.ToString().Contains("request transaction was rolled back"),
                "abandoned request left an unresolved future");
        }
        bool callback = false;
        ulong id = app.Build(tx => tx.ShowAlert(cancel: "Keep", onResult: (tx, _) =>
        {
            Check(app.CurrentTx == tx, "callback lost its transaction");
            callback = true;
            tx.ShowAlert(cancel: "Next");
        }));
        app.AlertResult(id, AlertChoice.Cancel);
        Check(callback && app.liveAlert != 0, "callback could not open the next dialog");
        app.AlertResult(app.liveAlert, AlertChoice.Cancel);
        Check(app.liveAlert == 0, "handlerless result did not retire the slot");
        Console.WriteLine("async-dialog: request rollback and callback compatibility OK");
    }

    static void Boundaries(KayaApp app)
    {
        app.Build(_ => Refused(app.DrainAsync, "async work cannot run inside a transaction"));
        bool entered = false;
        Action<Tx> invalid = async _ => { entered = true; await Task.Yield(); };
        Refused(() => app.Build(invalid), "Build requires a synchronous body");
        Func<Tx, Task> invalidTask = async _ => { entered = true; await Task.Yield(); };
        Refused(() => app.Build(invalidTask), "Build requires a synchronous body");
        Check(!entered, "async Build entered before being refused");
        app.Build(tx =>
        {
            var rows = tx.Collection();
            tx.Each(rows, row => Refused(() => app.ShowAlertAsync(cancel: "Keep"), "template body"));
        });
        bool wrongThread = false;
        var worker = new Thread(() =>
        {
            try { app.ShowAlertAsync(cancel: "Keep"); }
            catch (InvalidOperationException e) { wrongThread = e.Message.Contains("app thread"); }
        });
        worker.Start();
        Check(worker.Join(5000) && wrongThread, "foreign-thread async request was not refused");
        Console.WriteLine("async-dialog: open-transaction, async-Build, template and foreign-thread refusals OK");
    }
}
