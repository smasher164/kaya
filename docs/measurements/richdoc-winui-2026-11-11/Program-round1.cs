// The rich document probe (docs/rich-document-plan.md §9 step 0, the WinUI row):
//   L   TOM list paragraphs: do ListType/ListStart/ListLevelIndex move cp offsets
//       or the AdjustCrlf text, and do the numbers appear only with IncludeNumbering;
//       which marker glyphs each MarkerType draws, per level; how ListStart numbers.
//   T   a run's ForegroundColor across an app theme switch (microsoft-ui-xaml #6908).
//   K   which keys PreviewKeyDown sees on a RichEditBox (Tab, Shift+Tab, Back, Return),
//       and what the control does with an unhandled Tab.
//   C   whether ITextRange.Copy and Ctrl+C raise CopyingToClipboard.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.UI;

namespace KayaDocProbe
{
    public static class Log
    {
        static readonly object Gate = new object();
        public static string Path = @"C:\kaya\doc-probe\log.txt";
        public static void Line(string s)
        {
            lock (Gate)
            {
                var stamp = DateTime.Now.ToString("HH:mm:ss.fff");
                try { File.AppendAllText(Path, stamp + " " + s + "\r\n", Encoding.UTF8); } catch { }
            }
        }
    }

    public static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Line("UNHANDLED " + e.ExceptionObject);
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start((p) =>
            {
                var q = DispatcherQueue.GetForCurrentThread();
                System.Threading.SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(q));
                new ProbeApp();
            });
        }
    }

    public partial class ProbeApp : Application
    {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] static extern int SetForegroundWindow(IntPtr hwnd);
        const uint KEYUP = 0x2;
        const string DIR = @"C:\kaya\doc-probe";

        Window win;
        Grid root;
        RichEditBox box;
        IntPtr hwnd;

        public ProbeApp()
        {
            InitializeComponent();
            UnhandledException += (s, e) => { Log.Line("XAML UnhandledException: " + e.Message); e.Handled = true; };
        }

        static string Show(string s)
        {
            if (s == null) return "<null>";
            var b = new StringBuilder("\"");
            foreach (char c in s)
            {
                if (c == '\r') b.Append("\\r");
                else if (c == '\n') b.Append("\\n");
                else if (c == '\t') b.Append("\\t");
                else if (c < 0x20 || c > 0x7e) b.Append("\\u").Append(((int)c).ToString("x4"));
                else b.Append(c);
            }
            return b.Append('"').ToString();
        }

        static string Get(RichEditTextDocument doc, TextGetOptions o)
        {
            doc.GetText(o, out string t);
            return t;
        }

        static int Story(RichEditTextDocument doc) => doc.GetRange(0, 0).StoryLength;

        void Reads(string label)
        {
            var doc = box.Document;
            Log.Line("  " + label + " StoryLength=" + Story(doc)
                + " AdjustCrlf|NoHidden=" + Show(Get(doc, TextGetOptions.AdjustCrlf | TextGetOptions.NoHidden))
                + " AdjustCrlf|NoHidden|IncludeNumbering=" + Show(Get(doc, TextGetOptions.AdjustCrlf | TextGetOptions.NoHidden | TextGetOptions.IncludeNumbering)));
        }

        static readonly string Seed = "Apples\rGreen ones\rBread\rWash\rSlice\rMilk\rEggs\rTail";

        int[] Starts()
        {
            var t = Get(box.Document, TextGetOptions.AdjustCrlf | TextGetOptions.NoHidden);
            var s = new List<int> { 0 };
            for (int i = 0; i < t.Length; i++) if (t[i] == '\r' || t[i] == '\n') s.Add(i + 1);
            return s.ToArray();
        }

        ITextRange Para(int n)
        {
            var st = Starts();
            int a = st[n];
            int b = n + 1 < st.Length ? st[n + 1] - 1 : Story(box.Document) - 1;
            return box.Document.GetRange(a, b);
        }

        void SetList(int n, MarkerType type, int level, int start, MarkerStyle style)
        {
            var r = Para(n);
            var p = r.ParagraphFormat;
            p.ListType = type;
            if (level > 0) p.ListLevelIndex = level;
            if (start > 0) p.ListStart = start;
            if (style != MarkerStyle.Undefined) p.ListStyle = style;
            r.ParagraphFormat = p;
        }

        void Paras(string label)
        {
            var st = Starts();
            var t = Get(box.Document, TextGetOptions.AdjustCrlf | TextGetOptions.NoHidden);
            for (int n = 0; n < st.Length; n++)
            {
                var r = Para(n);
                var p = r.ParagraphFormat;
                var first = box.Document.GetRange(st[n], st[n] + 1);
                first.GetRect(PointOptions.ClientCoordinates | PointOptions.AllowOffClient, out Windows.Foundation.Rect rect, out int hit);
                string ch;
                first.GetText(TextGetOptions.None, out ch);
                string numbered;
                r.GetText(TextGetOptions.IncludeNumbering, out numbered);
                Log.Line("  " + label + " para " + n + " start=" + st[n] + " firstchar=" + Show(ch)
                    + " ListType=" + p.ListType + "(" + (int)p.ListType + ") ListStart=" + p.ListStart + " ListLevelIndex=" + p.ListLevelIndex
                    + " ListStyle=" + p.ListStyle + " ListTab=" + p.ListTab + " Left=" + p.LeftIndent + " First=" + p.FirstLineIndent
                    + " rect.X=" + rect.X.ToString("0.0") + " rect.Y=" + rect.Y.ToString("0.0")
                    + " range.IncludeNumbering=" + Show(numbered));
            }
        }

        void Caret(string label, int at)
        {
            box.Document.Selection.SetRange(at, at);
            var s = box.Document.Selection;
            string after;
            box.Document.GetRange(at, at + 1).GetText(TextGetOptions.None, out after);
            Log.Line("  " + label + " SetRange(" + at + ") -> Start=" + s.StartPosition + " End=" + s.EndPosition + " char-at=" + Show(after));
        }

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            root = new Grid { Padding = new Thickness(12) };
            box = new RichEditBox { Width = 520, Height = 420, AcceptsReturn = true };
            box.ClipboardCopyFormat = RichEditClipboardFormat.PlainText;
            box.DisabledFormattingAccelerators = DisabledFormattingAccelerators.All;
            box.Paste += (s, a) => { a.Handled = true; };
            box.PreviewKeyDown += (s, a) => Log.Line("  PreviewKeyDown " + a.Key + " handled=" + a.Handled);
            box.CopyingToClipboard += (s, a) => Log.Line("  CopyingToClipboard raised");
            box.CuttingToClipboard += (s, a) => Log.Line("  CuttingToClipboard raised");
            box.ActualThemeChanged += (s, a) => Log.Line("  ActualThemeChanged -> " + box.ActualTheme);
            root.Children.Add(box);
            win = new Window { Title = "kaya doc probe" };
            win.Content = root;
            win.Activate();
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
            Drive();
        }

        async Task Key(byte vk, bool shift = false, bool ctrl = false)
        {
            SetForegroundWindow(hwnd);
            await Task.Delay(100);
            if (ctrl) keybd_event(0x11, 0, 0, UIntPtr.Zero);
            if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
            if (shift) keybd_event(0x10, 0, KEYUP, UIntPtr.Zero);
            if (ctrl) keybd_event(0x11, 0, KEYUP, UIntPtr.Zero);
            await Task.Delay(400);
        }

        async void Drive()
        {
            try
            {
                await Task.Delay(2000);
                SetForegroundWindow(hwnd);
                await Task.Delay(300);
                var doc = box.Document;
                Log.Line("== L1 plain seed ==");
                doc.SetText(TextSetOptions.None, Seed);
                Reads("plain");
                Paras("plain");

                Log.Line("== L2 bullets on paras 0..2 (level 1, 2, 1), numbered (Arabic, Period) on 3..4, rest plain ==");
                SetList(0, MarkerType.Bullet, 1, 0, MarkerStyle.Undefined);
                SetList(1, MarkerType.Bullet, 2, 0, MarkerStyle.Undefined);
                SetList(2, MarkerType.Bullet, 1, 0, MarkerStyle.Undefined);
                SetList(3, MarkerType.Arabic, 1, 1, MarkerStyle.Period);
                SetList(4, MarkerType.Arabic, 1, 0, MarkerStyle.Period);
                Reads("listed");
                Paras("listed");
                foreach (var at in new int[] { 0, 7, 18, 24, 29 }) Caret("listed", at);
                await Task.Delay(400);
                await Shot(DIR + @"\l2.bmp");

                Log.Line("== L3 marker types per level: Bullet at levels 1..3, LowercaseEnglishLetter, LowercaseRoman, UnicodeSequence 25E6 / 25AA / 2610 / 2611 ==");
                doc.SetText(TextSetOptions.None, Seed);
                SetList(0, MarkerType.Bullet, 1, 0, MarkerStyle.Undefined);
                SetList(1, MarkerType.Bullet, 2, 0, MarkerStyle.Undefined);
                SetList(2, MarkerType.Bullet, 3, 0, MarkerStyle.Undefined);
                SetList(3, MarkerType.LowercaseEnglishLetter, 2, 1, MarkerStyle.Period);
                SetList(4, MarkerType.LowercaseRoman, 3, 1, MarkerStyle.Period);
                SetList(5, MarkerType.UnicodeSequence, 1, 0x25E6, MarkerStyle.Plain);
                SetList(6, MarkerType.UnicodeSequence, 1, 0x25AA, MarkerStyle.Plain);
                SetList(7, MarkerType.UnicodeSequence, 1, 0x2610, MarkerStyle.Plain);
                Reads("types");
                Paras("types");
                await Task.Delay(400);
                await Shot(DIR + @"\l3.bmp");

                Log.Line("== L4 ListStart per paragraph: three Arabic items with ListStart 1, 1, 1 then 1, 5, 9; and UnicodeSequence 2610 on two consecutive ==");
                doc.SetText(TextSetOptions.None, Seed);
                for (int n = 0; n < 3; n++) SetList(n, MarkerType.Arabic, 1, 1, MarkerStyle.Period);
                SetList(4, MarkerType.UnicodeSequence, 1, 0x2610, MarkerStyle.Plain);
                SetList(5, MarkerType.UnicodeSequence, 1, 0x2610, MarkerStyle.Plain);
                SetList(6, MarkerType.UnicodeSequence, 1, 0x2611, MarkerStyle.Plain);
                Paras("start111");
                SetList(1, MarkerType.Arabic, 1, 5, MarkerStyle.Period);
                SetList(2, MarkerType.Arabic, 1, 9, MarkerStyle.Period);
                Paras("start159");
                await Task.Delay(400);
                await Shot(DIR + @"\l4.bmp");

                Log.Line("== L5 numbering across a bullet in between and a deeper level ==");
                doc.SetText(TextSetOptions.None, Seed);
                SetList(0, MarkerType.Arabic, 1, 1, MarkerStyle.Period);
                SetList(1, MarkerType.LowercaseEnglishLetter, 2, 1, MarkerStyle.Period);
                SetList(2, MarkerType.Arabic, 1, 2, MarkerStyle.Period);
                SetList(3, MarkerType.Bullet, 1, 0, MarkerStyle.Undefined);
                SetList(4, MarkerType.Arabic, 1, 1, MarkerStyle.Period);
                Paras("mixed");

                Log.Line("== K keys on a plain paragraph and on a list item (real keybd_event) ==");
                doc.SetText(TextSetOptions.None, "abc\rdef");
                SetList(1, MarkerType.Bullet, 1, 0, MarkerStyle.Undefined);
                box.Focus(FocusState.Programmatic);
                await Task.Delay(300);
                Caret("key", 1);
                await Key(0x09);
                Reads("after Tab in plain");
                Log.Line("  focus after Tab: " + box.FocusState);
                box.Focus(FocusState.Programmatic);
                Caret("key", Get(doc, TextGetOptions.AdjustCrlf).IndexOf('d'));
                await Key(0x09);
                Reads("after Tab at list start");
                Paras("after Tab at list start");
                await Key(0x09, shift: true);
                Reads("after Shift+Tab");
                Paras("after Shift+Tab");
                await Key(0x08);
                Reads("after Back at list start");
                Paras("after Back at list start");
                Caret("key", Get(doc, TextGetOptions.AdjustCrlf).Length);
                await Key(0x0D);
                Reads("after Return at end");
                Paras("after Return at end");

                Log.Line("== C copy ==");
                doc.Selection.SetRange(0, 3);
                doc.Selection.Copy();
                Log.Line("  after ITextSelection.Copy");
                doc.GetRange(0, 3).Copy();
                Log.Line("  after ITextRange.Copy");
                doc.Selection.SetRange(0, 3);
                await Key(0x43, ctrl: true);
                Log.Line("  after Ctrl+C");

                Log.Line("== T a run's colour across a theme switch ==");
                root.RequestedTheme = ElementTheme.Light;
                await Task.Delay(600);
                doc.SetText(TextSetOptions.None, "Fresh from the market.");
                var run = doc.GetRange(0, 5);
                var cf = run.CharacterFormat;
                cf.ForegroundColor = Color.FromArgb(255, 0x01, 0x6F, 0xEF);
                run.CharacterFormat = cf;
                var plain = doc.GetRange(6, 10).CharacterFormat.ForegroundColor;
                Log.Line("  light: run=" + doc.GetRange(0, 5).CharacterFormat.ForegroundColor + " other=" + plain);
                await Shot(DIR + @"\t-light.bmp");
                root.RequestedTheme = ElementTheme.Dark;
                await Task.Delay(1200);
                Log.Line("  dark: run=" + doc.GetRange(0, 5).CharacterFormat.ForegroundColor + " other=" + doc.GetRange(6, 10).CharacterFormat.ForegroundColor);
                await Shot(DIR + @"\t-dark.bmp");
                root.RequestedTheme = ElementTheme.Light;
                await Task.Delay(1200);
                Log.Line("  light again: run=" + doc.GetRange(0, 5).CharacterFormat.ForegroundColor + " other=" + doc.GetRange(6, 10).CharacterFormat.ForegroundColor);
                await Shot(DIR + @"\t-light2.bmp");
            }
            catch (Exception ex)
            {
                Log.Line("Drive THREW " + ex);
            }
            Log.Line("PROBEDONE");
            Environment.Exit(0);
        }

        async Task Shot(string path)
        {
            try
            {
                var rtb = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
                await rtb.RenderAsync(box);
                var buf = await rtb.GetPixelsAsync();
                var px = new byte[buf.Length];
                Windows.Storage.Streams.DataReader.FromBuffer(buf).ReadBytes(px);
                int w = rtb.PixelWidth, h = rtb.PixelHeight, stride = w * 4;
                using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
                using (var bw = new BinaryWriter(fs))
                {
                    bw.Write((ushort)0x4d42); bw.Write(54 + px.Length); bw.Write(0); bw.Write(54);
                    bw.Write(40); bw.Write(w); bw.Write(h); bw.Write((ushort)1); bw.Write((ushort)32);
                    bw.Write(0); bw.Write(px.Length); bw.Write(2835); bw.Write(2835); bw.Write(0); bw.Write(0);
                    for (int y = h - 1; y >= 0; y--) bw.Write(px, y * stride, stride);
                }
                Log.Line("  shot " + path + " " + w + "x" + h);
            }
            catch (Exception ex) { Log.Line("  shot THREW " + ex.GetType().Name + ": " + ex.Message); }
        }
    }
}
