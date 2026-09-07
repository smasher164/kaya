// The search probe (docs/search-plan.md §7, the WinUI row of §3): the two
// readings the plan asks for before the arm is chosen —
//
//   1. does an AutoSuggestBox with QueryIcon=Find and NO ItemsSource ever
//      open an empty suggestions flyout while a REAL USER types into it, and
//   2. what AutomationControlType does its peer report,
//
// plus the three the arm needs whichever control wins: whether the control's
// own clear button is reachable (template part + Invoke pattern), whether a
// plain KeyDown handler — the only registration a Rust WinRT delegate can
// make, since AddHandler's handled-events-too overload wants an IInspectable
// (CLAUDE.md, the slider row) — ever sees Escape, and what PlaceholderText
// reads back as.
//
// Real keys, not property writes: the flyout question is about USER input,
// and TextChanged carries a Reason that says which arrived. The process runs
// in the guest's interactive session (schtasks /it), so keybd_event lands in
// its own foreground window.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace KayaSearchProbe
{
    public static class Log
    {
        static readonly object Gate = new object();
        public static string Path =
            Environment.GetEnvironmentVariable("KAYA_SP_LOG") ?? @"C:\kaya\searchprobe\log.txt";

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

        const uint KEYUP = 0x2;
        const byte VK_SHIFT = 0x10;
        const byte VK_ESCAPE = 0x1b;
        const byte VK_BACK = 0x08;

        Window win;
        AutoSuggestBox asb;
        TextBox tb;
        IntPtr hwnd;

        // Every TextChanged, with the Reason the S6 arm would read.
        readonly List<string> asbChanges = new List<string>();
        readonly List<string> tbChanges = new List<string>();
        // Every key event either handler saw, tagged with which registration.
        readonly List<string> keys = new List<string>();

        public ProbeApp()
        {
            InitializeComponent();
            UnhandledException += (s, e) =>
            {
                Log.Line("probe XAML UnhandledException: " + e.Message + " / " + e.Exception);
                e.Handled = true;
            };
        }

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            Log.Line("probe OnLaunched");
            // App.xaml merges XamlControlsResources; this only reports it.
            Log.Line("probe merged dictionaries=" + Resources.MergedDictionaries.Count);

            var stack = new StackPanel { Spacing = 12, Margin = new Thickness(16) };

            asb = new AutoSuggestBox
            {
                Name = "probeAsb",
                PlaceholderText = "Search",
                QueryIcon = new SymbolIcon(Symbol.Find),
                Width = 320,
            };
            // NO ItemsSource AT ALL — the plan's question is exactly this shape.
            asb.TextChanged += (s, a) =>
            {
                asbChanges.Add(a.Reason + "=" + Quote(asb.Text));
                Log.Line("asb TextChanged reason=" + a.Reason + " text=" + Quote(asb.Text)
                         + " listOpen=" + asb.IsSuggestionListOpen);
            };
            asb.QuerySubmitted += (s, a) => Log.Line("asb QuerySubmitted " + Quote(a.QueryText));
            asb.SuggestionChosen += (s, a) => Log.Line("asb SuggestionChosen");
            asb.KeyDown += (s, a) => keys.Add("asb.KeyDown " + a.Key + " handled=" + a.Handled);
            asb.PreviewKeyDown += (s, a) => keys.Add("asb.PreviewKeyDown " + a.Key + " handled=" + a.Handled);
            // The registration a Rust delegate CANNOT make, measured beside the
            // one it can: if only this one fires for Escape, the WinUI Escape
            // arm cannot be a KeyDown handler on the control.
            asb.AddHandler(UIElement.KeyDownEvent,
                new KeyEventHandler((s, a) => keys.Add("asb.AddHandler(true) " + a.Key + " handled=" + a.Handled)),
                true);
            stack.Children.Add(asb);

            tb = new TextBox { Name = "probeTb", PlaceholderText = "Search", Width = 320 };
            tb.TextChanged += (s, a) =>
            {
                tbChanges.Add(Quote(tb.Text));
                Log.Line("tb TextChanged text=" + Quote(tb.Text));
            };
            tb.KeyDown += (s, a) => keys.Add("tb.KeyDown " + a.Key + " handled=" + a.Handled);
            tb.AddHandler(UIElement.KeyDownEvent,
                new KeyEventHandler((s, a) => keys.Add("tb.AddHandler(true) " + a.Key + " handled=" + a.Handled)),
                true);
            stack.Children.Add(tb);

            win = new Window { Title = "kaya search probe" };
            win.Content = stack;
            win.Activate();
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
            Log.Line("probe window activated hwnd=" + hwnd.ToString("x"));
            Drive();
        }

        static string Quote(string s) { return s == null ? "<null>" : "\"" + s + "\""; }

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

        /// The flyout reading, polled rather than sampled once: a popup that
        /// opens and closes inside one 300ms sleep is a popup the arm would
        /// have shipped. Reports the MAXIMUM seen, and says how many samples
        /// it took — a reading of zero over one sample measures nothing.
        async Task<string> WatchPopups(int ms)
        {
            int samples = 0, maxPopups = 0, listOpen = 0;
            var seen = new List<string>();
            var until = DateTime.Now.AddMilliseconds(ms);
            while (DateTime.Now < until)
            {
                samples++;
                if (asb.IsSuggestionListOpen) listOpen++;
                try
                {
                    var popups = VisualTreeHelper.GetOpenPopupsForXamlRoot(asb.XamlRoot);
                    if (popups.Count > maxPopups) maxPopups = popups.Count;
                    foreach (var p in popups)
                    {
                        var what = p.Child == null ? "<no child>" : p.Child.GetType().Name;
                        var fe = p.Child as FrameworkElement;
                        var label = what + (fe != null && !string.IsNullOrEmpty(fe.Name) ? "#" + fe.Name : "");
                        if (!seen.Contains(label)) seen.Add(label);
                    }
                }
                catch (Exception ex) { seen.Add("<popup read threw " + ex.GetType().Name + ">"); }
                // await, NEVER Thread.Sleep: this runs ON the UI thread, and a
                // blocking sleep stops message dispatch — the first run's
                // injected keys sat in the queue and arrived after the
                // programmatic write, so M1 measured nothing.
                await Task.Delay(15);
            }
            return "samples=" + samples + " maxOpenPopups=" + maxPopups
                   + " listOpenSamples=" + listOpen
                   + " popups=[" + string.Join(",", seen) + "]";
        }

        static void DumpTree(DependencyObject node, int depth, List<string> into)
        {
            if (depth > 6) return;
            int n = VisualTreeHelper.GetChildrenCount(node);
            for (int i = 0; i < n; i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                var fe = child as FrameworkElement;
                var line = new string(' ', depth * 2) + child.GetType().Name;
                if (fe != null)
                {
                    if (!string.IsNullOrEmpty(fe.Name)) line += " #" + fe.Name;
                    line += " vis=" + fe.Visibility;
                }
                into.Add(line);
                DumpTree(child, depth + 1, into);
            }
        }

        static DependencyObject FindByName(DependencyObject node, string name, int depth)
        {
            if (depth > 8) return null;
            int n = VisualTreeHelper.GetChildrenCount(node);
            for (int i = 0; i < n; i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                var fe = child as FrameworkElement;
                if (fe != null && fe.Name == name) return child;
                var hit = FindByName(child, name, depth + 1);
                if (hit != null) return hit;
            }
            return null;
        }

        static T FindFirst<T>(DependencyObject node, int depth) where T : class
        {
            if (depth > 8) return null;
            int n = VisualTreeHelper.GetChildrenCount(node);
            for (int i = 0; i < n; i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                var hit = child as T;
                if (hit != null) return hit;
                var deeper = FindFirst<T>(child, depth + 1);
                if (deeper != null) return deeper;
            }
            return null;
        }

        static void ReportPeer(string what, UIElement element)
        {
            if (element == null) { Log.Line("PEER " + what + ": <no element>"); return; }
            try
            {
                var fe = element as FrameworkElement;
                var peer = FrameworkElementAutomationPeer.CreatePeerForElement(fe);
                if (peer == null) { Log.Line("PEER " + what + ": <no peer>"); return; }
                Log.Line("PEER " + what
                         + ": controlType=" + peer.GetAutomationControlType()
                         + " className=" + peer.GetClassName()
                         + " localized=\"" + peer.GetLocalizedControlType() + "\""
                         + " name=\"" + peer.GetName() + "\""
                         + " valuePattern=" + (peer.GetPattern(PatternInterface.Value) != null)
                         + " invokePattern=" + (peer.GetPattern(PatternInterface.Invoke) != null));
                var kids = peer.GetChildren();
                if (kids != null)
                    foreach (var k in kids)
                        Log.Line("PEER " + what + " child: controlType=" + k.GetAutomationControlType()
                                 + " className=" + k.GetClassName() + " name=\"" + k.GetName() + "\"");
            }
            catch (Exception ex) { Log.Line("PEER " + what + " THREW " + ex.GetType().Name + ": " + ex.Message); }
        }

        async void Drive()
        {
            try
            {
                await Task.Delay(1500);
                SetForegroundWindow(hwnd);
                await Task.Delay(300);

                Log.Line("== M0 placeholder read-back ==");
                Log.Line("asb.PlaceholderText=" + Quote(asb.PlaceholderText)
                         + " tb.PlaceholderText=" + Quote(tb.PlaceholderText));

                Log.Line("== M1 the flyout, on REAL keystrokes into an AutoSuggestBox with no ItemsSource ==");
                asb.Focus(FocusState.Programmatic);
                await Task.Delay(300);
                Log.Line("before typing: " + await WatchPopups(300));
                foreach (char ch in "ang")
                {
                    SendChar(ch);
                    await Task.Delay(50);
                    Log.Line("after '" + ch + "': text=" + Quote(asb.Text) + " " + await WatchPopups(600));
                }
                Log.Line("asb changes so far: [" + string.Join(", ", asbChanges) + "]");

                Log.Line("== M1b a PROGRAMMATIC write (the Prop::Text path) ==");
                asbChanges.Clear();
                asb.Text = "ch";
                await Task.Delay(200);
                Log.Line("after programmatic write: " + await WatchPopups(400)
                         + " changes=[" + string.Join(", ", asbChanges) + "]");

                Log.Line("== M2 the automation peers ==");
                ReportPeer("AutoSuggestBox", asb);
                var inner = FindFirst<TextBox>(asb, 0);
                Log.Line("asb inner TextBox: " + (inner == null ? "<not reachable through the visual tree>"
                                                                : "found, Name=\"" + inner.Name + "\""));
                ReportPeer("AutoSuggestBox.innerTextBox", inner);
                ReportPeer("TextBox", tb);

                Log.Line("== M3 the AutoSuggestBox visual tree (the clear affordance lives here) ==");
                var tree = new List<string>();
                DumpTree(asb, 0, tree);
                foreach (var line in tree) Log.Line("  " + line);

                Log.Line("== M4 the control's own clear button ==");
                var del = FindByName(asb, "DeleteButton", 0) as Button;
                if (del == null) del = FindByName(asb, "DeleteButton", 0) as Button;
                Log.Line("DeleteButton under the AutoSuggestBox: "
                         + (del == null ? "<not found by name>" : "found vis=" + del.Visibility));
                if (del != null)
                {
                    asbChanges.Clear();
                    try
                    {
                        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(del);
                        var invoke = peer.GetPattern(PatternInterface.Invoke) as IInvokeProvider;
                        Log.Line("DeleteButton invoke provider: " + (invoke != null));
                        if (invoke != null)
                        {
                            invoke.Invoke();
                            await Task.Delay(400);
                            Log.Line("after Invoke: asb.Text=" + Quote(asb.Text)
                                     + " changes=[" + string.Join(", ", asbChanges) + "]"
                                     + " focusedIsAsb=" + IsAsbFocused());
                        }
                    }
                    catch (Exception ex) { Log.Line("DeleteButton invoke THREW " + ex.GetType().Name + ": " + ex.Message); }
                }
                var tbDel = FindByName(tb, "DeleteButton", 0) as Button;
                Log.Line("DeleteButton under the plain TextBox: "
                         + (tbDel == null ? "<not found by name>" : "found vis=" + tbDel.Visibility));

                Log.Line("== M5 Escape ==");
                keys.Clear();
                asbChanges.Clear();
                asb.Focus(FocusState.Programmatic);
                await Task.Delay(200);
                foreach (char ch in "an") SendChar(ch);
                await Task.Delay(400);
                Log.Line("asb before Escape: " + Quote(asb.Text));
                keys.Clear();
                SendVk(VK_ESCAPE);
                await Task.Delay(500);
                Log.Line("asb after Escape: " + Quote(asb.Text)
                         + " focusedIsAsb=" + IsAsbFocused()
                         + " changes=[" + string.Join(", ", asbChanges) + "]");
                Log.Line("keys the handlers saw: [" + string.Join(" | ", keys) + "]");

                keys.Clear();
                tbChanges.Clear();
                tb.Focus(FocusState.Programmatic);
                await Task.Delay(200);
                foreach (char ch in "an") SendChar(ch);
                await Task.Delay(400);
                Log.Line("tb before Escape: " + Quote(tb.Text));
                keys.Clear();
                SendVk(VK_ESCAPE);
                await Task.Delay(500);
                Log.Line("tb after Escape: " + Quote(tb.Text)
                         + " changes=[" + string.Join(", ", tbChanges) + "]");
                Log.Line("keys the handlers saw: [" + string.Join(" | ", keys) + "]");

                Log.Line("== M6 backspace out of the AutoSuggestBox (the empty-flyout tail) ==");
                asb.Focus(FocusState.Programmatic);
                await Task.Delay(200);
                for (int i = 0; i < 4; i++)
                {
                    SendVk(VK_BACK);
                    Log.Line("after backspace " + i + ": text=" + Quote(asb.Text) + " " + await WatchPopups(300));
                }
            }
            catch (Exception ex)
            {
                Log.Line("probe Drive THREW " + ex);
            }
            Log.Line("PROBEDONE");
            Environment.Exit(0);
        }

        bool IsAsbFocused()
        {
            var focused = FocusManager.GetFocusedElement(win.Content.XamlRoot) as DependencyObject;
            if (focused == null) return false;
            if (ReferenceEquals(focused, asb)) return true;
            // The inner TextBox holds the keyboard focus when the box does.
            for (DependencyObject node = focused; node != null; node = VisualTreeHelper.GetParent(node))
                if (ReferenceEquals(node, asb)) return true;
            return false;
        }
    }
}
