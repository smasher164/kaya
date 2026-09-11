// The WinUI 3 rich-text probe (docs/rich-text-plan.md §3.3; R2, R4, R6, R9).
//
// kaya's textarea IS a RichEditBox already, held to a plain-text CONTRACT by
// two property pins and a cancelled Paste (crates/kaya/src/winui/mod.rs,
// pin_plain_text). This probe holds two of them side by side - one pinned
// exactly as kaya pins it, one left alone - and takes six readings:
//
//   M1  the final EOP: GetText lengths against StoryLength for "", "abc",
//       "abc\r" and two paragraphs, on BOTH controls, plus AllowFinalEop.
//   M2  unit arithmetic over "h\u00e9llo \ud83d\udc4b \u4e16\u754c".
//   M3  undo suppression: UndoLimit = 0 against real Ctrl+Z, against a
//       format change, raised back at runtime, and BeginUndoGroup grouping.
//   M4  edit reporting: the event ORDER for a keystroke, a Ctrl+V paste, a
//       programmatic SetText and an attribute-only change.
//   M5  read-back: the FormatEffect tri-state, and ITextRange.Link.
//   M6  a formatted specimen left standing for the out-of-process UIA
//       client (uia.ps1), which reads the TextPattern attributes.
//
// Real keys, not property writes, wherever the question is about user input:
// the process runs in the guest's interactive session (schtasks /it), so
// keybd_event lands in its own foreground window.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace KayaRichProbe
{
    public static class Log
    {
        static readonly object Gate = new object();
        public static string Path =
            Environment.GetEnvironmentVariable("KAYA_RT_LOG") ?? @"C:\kaya\richtext-probe\log.txt";

        public static void Line(string s)
        {
            lock (Gate)
            {
                var stamp = DateTime.Now.ToString("HH:mm:ss.fff");
                try { File.AppendAllText(Path, stamp + " " + s + "\r\n", Encoding.UTF8); }
                catch { }
                Console.WriteLine(stamp + " " + s);
                Console.Out.Flush();
            }
        }
    }

    public static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
                Log.Line("probe UNHANDLED " + e.ExceptionObject);
            Log.Line("probe Main entered");
            try
            {
                WinRT.ComWrappersSupport.InitializeComWrappers();
                Application.Start((p) =>
                {
                    var q = DispatcherQueue.GetForCurrentThread();
                    System.Threading.SynchronizationContext.SetSynchronizationContext(
                        new DispatcherQueueSynchronizationContext(q));
                    new ProbeApp();
                });
                Log.Line("probe Application.Start returned");
            }
            catch (Exception ex)
            {
                Log.Line("probe Main THREW " + ex);
            }
        }
    }

    public partial class ProbeApp : Application
    {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] static extern short VkKeyScanW(char ch);
        [DllImport("user32.dll")] static extern int SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool EmptyClipboard();
        [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint fmt, IntPtr mem);
        [DllImport("user32.dll")] static extern bool CloseClipboard();
        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr mem);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr mem);

        const uint KEYUP = 0x2;
        const byte VK_SHIFT = 0x10;
        const byte VK_CONTROL = 0x11;
        const byte VK_END = 0x23;
        const byte VK_Z = 0x5a;
        const byte VK_V = 0x56;
        const byte VK_B = 0x42;

        const string DIR = @"C:\kaya\richtext-probe";
        const string CR = "\r";

        Window win;
        RichEditBox pinned;   // kaya's two pins + the cancelled Paste
        RichEditBox rich;     // the same control, untouched
        IntPtr hwnd;

        int seq;
        readonly List<string> events = new List<string>();

        public ProbeApp()
        {
            InitializeComponent();
            UnhandledException += (s, e) =>
            {
                Log.Line("probe XAML UnhandledException: " + e.Message + " / " + e.Exception);
                e.Handled = true;
            };
        }

        // ---- helpers -----------------------------------------------------

        /// Every non-printable and non-ASCII character spelled out, so a CR, a
        /// surrogate half and a final EOP are all legible in the log.
        static string Show(string s)
        {
            if (s == null) return "<null>";
            var b = new StringBuilder("\"");
            foreach (char c in s)
            {
                if (c == '\r') b.Append("\\r");
                else if (c == '\n') b.Append("\\n");
                else if (c == '"') b.Append("\\\"");
                else if (c < 0x20 || c > 0x7e) b.Append("\\u").Append(((int)c).ToString("x4"));
                else b.Append(c);
            }
            return b.Append('"').ToString();
        }

        static string Utf16Codes(string s)
        {
            if (s == null) return "<null>";
            var parts = new List<string>();
            foreach (char c in s) parts.Add(((int)c).ToString("x4"));
            return "[" + string.Join(" ", parts) + "]";
        }

        static string Get(RichEditTextDocument doc, TextGetOptions opt)
        {
            string s;
            doc.GetText(opt, out s);
            return s;
        }

        static int StoryLen(RichEditTextDocument doc)
        {
            return doc.GetRange(0, 0).StoryLength;
        }

        void Ev(string s)
        {
            lock (events) events.Add((++seq).ToString() + ":" + s);
        }

        string TakeEvents()
        {
            lock (events)
            {
                var s = string.Join(" | ", events);
                events.Clear();
                return s.Length == 0 ? "<none>" : s;
            }
        }

        static void SetClipboardText(string s)
        {
            var bytes = Encoding.Unicode.GetBytes(s + "\0");
            IntPtr h = GlobalAlloc(0x0042 /* GHND */, (UIntPtr)(uint)bytes.Length);
            IntPtr p = GlobalLock(h);
            Marshal.Copy(bytes, 0, p, bytes.Length);
            GlobalUnlock(h);
            if (OpenClipboard(IntPtr.Zero))
            {
                EmptyClipboard();
                SetClipboardData(13 /* CF_UNICODETEXT */, h);
                CloseClipboard();
            }
        }

        void SendChar(char ch)
        {
            short scan = VkKeyScanW(ch);
            byte vk = (byte)(scan & 0xff);
            bool shift = ((scan >> 8) & 1) != 0;
            if (shift) keybd_event(VK_SHIFT, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
            if (shift) keybd_event(VK_SHIFT, 0, KEYUP, UIntPtr.Zero);
        }

        void SendVk(byte vk)
        {
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
        }

        void SendCtrl(byte vk)
        {
            keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
            keybd_event(VK_CONTROL, 0, KEYUP, UIntPtr.Zero);
        }

        static string Effect(FormatEffect e)
        {
            return e.ToString() + "(" + ((int)e).ToString() + ")";
        }

        static string BoldOf(RichEditTextDocument doc, int a, int b)
        {
            try { return Effect(doc.GetRange(a, b).CharacterFormat.Bold); }
            catch (Exception ex) { return "<threw " + ex.GetType().Name + ">"; }
        }

        /// The object ITextRange.CharacterFormat hands back is LIVE - mutating
        /// it applies at once, which run 1 measured by seeing TWO TextChanging
        /// events for one intended change. This is the one-apply route.
        static void SetBold(RichEditTextDocument doc, int a, int b, FormatEffect v)
        {
            doc.GetRange(a, b).CharacterFormat.Bold = v;
        }

        static void SetBoldAssignBack(RichEditTextDocument doc, int a, int b, FormatEffect v)
        {
            var r = doc.GetRange(a, b);
            var cf = r.CharacterFormat;
            cf.Bold = v;
            r.CharacterFormat = cf;
        }

        static void SetItalic(RichEditTextDocument doc, int a, int b, FormatEffect v)
        {
            doc.GetRange(a, b).CharacterFormat.Italic = v;
        }

        /// Every earlier phase leaves the DEFAULT character format behind it, so
        /// a fresh SetText inherits bold / Consolas / 24pt and the next reading
        /// lies (run 1 read bold=On over every run of the specimen). Clear the
        /// whole story explicitly instead of trusting the control.
        static void Normalize(RichEditTextDocument doc, string face, float size)
        {
            int n = StoryLen(doc);
            var cf = doc.GetRange(0, n).CharacterFormat;
            cf.Bold = FormatEffect.Off;
            cf.Italic = FormatEffect.Off;
            cf.Underline = UnderlineType.None;
            cf.Strikethrough = FormatEffect.Off;
            cf.Name = face;
            cf.Size = size;
            var d = doc.GetDefaultCharacterFormat();
            d.Bold = FormatEffect.Off;
            d.Italic = FormatEffect.Off;
            d.Underline = UnderlineType.None;
            d.Strikethrough = FormatEffect.Off;
            d.Name = face;
            d.Size = size;
            doc.SetDefaultCharacterFormat(d);
        }

        /// Every TextGetOptions spelling of the same story, side by side: run 1
        /// found GetText(None) carrying the final CR that AdjustCrlf drops, and
        /// a Link putting its field instruction INTO the story.
        static string AllReads(RichEditTextDocument doc)
        {
            var opts = new KeyValuePair<string, TextGetOptions>[]
            {
                new KeyValuePair<string, TextGetOptions>("None", TextGetOptions.None),
                new KeyValuePair<string, TextGetOptions>("AdjustCrlf", TextGetOptions.AdjustCrlf),
                new KeyValuePair<string, TextGetOptions>("AllowFinalEop", TextGetOptions.AllowFinalEop),
                new KeyValuePair<string, TextGetOptions>("NoHidden", TextGetOptions.NoHidden),
                new KeyValuePair<string, TextGetOptions>("AdjustCrlf|NoHidden",
                    TextGetOptions.AdjustCrlf | TextGetOptions.NoHidden),
                new KeyValuePair<string, TextGetOptions>("AdjustCrlf|AllowFinalEop",
                    TextGetOptions.AdjustCrlf | TextGetOptions.AllowFinalEop),
                new KeyValuePair<string, TextGetOptions>("UseCrlf", TextGetOptions.UseCrlf),
                new KeyValuePair<string, TextGetOptions>("UseObjectText", TextGetOptions.UseObjectText),
            };
            var b = new StringBuilder();
            foreach (var o in opts)
            {
                string t;
                try { t = Get(doc, o.Value); }
                catch (Exception ex) { t = "<threw " + ex.GetType().Name + ">"; }
                b.Append(" | ").Append(o.Key).Append('=').Append(Show(t))
                 .Append(" len=").Append(t == null ? -1 : t.Length);
            }
            return b.ToString();
        }

        // ---- launch ------------------------------------------------------

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            Log.Line("probe OnLaunched; merged dictionaries=" + Resources.MergedDictionaries.Count);
            var stack = new StackPanel { Spacing = 8, Margin = new Thickness(12) };

            pinned = new RichEditBox { Width = 520, Height = 90 };
            AutomationProperties.SetAutomationId(pinned, "pinnedProbe");
            // kaya's pins, verbatim (crates/kaya/src/winui/mod.rs pin_plain_text).
            pinned.ClipboardCopyFormat = RichEditClipboardFormat.PlainText;
            pinned.DisabledFormattingAccelerators = DisabledFormattingAccelerators.All;
            pinned.Paste += (s, a) => { a.Handled = true; };
            stack.Children.Add(pinned);

            rich = new RichEditBox { Width = 520, Height = 220 };
            AutomationProperties.SetAutomationId(rich, "richProbe");
            rich.TextChanging += (s, a) =>
                Ev("TextChanging IsContentChanging=" + a.IsContentChanging);
            rich.TextChanged += (s, a) =>
                Ev("TextChanged text=" + Show(Get(rich.Document, TextGetOptions.None)));
            rich.SelectionChanging += (s, a) =>
                Ev("SelectionChanging start=" + a.SelectionStart + " len=" + a.SelectionLength);
            rich.SelectionChanged += (s, a) =>
                Ev("SelectionChanged start=" + rich.Document.Selection.StartPosition
                   + " end=" + rich.Document.Selection.EndPosition);
            rich.TextCompositionStarted += (s, a) => Ev("TextCompositionStarted");
            rich.TextCompositionChanged += (s, a) => Ev("TextCompositionChanged");
            rich.TextCompositionEnded += (s, a) => Ev("TextCompositionEnded");
            rich.Paste += (s, a) => Ev("Paste(handled=" + a.Handled + ") [NOT cancelled]");
            stack.Children.Add(rich);

            win = new Window { Title = "kaya rich probe" };
            win.Content = stack;
            win.Activate();
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
            Log.Line("probe window activated hwnd=" + hwnd.ToString("x")
                     + " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id);
            try
            {
                File.WriteAllText(DIR + @"\pid.txt",
                    System.Diagnostics.Process.GetCurrentProcess().Id.ToString(), Encoding.ASCII);
            }
            catch (Exception ex) { Log.Line("probe pid.txt write failed " + ex.Message); }
            Drive();
        }

        // ---- M1: the final EOP -------------------------------------------

        void Eop(RichEditBox box, string label, string set)
        {
            var doc = box.Document;
            try
            {
                doc.SetText(TextSetOptions.None, set);
                string none = Get(doc, TextGetOptions.None);
                string crlf = Get(doc, TextGetOptions.AdjustCrlf);
                int story = StoryLen(doc);
                int selStory = doc.Selection.StoryLength;
                int maxEnd = doc.GetRange(0, TextConstants.MaxUnitCount).EndPosition;
                int intMaxEnd = doc.GetRange(0, int.MaxValue).EndPosition;
                Log.Line("  " + label + " set=" + Show(set) + AllReads(doc)
                         + " | StoryLength(GetRange(0,0))=" + story
                         + " Selection.StoryLength=" + selStory
                         + " | GetRange(0,MaxUnitCount).EndPosition=" + maxEnd
                         + " GetRange(0,int.MaxValue).EndPosition=" + intMaxEnd
                         + " | StoryLength-1==len(None)? " + ((story - 1) == none.Length)
                         + " | StoryLength-1==len(AdjustCrlf)? " + ((story - 1) == crlf.Length));
            }
            catch (Exception ex)
            {
                Log.Line("  " + label + " set=" + Show(set) + " THREW " + ex.GetType().Name + ": " + ex.Message);
            }
        }

        // ---- driver ------------------------------------------------------

        async void Drive()
        {
            try
            {
                await Task.Delay(1800);
                SetForegroundWindow(hwnd);
                await Task.Delay(400);
                Log.Line("MaxUnitCount=" + TextConstants.MaxUnitCount);

                // ---- M1 ------------------------------------------------------
                Log.Line("== M1 the final EOP: StoryLength against GetText, pinned vs rich ==");
                foreach (var t in new string[] { "", "abc", "abc" + CR, "abc" + CR + "def", "a\nb" })
                {
                    Eop(pinned, "PINNED", t);
                    Eop(rich, "RICH  ", t);
                }
                Log.Line("== M1b is the PINNED control still a rich control underneath? ==");
                try
                {
                    pinned.Document.SetText(TextSetOptions.None, "abc");
                    SetBold(pinned.Document, 0, 2, FormatEffect.On);
                    Log.Line("  PINNED after a programmatic Bold On over (0,2): bold(0,2)="
                             + BoldOf(pinned.Document, 0, 2) + " bold(2,3)=" + BoldOf(pinned.Document, 2, 3)
                             + " bold(0,3)=" + BoldOf(pinned.Document, 0, 3));
                    string rtf = Get(pinned.Document, TextGetOptions.FormatRtf);
                    Log.Line("  PINNED GetText(FormatRtf) length=" + rtf.Length
                             + " head=" + Show(rtf.Length > 220 ? rtf.Substring(0, 220) : rtf));
                    Log.Line("  PINNED GetText(None) after the bold=" + Show(Get(pinned.Document, TextGetOptions.None))
                             + " StoryLength=" + StoryLen(pinned.Document));
                }
                catch (Exception ex) { Log.Line("  M1b THREW " + ex); }

                // ---- M2 ------------------------------------------------------
                Log.Line("== M2 unit arithmetic ==");
                const string SAMPLE = "h\u00e9llo \ud83d\udc4b \u4e16\u754c";
                try
                {
                    var doc = rich.Document;
                    doc.SetText(TextSetOptions.None, SAMPLE);
                    string back = Get(doc, TextGetOptions.None);
                    var utf8 = Encoding.UTF8.GetBytes(SAMPLE);
                    Log.Line("  source " + Show(SAMPLE) + " utf16units=" + SAMPLE.Length
                             + " utf8bytes=" + utf8.Length + " codepoints="
                             + new System.Globalization.StringInfo(SAMPLE).LengthInTextElements
                             + " (text elements)");
                    Log.Line("  GetText(None)=" + Show(back) + " len=" + back.Length
                             + " codes=" + Utf16Codes(back)
                             + " StoryLength=" + StoryLen(doc)
                             + " roundTripEqual=" + (back == SAMPLE));
                    // Per-unit: every single-unit range, its text and its endpoints
                    // back, which is where a clamp or a surrogate snap would show.
                    int story = StoryLen(doc);
                    int byteOff = 0;
                    for (int i = 0; i < story; i++)
                    {
                        var r = doc.GetRange(i, i + 1);
                        string t = r.Text;
                        string src = i < SAMPLE.Length ? SAMPLE.Substring(i, 1) : "<past source>";
                        int thisBytes = i < SAMPLE.Length
                            ? Encoding.UTF8.GetByteCount(SAMPLE.Substring(i, 1)) : 0;
                        Log.Line("    cp " + i + " -> range(" + r.StartPosition + "," + r.EndPosition
                                 + ") len=" + r.Length + " text=" + Show(t) + " codes=" + Utf16Codes(t)
                                 + " | source unit " + Show(src) + " codes=" + Utf16Codes(src)
                                 + " utf8ByteOffsetOfUnit=" + byteOff);
                        // A lone surrogate's UTF-8 count is not the pair's half, so the
                        // running offset is taken from the WHOLE source instead.
                        byteOff = i + 1 <= SAMPLE.Length
                            ? Encoding.UTF8.GetByteCount(SAMPLE.Substring(0, Math.Min(i + 1, SAMPLE.Length)))
                            : byteOff;
                    }
                    // The split-pair question, both directions.
                    int hi = SAMPLE.IndexOf('\ud83d');
                    var split = doc.GetRange(hi, hi + 1);
                    Log.Line("  split high surrogate at cp " + hi + ": range(" + split.StartPosition
                             + "," + split.EndPosition + ") text=" + Show(split.Text)
                             + " codes=" + Utf16Codes(split.Text));
                    var pair = doc.GetRange(hi, hi + 2);
                    Log.Line("  whole pair (" + hi + "," + (hi + 2) + "): text=" + Show(pair.Text)
                             + " codes=" + Utf16Codes(pair.Text));
                    var over = doc.GetRange(-5, 9999);
                    Log.Line("  GetRange(-5,9999) clamps to (" + over.StartPosition + ","
                             + over.EndPosition + ") len=" + over.Length);
                    // GetRange SNAPPED the split pair outward in run 1, which
                    // docs/ranges-units.md says Windows does NOT do. Ask the two
                    // other doors as well before believing either.
                    var sr = doc.GetRange(0, 0);
                    sr.SetRange(hi, hi + 1);
                    Log.Line("  SetRange(" + hi + "," + (hi + 1) + ") -> (" + sr.StartPosition
                             + "," + sr.EndPosition + ") text=" + Show(sr.Text));
                    var sr2 = doc.GetRange(0, 0);
                    sr2.SetRange(hi + 1, hi + 2);
                    Log.Line("  SetRange(" + (hi + 1) + "," + (hi + 2) + ") -> (" + sr2.StartPosition
                             + "," + sr2.EndPosition + ") text=" + Show(sr2.Text));
                    doc.Selection.SetRange(hi, hi + 1);
                    await Task.Delay(120);
                    Log.Line("  Selection.SetRange(" + hi + "," + (hi + 1) + ") -> ("
                             + doc.Selection.StartPosition + "," + doc.Selection.EndPosition
                             + ") text=" + Show(doc.Selection.Text));
                    var half = doc.GetRange(0, hi + 1);
                    Log.Line("  GetRange(0," + (hi + 1) + ") [end splits the pair] -> ("
                             + half.StartPosition + "," + half.EndPosition + ") text="
                             + Show(half.Text));
                }
                catch (Exception ex) { Log.Line("  M2 THREW " + ex); }

                // ---- M3 ------------------------------------------------------
                Log.Line("== M3 undo suppression (R6) ==");
                try
                {
                    var doc = rich.Document;
                    doc.SetText(TextSetOptions.None, "seed");
                    rich.Focus(FocusState.Programmatic);
                    await Task.Delay(250);
                    SendVk(VK_END);
                    await Task.Delay(120);

                    Log.Line("  -- M3a UndoLimit = 0, then typed text and Ctrl+Z --");
                    doc.UndoLimit = 0;
                    Log.Line("  UndoLimit read back = " + doc.UndoLimit
                             + " CanUndo=" + doc.CanUndo() + " CanRedo=" + doc.CanRedo());
                    foreach (char c in "XYZ") { SendChar(c); await Task.Delay(80); }
                    await Task.Delay(300);
                    string afterType = Get(doc, TextGetOptions.None);
                    Log.Line("  after typing: " + Show(afterType) + " CanUndo=" + doc.CanUndo());
                    SendCtrl(VK_Z);
                    await Task.Delay(400);
                    string afterUndo = Get(doc, TextGetOptions.None);
                    Log.Line("  after Ctrl+Z: " + Show(afterUndo)
                             + " unchanged=" + (afterUndo == afterType));
                    doc.Undo();
                    await Task.Delay(200);
                    Log.Line("  after a PROGRAMMATIC doc.Undo(): text="
                             + Show(Get(doc, TextGetOptions.None)) + " CanUndo=" + doc.CanUndo());

                    Log.Line("  -- M3b UndoLimit = 0 and a FORMAT change --");
                    doc.SetText(TextSetOptions.None, "formatme");
                    doc.UndoLimit = 0;
                    doc.Selection.SetRange(0, 6);
                    var selCf = doc.Selection.CharacterFormat;
                    selCf.Bold = FormatEffect.On;
                    doc.Selection.CharacterFormat = selCf;
                    await Task.Delay(200);
                    Log.Line("  after Selection.CharacterFormat.Bold=On: bold(0,6)="
                             + BoldOf(doc, 0, 6) + " CanUndo=" + doc.CanUndo());
                    SendCtrl(VK_Z);
                    await Task.Delay(400);
                    Log.Line("  after Ctrl+Z: bold(0,6)=" + BoldOf(doc, 0, 6)
                             + " text=" + Show(Get(doc, TextGetOptions.None))
                             + " CanUndo=" + doc.CanUndo());

                    Log.Line("  -- M3c can UndoLimit be raised again at runtime? --");
                    doc.UndoLimit = 100;
                    Log.Line("  UndoLimit read back = " + doc.UndoLimit);
                    doc.SetText(TextSetOptions.None, "base");
                    rich.Focus(FocusState.Programmatic);
                    await Task.Delay(200);
                    SendVk(VK_END);
                    await Task.Delay(120);
                    foreach (char c in "QRS") { SendChar(c); await Task.Delay(80); }
                    await Task.Delay(300);
                    string t2 = Get(doc, TextGetOptions.None);
                    Log.Line("  after typing with the limit raised: " + Show(t2)
                             + " CanUndo=" + doc.CanUndo());
                    SendCtrl(VK_Z);
                    await Task.Delay(400);
                    string t3 = Get(doc, TextGetOptions.None);
                    Log.Line("  after Ctrl+Z: " + Show(t3) + " undoDidSomething=" + (t3 != t2));

                    Log.Line("  -- M3c2 does UndoLimit = 0 CLEAR a stack that already has entries? --");
                    Log.Line("  CanUndo before the limit drops = " + doc.CanUndo());
                    doc.UndoLimit = 0;
                    Log.Line("  CanUndo after UndoLimit=0 = " + doc.CanUndo()
                             + "; raising it back to 100");
                    doc.UndoLimit = 100;
                    Log.Line("  CanUndo after raising it again = " + doc.CanUndo());

                    Log.Line("  -- M3d0 is a FORMAT change undoable AT ALL (limit 100)? --");
                    doc.UndoLimit = 100;
                    doc.SetText(TextSetOptions.None, "group ");
                    Normalize(doc, "Segoe UI Variable", 14);
                    await Task.Delay(200);
                    Log.Line("  clean start: text=" + Show(Get(doc, TextGetOptions.None))
                             + " bold(0,5)=" + BoldOf(doc, 0, 5) + " CanUndo=" + doc.CanUndo());
                    SetBold(doc, 0, 5, FormatEffect.On);
                    await Task.Delay(250);
                    Log.Line("  after Bold On: bold(0,5)=" + BoldOf(doc, 0, 5)
                             + " CanUndo=" + doc.CanUndo());
                    doc.Undo();
                    await Task.Delay(300);
                    Log.Line("  after doc.Undo(): bold(0,5)=" + BoldOf(doc, 0, 5)
                             + " text=" + Show(Get(doc, TextGetOptions.None))
                             + " CanUndo=" + doc.CanUndo());

                    Log.Line("  -- M3d BeginUndoGroup around an insert AND a format --");
                    doc.SetText(TextSetOptions.None, "group ");
                    Normalize(doc, "Segoe UI Variable", 14);
                    await Task.Delay(200);
                    Log.Line("  before the group: " + Show(Get(doc, TextGetOptions.None))
                             + " bold(0,5)=" + BoldOf(doc, 0, 5) + " CanUndo=" + doc.CanUndo());
                    doc.BeginUndoGroup();
                    doc.Selection.SetRange(6, 6);
                    doc.Selection.TypeText("INS");
                    SetBold(doc, 0, 5, FormatEffect.On);
                    doc.EndUndoGroup();
                    await Task.Delay(250);
                    Log.Line("  after the group: " + Show(Get(doc, TextGetOptions.None))
                             + " bold(0,5)=" + BoldOf(doc, 0, 5) + " CanUndo=" + doc.CanUndo());
                    doc.Undo();
                    await Task.Delay(300);
                    Log.Line("  after ONE doc.Undo(): text="
                             + Show(Get(doc, TextGetOptions.None)) + " bold(0,5)=" + BoldOf(doc, 0, 5)
                             + " CanUndo=" + doc.CanUndo());
                    doc.Undo();
                    await Task.Delay(300);
                    Log.Line("  after a SECOND doc.Undo(): text="
                             + Show(Get(doc, TextGetOptions.None)) + " bold(0,5)=" + BoldOf(doc, 0, 5));

                    Log.Line("  -- M3e UndoLimit=0 against the control's OWN Ctrl+B accelerator --");
                    doc.SetText(TextSetOptions.None, "accel");
                    doc.UndoLimit = 0;
                    rich.Focus(FocusState.Programmatic);
                    await Task.Delay(200);
                    Normalize(doc, "Segoe UI Variable", 14);
                    doc.Selection.SetRange(0, 5);
                    await Task.Delay(150);
                    Log.Line("  BEFORE Ctrl+B: bold(0,5)=" + BoldOf(doc, 0, 5)
                             + " focusIsRich=" + (FocusManager.GetFocusedElement(win.Content.XamlRoot) == rich)
                             + " DisabledFormattingAccelerators=" + rich.DisabledFormattingAccelerators);
                    SendCtrl(VK_B);
                    await Task.Delay(350);
                    Log.Line("  after a REAL Ctrl+B on the unpinned control: bold(0,5)="
                             + BoldOf(doc, 0, 5) + " CanUndo=" + doc.CanUndo());
                    SendCtrl(VK_Z);
                    await Task.Delay(400);
                    Log.Line("  after Ctrl+Z: bold(0,5)=" + BoldOf(doc, 0, 5));
                }
                catch (Exception ex) { Log.Line("  M3 THREW " + ex); }

                // ---- M4 ------------------------------------------------------
                Log.Line("== M4 edit reporting (R4) ==");
                try
                {
                    var doc = rich.Document;
                    doc.UndoLimit = 100;
                    doc.SetText(TextSetOptions.None, "abc");
                    rich.Focus(FocusState.Programmatic);
                    await Task.Delay(300);
                    SendVk(VK_END);
                    await Task.Delay(200);

                    TakeEvents();
                    Log.Line("  -- M4a ONE keystroke 'x' at the end --");
                    SendChar('x');
                    await Task.Delay(500);
                    Log.Line("  events: " + TakeEvents());
                    Log.Line("  text now " + Show(Get(doc, TextGetOptions.None)));

                    Log.Line("  -- M4b a Ctrl+V paste of plain text \"PQ\" --");
                    SetClipboardText("PQ");
                    await Task.Delay(200);
                    TakeEvents();
                    SendCtrl(VK_V);
                    await Task.Delay(700);
                    Log.Line("  events: " + TakeEvents());
                    Log.Line("  text now " + Show(Get(doc, TextGetOptions.None)));

                    Log.Line("  -- M4c a PROGRAMMATIC SetText --");
                    TakeEvents();
                    doc.SetText(TextSetOptions.None, "programmatic");
                    await Task.Delay(500);
                    Log.Line("  events: " + TakeEvents());

                    Log.Line("  -- M4d an ATTRIBUTE-ONLY change, ONE apply (the live object) --");
                    TakeEvents();
                    SetBold(doc, 0, 4, FormatEffect.On);
                    await Task.Delay(600);
                    Log.Line("  events: " + TakeEvents());
                    Log.Line("  bold(0,4)=" + BoldOf(doc, 0, 4));

                    Log.Line("  -- M4d2 the SAME change through the assign-back route --");
                    TakeEvents();
                    SetBoldAssignBack(doc, 4, 8, FormatEffect.On);
                    await Task.Delay(600);
                    Log.Line("  events: " + TakeEvents());
                    Log.Line("  bold(4,8)=" + BoldOf(doc, 4, 8));

                    Log.Line("  -- M4d3 a PARAGRAPH-format change (alignment) --");
                    TakeEvents();
                    doc.GetRange(0, 4).ParagraphFormat.Alignment = ParagraphAlignment.Center;
                    await Task.Delay(600);
                    Log.Line("  events: " + TakeEvents());

                    Log.Line("  -- M4d4 a format change that changes NOTHING (Bold On again) --");
                    TakeEvents();
                    SetBold(doc, 0, 4, FormatEffect.On);
                    await Task.Delay(600);
                    Log.Line("  events: " + TakeEvents());
                    doc.GetRange(0, 4).ParagraphFormat.Alignment = ParagraphAlignment.Left;
                    SetBold(doc, 0, 8, FormatEffect.Off);

                    Log.Line("  -- M4e a programmatic SELECTION move, nothing else --");
                    await Task.Delay(600);
                    TakeEvents();
                    doc.Selection.SetRange(2, 5);
                    await Task.Delay(400);
                    Log.Line("  events: " + TakeEvents());

                    Log.Line("  -- M4f a real BACKSPACE --");
                    TakeEvents();
                    doc.Selection.SetRange(12, 12);
                    await Task.Delay(200);
                    TakeEvents();
                    SendVk(0x08);
                    await Task.Delay(500);
                    Log.Line("  events: " + TakeEvents());
                    Log.Line("  text now " + Show(Get(doc, TextGetOptions.None)));
                }
                catch (Exception ex) { Log.Line("  M4 THREW " + ex); }

                // ---- M5 ------------------------------------------------------
                Log.Line("== M5 read-back: the tri-state, and Link ==");
                try
                {
                    var doc = rich.Document;
                    doc.SetText(TextSetOptions.None, "abcdefghij");
                    Normalize(doc, "Segoe UI Variable", 14);
                    await Task.Delay(150);
                    Log.Line("  after Normalize: bold(0,10)=" + BoldOf(doc, 0, 10)
                             + " name(0,10)=" + Show(doc.GetRange(0, 10).CharacterFormat.Name)
                             + " size(0,10)=" + doc.GetRange(0, 10).CharacterFormat.Size);
                    SetBold(doc, 0, 5, FormatEffect.On);
                    await Task.Delay(200);
                    Log.Line("  bold over (0,5) only:");
                    Log.Line("    bold(0,5)  [fully bold]  = " + BoldOf(doc, 0, 5));
                    Log.Line("    bold(5,10) [fully plain] = " + BoldOf(doc, 5, 10));
                    Log.Line("    bold(0,10) [mixed]       = " + BoldOf(doc, 0, 10));
                    Log.Line("    bold(4,6)  [straddling]  = " + BoldOf(doc, 4, 6));
                    Log.Line("    bold(0,0)  [collapsed, bold half]  = " + BoldOf(doc, 0, 0));
                    Log.Line("    bold(7,7)  [collapsed, plain half] = " + BoldOf(doc, 7, 7));
                    Log.Line("    bold(5,5)  [collapsed, on the seam] = " + BoldOf(doc, 5, 5));
                    SetItalic(doc, 2, 8, FormatEffect.On);
                    await Task.Delay(150);
                    var r05 = doc.GetRange(0, 5);
                    var r510 = doc.GetRange(5, 10);
                    var r010 = doc.GetRange(0, 10);
                    Log.Line("  with italic over (2,8) as well:");
                    Log.Line("    italic(0,5)=" + Effect(r05.CharacterFormat.Italic)
                             + " italic(2,8)=" + Effect(doc.GetRange(2, 8).CharacterFormat.Italic)
                             + " italic(0,10)=" + Effect(r010.CharacterFormat.Italic));
                    Log.Line("    underline(0,10)=" + r010.CharacterFormat.Underline
                             + " strike(0,10)=" + Effect(r010.CharacterFormat.Strikethrough)
                             + " weight(0,5)=" + r05.CharacterFormat.Weight
                             + " weight(5,10)=" + r510.CharacterFormat.Weight
                             + " weight(0,10)=" + r010.CharacterFormat.Weight);
                    // The non-FormatEffect properties: is there an Undefined
                    // spelling for a mixed font name and a mixed size?
                    doc.GetRange(0, 5).CharacterFormat.Name = "Consolas";
                    doc.GetRange(5, 10).CharacterFormat.Name = "Courier New";
                    doc.GetRange(0, 5).CharacterFormat.Size = 12;
                    doc.GetRange(5, 10).CharacterFormat.Size = 24;
                    var u0 = doc.GetRange(0, 5).CharacterFormat;
                    u0.Underline = UnderlineType.Single;
                    await Task.Delay(150);
                    Log.Line("    mixed NAME and SIZE: name(0,5)=" + Show(doc.GetRange(0, 5).CharacterFormat.Name)
                             + " name(5,10)=" + Show(doc.GetRange(5, 10).CharacterFormat.Name)
                             + " name(0,10)=" + Show(doc.GetRange(0, 10).CharacterFormat.Name)
                             + " size(0,5)=" + doc.GetRange(0, 5).CharacterFormat.Size
                             + " size(5,10)=" + doc.GetRange(5, 10).CharacterFormat.Size
                             + " size(0,10)=" + doc.GetRange(0, 10).CharacterFormat.Size
                             + " weight(0,10)=" + doc.GetRange(0, 10).CharacterFormat.Weight
                             + " underline(0,5)=" + doc.GetRange(0, 5).CharacterFormat.Underline
                             + " underline(0,10)=" + doc.GetRange(0, 10).CharacterFormat.Underline);
                    Log.Line("    TextConstants.UndefinedFloatValue=" + TextConstants.UndefinedFloatValue
                             + " UndefinedInt32Value=" + TextConstants.UndefinedInt32Value);

                    Log.Line("  -- M5b ITextRange.Link: run 1 found the URL going INTO the story --");
                    doc.SetText(TextSetOptions.None, "see example here");
                    Normalize(doc, "Segoe UI Variable", 14);
                    await Task.Delay(150);
                    Log.Line("    before the link: StoryLength=" + StoryLen(doc) + AllReads(doc));
                    int a = 4;
                    var lr = doc.GetRange(a, a + 7);
                    Log.Line("    the range to link: (" + lr.StartPosition + "," + lr.EndPosition
                             + ") text=" + Show(lr.Text));
                    try
                    {
                        lr.Link = "\"https://example.com/\"";
                        await Task.Delay(250);
                        Log.Line("    AFTER Link=: StoryLength=" + StoryLen(doc) + AllReads(doc));
                        Log.Line("    the range now: (" + lr.StartPosition + "," + lr.EndPosition
                                 + ") text=" + Show(lr.Text) + " Link=" + Show(lr.Link)
                                 + " LinkType=" + lr.CharacterFormat.LinkType);
                        // WHICH characters are hidden - the whole offset question.
                        int n = StoryLen(doc);
                        var hid = new StringBuilder();
                        for (int i = 0; i < n; i++)
                        {
                            var c = doc.GetRange(i, i + 1);
                            hid.Append("\r\n      cp ").Append(i).Append(' ')
                               .Append(Show(c.Text))
                               .Append(" hidden=").Append(Effect(c.CharacterFormat.Hidden))
                               .Append(" linkType=").Append(c.CharacterFormat.LinkType)
                               .Append(" link=").Append(Show(c.Link));
                        }
                        Log.Line("    per-character:" + hid.ToString());
                        var found = doc.GetRange(0, 0);
                        found.SetRange(0, StoryLen(doc));
                        Log.Line("    selection over the whole story: text=" + Show(found.Text));
                        Log.Line("    Link removal: setting Link=\"\" ...");
                        lr.Link = "";
                        await Task.Delay(250);
                        Log.Line("    after removal: StoryLength=" + StoryLen(doc) + AllReads(doc));
                    }
                    catch (Exception ex) { Log.Line("    QUOTED form THREW " + ex.GetType().Name + ": " + ex.Message); }
                    try
                    {
                        var lr2 = doc.GetRange(0, 3);
                        lr2.Link = "https://plain.example/";
                    }
                    catch (Exception ex) { Log.Line("    BARE form (no quotes) THREW " + ex.GetType().Name + ": " + ex.Message); }
                    Log.Line("    a NON-link range: Link=" + Show(doc.GetRange(0, 3).Link)
                             + " LinkType=" + doc.GetRange(0, 3).CharacterFormat.LinkType);
                    // And the other direction: can a link be made without the
                    // field, by RTF, so the guest-visible bytes stay put?
                    try
                    {
                        doc.SetText(TextSetOptions.None, "see example here");
                        Normalize(doc, "Segoe UI Variable", 14);
                        string rtfIn = "{\\rtf1\\ansi see {\\field{\\*\\fldinst{HYPERLINK \"https://example.com/\"}}"
                                     + "{\\fldrslt{\\ul\\cf2 example}}} here\\par}";
                        doc.SetText(TextSetOptions.FormatRtf, rtfIn);
                        await Task.Delay(250);
                        Log.Line("    RTF-set link: StoryLength=" + StoryLen(doc) + AllReads(doc));
                        int nn = StoryLen(doc);
                        var hid2 = new StringBuilder();
                        for (int i = 0; i < nn; i++)
                        {
                            var c = doc.GetRange(i, i + 1);
                            hid2.Append(' ').Append(i).Append(Show(c.Text))
                                .Append("/h=").Append(((int)c.CharacterFormat.Hidden))
                                .Append("/lt=").Append(c.CharacterFormat.LinkType);
                        }
                        Log.Line("    per-character:" + hid2.ToString());
                    }
                    catch (Exception ex) { Log.Line("    RTF-set link THREW " + ex.GetType().Name + ": " + ex.Message); }
                }
                catch (Exception ex) { Log.Line("  M5 THREW " + ex); }

                Log.Line("== M6 the UIA specimen ==");
                try
                {
                    var doc = rich.Document;
                    string spec = "plain run" + CR + "bold run" + CR + "italic run" + CR
                                + "under run" + CR + "strike run" + CR + "mono run" + CR
                                + "link run" + CR + "heading run";
                    doc.SetText(TextSetOptions.None, spec);
                    Normalize(doc, "Segoe UI Variable", 14);
                    await Task.Delay(200);

                    // EVERY offset is recomputed against the CURRENT text: run 1
                    // captured them once and the link's field instruction shifted
                    // everything after it, so five runs were formatted at the
                    // wrong place.
                    Func<string, int> at = w => Get(doc, TextGetOptions.None).IndexOf(w);

                    int i = at("bold run");
                    SetBold(doc, i, i + 8, FormatEffect.On);
                    i = at("italic run");
                    SetItalic(doc, i, i + 10, FormatEffect.On);
                    i = at("under run");
                    doc.GetRange(i, i + 9).CharacterFormat.Underline = UnderlineType.Single;
                    i = at("strike run");
                    doc.GetRange(i, i + 10).CharacterFormat.Strikethrough = FormatEffect.On;
                    i = at("mono run");
                    doc.GetRange(i, i + 8).CharacterFormat.Name = "Consolas";
                    i = at("heading run");
                    var hf = doc.GetRange(i, i + 11).CharacterFormat;
                    hf.Size = 24;
                    hf.Bold = FormatEffect.On;
                    // THE LINK LAST, because setting one inserts its field
                    // instruction and moves every offset after it.
                    i = at("link run");
                    doc.GetRange(i, i + 8).Link = "\"https://example.com/kaya\"";
                    await Task.Delay(300);

                    Log.Line("  specimen StoryLength=" + StoryLen(doc) + AllReads(doc));
                    foreach (var w in new string[] { "plain run", "bold run", "italic run", "under run",
                                                     "strike run", "mono run", "link run", "heading run" })
                    {
                        int k = at(w);
                        var rr = doc.GetRange(k, k + w.Length);
                        Log.Line("  " + w + " cp(" + k + "," + (k + w.Length) + ") bold="
                                 + Effect(rr.CharacterFormat.Bold)
                                 + " italic=" + Effect(rr.CharacterFormat.Italic)
                                 + " underline=" + rr.CharacterFormat.Underline
                                 + " strike=" + Effect(rr.CharacterFormat.Strikethrough)
                                 + " name=" + Show(rr.CharacterFormat.Name)
                                 + " size=" + rr.CharacterFormat.Size
                                 + " weight=" + rr.CharacterFormat.Weight
                                 + " hidden=" + Effect(rr.CharacterFormat.Hidden)
                                 + " link=" + Show(rr.Link)
                                 + " linkType=" + rr.CharacterFormat.LinkType);
                    }
                    Log.Line("== M7 the PROVIDER side, by NUMERIC attribute id ==");
                    Log.Line("  (the managed UIA client has no identifier for Link/StyleId/StyleName,"
                             + " so those ids are asked here, in process, through ITextRangeProvider)");
                    try
                    {
                        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(rich);
                        var prov = peer == null ? null : peer.GetPattern(PatternInterface.Text) as ITextProvider;
                        if (prov == null) Log.Line("  no ITextProvider on the RichEditBox peer");
                        else
                        {
                            var dr = prov.DocumentRange;
                            Log.Line("  provider DocumentRange.GetText(-1)=" + Show(dr.GetText(-1)));
                            int[] ids = { 40005, 40006, 40007, 40013, 40014, 40026, 40030,
                                          40033, 40034, 40035, 40031, 40002, 40009 };
                            string[] nm = { "FontName", "FontSize", "FontWeight", "IsHidden", "IsItalic",
                                            "StrikethroughStyle", "UnderlineStyle", "StyleName", "StyleId",
                                            "Link", "AnnotationTypes", "BulletStyle", "HorizontalTextAlignment" };
                            foreach (var w in new string[] { "plain run", "bold run", "italic run", "under run",
                                                             "strike run", "mono run", "link run", "heading run" })
                            {
                                var rr = dr.FindText(w, false, true);
                                if (rr == null) { Log.Line("  " + w + ": provider FindText found nothing"); continue; }
                                var sb = new StringBuilder("  " + w + " [" + Show(rr.GetText(-1)) + "]");
                                for (int k = 0; k < ids.Length; k++)
                                {
                                    object v;
                                    try { v = rr.GetAttributeValue(ids[k]); }
                                    catch (Exception ex) { v = "<threw " + ex.GetType().Name + ">"; }
                                    sb.Append(' ').Append(nm[k]).Append('=')
                                      .Append(v == null ? "<null>" : v.ToString());
                                }
                                Log.Line(sb.ToString());
                                try
                                {
                                    var kids = rr.GetChildren();
                                    Log.Line("      provider range children: "
                                             + (kids == null ? "<null>" : kids.Length.ToString()));
                                }
                                catch (Exception ex) { Log.Line("      GetChildren THREW " + ex.GetType().Name); }
                            }
                        }
                    }
                    catch (Exception ex) { Log.Line("  M7 THREW " + ex); }

                    doc.Selection.SetRange(0, 0);
                    await Task.Delay(200);
                    await Shot(rich, DIR + @"\specimen.bmp");
                    File.WriteAllText(DIR + @"\ready.txt", "ready", Encoding.ASCII);
                    Log.Line("READY-FOR-UIA");
                }
                catch (Exception ex) { Log.Line("  M6 THREW " + ex); }

                // Stay alive, pumping, until uia.ps1 says it is done.
                for (int i = 0; i < 240; i++)
                {
                    if (File.Exists(DIR + @"\uia_done.txt")) { Log.Line("uia_done seen"); break; }
                    await Task.Delay(1000);
                }
            }
            catch (Exception ex)
            {
                Log.Line("probe Drive THREW " + ex);
            }
            Log.Line("PROBEDONE");
            Environment.Exit(0);
        }

        /// A 32-bit BMP of one element, so the link's rendering is a picture and
        /// not a claim. RenderTargetBitmap hands back BGRA8; the header is
        /// written by hand to avoid a WinRT encoder and its stream interop.
        async Task Shot(FrameworkElement el, string path)
        {
            try
            {
                var rtb = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
                await rtb.RenderAsync(el);
                var buf = await rtb.GetPixelsAsync();
                var px = new byte[buf.Length];
                Windows.Storage.Streams.DataReader.FromBuffer(buf).ReadBytes(px);
                int w = rtb.PixelWidth, h = rtb.PixelHeight;
                int stride = w * 4;
                using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
                using (var bw = new BinaryWriter(fs))
                {
                    bw.Write((ushort)0x4d42);
                    bw.Write(54 + px.Length);
                    bw.Write(0); bw.Write(54);
                    bw.Write(40); bw.Write(w); bw.Write(h);
                    bw.Write((ushort)1); bw.Write((ushort)32);
                    bw.Write(0); bw.Write(px.Length);
                    bw.Write(2835); bw.Write(2835); bw.Write(0); bw.Write(0);
                    for (int y = h - 1; y >= 0; y--) bw.Write(px, y * stride, stride);
                }
                Log.Line("  shot " + path + " " + w + "x" + h);
            }
            catch (Exception ex) { Log.Line("  shot THREW " + ex.GetType().Name + ": " + ex.Message); }
        }
    }
}
