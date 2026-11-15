// The WinUI 3 highlight probe (docs/highlight-plan.md §3 and §1).
//
//   R1  RichEdit's RTF READER: \highlightN, \cbN, \chshdng0\chcbpatN and
//       \highlightN\cbN each loaded with SetText(FormatRtf); the run's
//       BackgroundColor read back, and GetText(FormatRtf) shows what it writes.
//       WordPad, the reader the plan named, is not on this guest (removed in
//       Windows 11 24H2); RichEditBox is the same RichEdit engine.
//   S1  the ONE BackgroundColor slot: the mark's value over a word, find's
//       #FFF18F over half of it, read per character.
//   T1  a theme switch: the slot and the foreground read before, after Dark,
//       after Light again.
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KayaHlProbe
{
    public static class Log
    {
        public static string Path = @"C:\kaya\hl-probe\log.txt";
        public static void Line(string s)
        {
            try { File.AppendAllText(Path, s + "\r\n", Encoding.UTF8); } catch { }
            Console.WriteLine(s);
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
        Window win;
        Grid root;
        RichEditBox box;

        public ProbeApp()
        {
            InitializeComponent();
            UnhandledException += (s, e) => { Log.Line("XAML UnhandledException " + e.Message); e.Handled = true; };
        }

        static string Hex(Windows.UI.Color c) => $"{c.A:X2}{c.R:X2}{c.G:X2}{c.B:X2}";

        string Runs(string label, int len)
        {
            var b = new StringBuilder(label + ":");
            string last = null; int from = 0;
            for (int i = 0; i <= len; i++)
            {
                string cur = null;
                if (i < len)
                {
                    var r = box.Document.GetRange(i, i + 1);
                    cur = "bg=" + Hex(r.CharacterFormat.BackgroundColor) + " fg=" + Hex(r.CharacterFormat.ForegroundColor);
                }
                if (cur != last)
                {
                    if (last != null) b.Append($" [{from},{i}) {last};");
                    last = cur; from = i;
                }
            }
            return b.ToString();
        }

        protected override void OnLaunched(LaunchActivatedEventArgs args)
        {
            win = new Window();
            root = new Grid();
            box = new RichEditBox { Width = 700, Height = 200 };
            root.Children.Add(box);
            win.Content = root;
            box.Loaded += async (s, e) => { try { await Run(); } catch (Exception ex) { Log.Line("THREW " + ex); } Log.Line("PROBEDONE"); };
            win.Activate();
        }

        async Task Run()
        {
            Log.Line("== R1 RichEdit's RTF reader ==");
            const string head = @"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red255\green235\blue59;}\f0 plain ";
            var cases = new (string, string)[] {
                ("highlight", @"{\highlight1 MARKED}"),
                ("cb", @"{\cb1 MARKED}"),
                ("chcbpat", @"{\chshdng0\chcbpat1 MARKED}"),
                ("highlight+cb", @"{\highlight1\cb1 MARKED}"),
                ("highlight0-clears", @"{\highlight1 MA\highlight0 RKED}"),
            };
            foreach (var (name, body) in cases)
            {
                box.Document.SetText(TextSetOptions.FormatRtf, head + body + @" plain\par}");
                box.Document.GetText(TextGetOptions.None, out var plain);
                var mid = box.Document.GetRange(8, 9);
                Log.Line($"  {name,-18} text={plain.TrimEnd('\r')} MARKED[2]={Hex(mid.CharacterFormat.BackgroundColor)} plain[1]={Hex(box.Document.GetRange(1, 2).CharacterFormat.BackgroundColor)}");
                Log.Line("    " + Runs("runs", plain.TrimEnd('\r').Length));
                box.Document.GetText(TextGetOptions.FormatRtf, out var rtf);
                var at = rtf.IndexOf("MARKED", StringComparison.Ordinal);
                var colortbl = rtf.IndexOf("{\\colortbl", StringComparison.Ordinal);
                Log.Line("    writes colortbl: " + (colortbl >= 0 ? rtf.Substring(colortbl, Math.Min(80, rtf.Length - colortbl)).Replace("\r", "").Replace("\n", "") : "<none>"));
                Log.Line("    writes around run: " + rtf.Substring(Math.Max(0, at - 60), Math.Min(80, rtf.Length - Math.Max(0, at - 60))).Replace("\r", "").Replace("\n", ""));
            }

            Log.Line("== S1 the one slot: mark then find over half ==");
            box.Document.SetText(TextSetOptions.None, "plain MARKEDWORD plain");
            var mark = Windows.UI.Color.FromArgb(0xFF, 0xF7, 0xE8, 0xAF);
            var find = Windows.UI.Color.FromArgb(0xFF, 0xFF, 0xF1, 0x8F);
            box.Document.GetRange(6, 16).CharacterFormat.BackgroundColor = mark;
            Log.Line("  " + Runs("mark", 22));
            box.Document.GetRange(12, 16).CharacterFormat.BackgroundColor = find;
            Log.Line("  " + Runs("mark+find", 22));

            Log.Line("== T1 theme switch ==");
            Log.Line("  " + Runs("before", 22));
            root.RequestedTheme = ElementTheme.Dark;
            await Task.Delay(1500);
            Log.Line("  " + Runs("after-dark", 22));
            root.RequestedTheme = ElementTheme.Light;
            await Task.Delay(1500);
            Log.Line("  " + Runs("after-light", 22));
        }
    }
}
