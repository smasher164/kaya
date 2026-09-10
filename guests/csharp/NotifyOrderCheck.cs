// The process-level notification handler's DISPATCH ORDER
// (docs/tasks-s9-plan.md R1), run rather than read. Headless, driven by
// tools/check-abort.py with KAYA_CHECK=notify.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

static class NotifyOrderCheck
{
    static void Check(bool ok, string what)
    {
        if (!ok)
        {
            Console.WriteLine("notify-order: FAIL — " + what);
            Environment.Exit(1);
        }
    }

    // A tap on a reminder after the app has exited relaunches the process,
    // and THAT process never called ShowNotification, so the one-shot table
    // is empty for the id that started it. The ring loop's switch has no
    // seam a test can reach, so these drive KayaApp.NotificationResult,
    // which the arm calls and tools/check-sugar-surface.py holds it to
    // calling.
    public static void Run()
    {
        var app = new KayaApp();
        var oneShot = new List<uint>();
        var process = new List<(ulong, uint)>();
        app.OnNotificationActivation((tx, id, outcome) => process.Add((id, outcome)));
        app.Build(tx => tx.ShowNotification(
            12, title: "bound at the show",
            onResult: (inner, outcome) => oneShot.Add(outcome)));

        // CASE 1: an id WITH a one-shot handler is answered by it, and the
        // process-level handler is not consulted at all.
        app.NotificationResult(12, KayaWire.NotificationOutcomeActivated);
        Check(oneShot.Count == 1 && oneShot[0] == KayaWire.NotificationOutcomeActivated,
            "the one-shot handler did not answer");
        Check(process.Count == 0,
            "the process-level handler answered an id that HAD a one-shot handler");

        // CASE 2: an id this process never showed — the relaunch case.
        app.NotificationResult(77, KayaWire.NotificationOutcomeActivated);
        Check(process.Count == 1 && process[0] == (77ul, KayaWire.NotificationOutcomeActivated),
            "a result with no one-shot handler did not reach the process-level one");

        // CASE 3: it does NOT retire.
        app.NotificationResult(78, KayaWire.NotificationOutcomeRefused);
        Check(process.Count == 2 && process[1] == (78ul, KayaWire.NotificationOutcomeRefused),
            "the process-level handler retired after its first result");

        // AND THE DROP IS ANNOUNCED, compared in full: a drop nobody
        // announced is R5's defect class, and this sentence is the only
        // signal a relaunched process's author gets that nothing listened.
        app.OnNotificationActivation(null!);
        var said = new StringWriter();
        TextWriter real = Console.Error;
        Console.SetError(said);
        try
        {
            app.NotificationResult(41, KayaWire.NotificationOutcomeRefused);
        }
        finally
        {
            Console.SetError(real);
        }
        string want = "kaya: notification 41 outcome refused reached no handler — "
            + "none was bound at the show and no process-level handler is "
            + "registered (App.OnNotificationActivation)";
        string got = said.ToString().Trim();
        Check(got == want, $"the drop was announced as \"{got}\", wanted \"{want}\"");

        Console.WriteLine("notify-order: OK — the one-shot wins, an unknown id "
            + "reaches the process handler, it does not retire, and an "
            + "unclaimed result announces its drop");

        // The SAME app: one per process is the family's rule, and the
        // link tables are independent of the notification ones.
        Links(app);
    }

    // THE APP-LINK ROUTES (docs/app-links-plan.md §4). Four things no lane
    // can see: the declaration's BYTES, the ids the counter mints, the
    // dispatch by route id, and the two drops — a route that matched and
    // reached no handler says so, route 0 says nothing because the CORE
    // already announced that miss naming every declared pattern. NOTHING
    // HERE READS A PATTERN: the core is the one parser and the one author
    // of every declaration refusal, and it faults at apply.
    static void Links(KayaApp app)
    {
        var seen = new List<(string, string)>();
        app.Link("task/{key}", (tx, p) => seen.Add(("task", p["key"])));
        app.Link("{section}", (tx, p) => seen.Add(("section", p["section"])));

        // CASE 1: the declaration is the generated record, parked, and
        // the ids come from the binding's own counter starting at 1.
        Check(app.pendingRecords.Count == 2
              && app.pendingRecords[0].AsSpan().SequenceEqual(
                  KayaWire.TxDeclareLinkRoute(1, "task/{key}"))
              && app.pendingRecords[1].AsSpan().SequenceEqual(
                  KayaWire.TxDeclareLinkRoute(2, "{section}")),
            "link did not park the generated records, or minted the wrong ids");

        // CASE 2: a link on a declared route reaches its handler with the
        // captures, and the registration does NOT retire.
        var captures = new Dictionary<string, string> { ["key"] = "t2" };
        app.LinkOpened(1, "dev.kaya.aurora.notes://task/t2", captures);
        app.LinkOpened(1, "dev.kaya.aurora.notes://task/t1",
            new Dictionary<string, string> { ["key"] = "t1" });
        app.LinkOpened(2, "dev.kaya.aurora.notes://today",
            new Dictionary<string, string> { ["section"] = "today" });
        Check(seen.Count == 3 && seen[0] == ("task", "t2")
              && seen[1] == ("task", "t1") && seen[2] == ("section", "today"),
            "a link did not reach its route's handler with the captures, or the registration retired");

        // CASE 3 and CASE 4: the two drops.
        var said = new StringWriter();
        TextWriter real = Console.Error;
        Console.SetError(said);
        try
        {
            app.LinkOpened(9, "dev.kaya.aurora.notes://task/t2",
                new Dictionary<string, string>());
            app.LinkOpened(0, "dev.kaya.aurora.notes://nope",
                new Dictionary<string, string>());
        }
        finally
        {
            Console.SetError(real);
        }
        Check(seen.Count == 3, "a route this process never declared reached a handler");
        string want = "kaya: link dev.kaya.aurora.notes://task/t2 matched route 9 "
            + "and reached no handler — none is registered for it (App.Link)";
        string got = said.ToString().Trim();
        Check(got == want, $"the link drop was announced as \"{got}\", wanted \"{want}\"");

        Console.WriteLine("link-route: OK — the declaration parks the generated "
            + "record, the dispatch is by route id and does not retire, an "
            + "unknown route announces its drop, and route 0 is silent");
    }
}
