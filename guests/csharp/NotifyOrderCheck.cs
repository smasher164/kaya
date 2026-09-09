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
    }
}
