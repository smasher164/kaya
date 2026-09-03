// The WinUI 3 half of the drag probe (docs/dnd-plan.md §2 probes 1 and 2).
// One window, two zones: a XAML DRAG SOURCE (CanDrag, DragStarting fills a
// DataPackage) and a DROP ZONE. The drop zone is served either by XAML
// (AllowDrop + DragOver/Drop) or by classic OLE (RevokeDragDrop then
// RegisterDragDrop on the window's own HWND with kaya's own IDropTarget) —
// KAYA_DP_MODE picks, because the whole question of probe 2 is which of
// the two receives what Explorer sends.
//
// No XAML markup on purpose: DISABLE_XAML_GENERATED_MAIN plus a code-built
// tree is the smallest WinUI 3 app that can answer the question, and it
// keeps the XAML compiler out of the probe's failure surface.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using KayaDragProbe.Shared;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KayaDragProbe
{
    public static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            // EVERY STAGE SAYS IT REACHED THE NEXT ONE: a WinUI app that
            // exits silently before OnLaunched writes nothing at all, and
            // "the log is empty" cannot tell a crashed bootstrap from a
            // window that never appeared.
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
                Log.Line("winui UNHANDLED " + e.ExceptionObject);
            Log.Line("winui Main entered");
            try
            {
                WinRT.ComWrappersSupport.InitializeComWrappers();
                Log.Line("winui ComWrappers initialized");
                Application.Start((p) =>
                {
                    Log.Line("winui Application.Start callback");
                    var q = DispatcherQueue.GetForCurrentThread();
                    System.Threading.SynchronizationContext.SetSynchronizationContext(
                        new DispatcherQueueSynchronizationContext(q));
                    new ProbeApp();
                });
                Log.Line("winui Application.Start returned");
            }
            catch (Exception ex)
            {
                Log.Line("winui Main THREW " + ex);
            }
        }
    }

    public class ProbeApp : Application
    {
        const string CUSTOM = "dev.kaya/note";
        const string CUSTOM_STREAM = "dev.kaya/note.stream";

        Window win;
        Border source;
        Border drop;
        IntPtr hwnd;
        string mode;
        readonly List<LoggingDropTarget> oleTargets = new List<LoggingDropTarget>();
        POINTL dropCentre;

        public ProbeApp()
        {
            Log.Line("winui ProbeApp ctor");
            UnhandledException += (s, e) =>
            {
                Log.Line("winui XAML UnhandledException: " + e.Message + " / " + e.Exception);
                e.Handled = true;
            };
            Log.Line("winui ProbeApp ctor done");
        }

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            Log.Line("winui OnLaunched");
            // MERGED HERE, NOT IN THE CTOR, and tiered: the framework's
            // control resources resolve through ms-appx against the EXE's
            // directory, and a failure is a later silent fail-fast rather
            // than an exception here (crates/kaya/src/winui/mod.rs,
            // require_control_resources).
            try
            {
                Resources.MergedDictionaries.Add(
                    new Microsoft.UI.Xaml.Controls.XamlControlsResources());
                Log.Line("winui XamlControlsResources merged");
            }
            catch (Exception ex)
            {
                Log.Line("winui XamlControlsResources FAILED: " + ex.GetType().Name + ": " + ex.Message);
            }
            mode = Environment.GetEnvironmentVariable("KAYA_DP_MODE") ?? "xaml";
            var grid = new Grid();
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            source = new Border
            {
                Background = new SolidColorBrush(Microsoft.UI.Colors.LightGreen),
                CanDrag = true,
                Margin = new Thickness(8),
                Child = new TextBlock { Text = "XAML SOURCE (CanDrag)", Margin = new Thickness(12) },
            };
            source.DragStarting += OnDragStarting;
            source.DropCompleted += OnDropCompleted;
            Grid.SetRow(source, 0);
            grid.Children.Add(source);

            drop = new Border
            {
                Background = new SolidColorBrush(Microsoft.UI.Colors.LightPink),
                Margin = new Thickness(8),
                Child = new TextBlock { Text = "DROP ZONE (" + mode + ")", Margin = new Thickness(12) },
            };
            if (mode == "xaml" || mode == "both")
            {
                drop.AllowDrop = true;
                drop.DragEnter += OnDragEnter;
                drop.DragOver += OnDragOver;
                drop.DragLeave += OnDragLeave;
                drop.Drop += OnDrop;
                // The window's whole content accepts too: issue #10119
                // reports DragOver never firing at all, and a zone that is
                // merely mis-aimed would look the same from outside.
                grid.AllowDrop = true;
                grid.DragOver += OnDragOverRoot;
                grid.Drop += OnDrop;
            }
            Grid.SetRow(drop, 1);
            grid.Children.Add(drop);

            win = new Window { Title = "kaya dragprobe winui" };
            win.Content = grid;
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
            win.Activate();

            int x = EnvInt("KAYA_DP_X", 0), y = EnvInt("KAYA_DP_Y", 0);
            int w = EnvInt("KAYA_DP_W", 500), h = EnvInt("KAYA_DP_H", 700);
            Native.SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, 0x0004 /* SWP_NOZORDER */);


            // REPORTED AFTER THE MOVE, not on Loaded: Loaded can fire inside
            // Activate(), before SetWindowPos, and a zone rectangle from
            // before the move aims the driver at the wrong pixels.
            var q = DispatcherQueue.GetForCurrentThread();
            var geo = q.CreateTimer();
            geo.Interval = TimeSpan.FromMilliseconds(1500);
            geo.IsRepeating = false;
            geo.Tick += (s, ev) =>
            {
                ReportGeometry();
                if (mode == "ole" || mode == "both") RegisterOle();
                if (Environment.GetEnvironmentVariable("KAYA_DP_REGCENSUS") == "1") RegistrationCensus();
            };
            geo.Start();
            var t = new System.Threading.Timer(_ =>
            {
                Log.Line("winui TTL reached, exiting");
                Environment.Exit(0);
            }, null, EnvInt("KAYA_DP_TTL", 150) * 1000, System.Threading.Timeout.Infinite);
            GC.KeepAlive(t);
        }

        /// Does `AllowDrop=true` put an OLE drop target on either HWND?
        /// Asked WITHOUT disturbing one: RegisterDragDrop answers
        /// DRAGDROP_E_ALREADYREGISTERED (0x80040101) when a target is
        /// there, and where it succeeds the probe revokes its own again so
        /// the window is left exactly as it was found.
        void RegistrationCensus()
        {
            Native.OleInitialize(IntPtr.Zero);
            // EVERY DESCENDANT, not just the chain under the drop point: if
            // XAML has an OLE drop target anywhere it is on one of these,
            // and a census that reads two windows agrees with everything.
            var chain = new List<IntPtr> { hwnd };
            Native.EnumChildWindows(hwnd, (h, l) => { chain.Add(h); return true; }, IntPtr.Zero);
            Log.Line("winui CENSUS window tree: " + chain.Count + " window(s)");
            foreach (var h in chain)
            {
                string cls = Native.ClassOf(h);
                int hr;
                try { hr = Native.RegisterDragDrop(h, new LoggingDropTarget("census", CUSTOM)); }
                catch (Exception ex)
                {
                    Log.Line("winui CENSUS hwnd=0x" + h.ToString("x") + " class=" + cls +
                             " RegisterDragDrop THREW " + ex.GetType().Name);
                    continue;
                }
                string verdict = hr == 0 ? "NO target was registered here (the probe's own is revoked again)"
                    : hr == unchecked((int)0x80040101) ? "a drop target IS already registered here"
                    : "unexpected";
                Log.Line("winui CENSUS hwnd=0x" + h.ToString("x") + " class=" + cls +
                         " RegisterDragDrop hr=0x" + hr.ToString("x8") + " -> " + verdict);
                if (hr == 0) Native.RevokeDragDrop(h);
            }
        }

        void RegisterOle()
        {
            // ON THE UI THREAD, AFTER THE WINDOW IS UP, AND OLE-INITIALIZED
            // FIRST: RegisterDragDrop answers E_OUTOFMEMORY (0x8007000e) on
            // a thread that only called CoInitializeEx, which is all the
            // XAML thread does (measured 2026-09-03).
            int ole = Native.OleInitialize(IntPtr.Zero);
            Log.Line("winui OLE route: OleInitialize hr=0x" + ole.ToString("x8"));
            // EVERY HWND UNDER THE DROP POINT, NOT JUST THE TOP-LEVEL ONE:
            // a WinUI 3 window hosts the XAML island in CHILD windows, and
            // OLE's drag loop asks the window the cursor is over. Which one
            // has to carry the target is exactly what this measures, so the
            // chain from the deepest child up to the top-level window is
            // registered a window at a time and each answer is printed.
            var chain = new List<IntPtr>();
            IntPtr deep = Native.WindowFromPoint(dropCentre);
            for (IntPtr h = deep; h != IntPtr.Zero; h = Native.GetParent(h))
            {
                chain.Add(h);
                if (h == hwnd) break;
            }
            if (!chain.Contains(hwnd)) chain.Add(hwnd);
            foreach (var h in chain)
            {
                string cls = Native.ClassOf(h);
                int rev = Native.RevokeDragDrop(h);
                Native.ChangeWindowMessageFilterEx(h, 0x0233, 1, IntPtr.Zero);
                Native.ChangeWindowMessageFilterEx(h, 0x0049, 1, IntPtr.Zero);
                var tgt = new LoggingDropTarget("winui[" + cls + "]", CUSTOM);
                oleTargets.Add(tgt);
                int reg;
                try { reg = Native.RegisterDragDrop(h, tgt); }
                catch (Exception ex)
                {
                    Log.Line("winui OLE route: RegisterDragDrop on 0x" + h.ToString("x") + " (" + cls +
                             ") THREW " + ex.GetType().Name + ": " + ex.Message);
                    continue;
                }
                Log.Line("winui OLE route: hwnd=0x" + h.ToString("x") + " class=" + cls +
                         " RevokeDragDrop hr=0x" + rev.ToString("x8") +
                         " RegisterDragDrop hr=0x" + reg.ToString("x8"));
            }
        }

        static int EnvInt(string name, int dflt)
        {
            int v;
            return int.TryParse(Environment.GetEnvironmentVariable(name), out v) ? v : dflt;
        }

        void ReportGeometry()
        {
            var origin = new POINTL { x = 0, y = 0 };
            Native.ClientToScreen(hwnd, ref origin);
            double scale = source.XamlRoot != null ? source.XamlRoot.RasterizationScale : 1.0;
            Log.Line("winui READY mode=" + mode + " hwnd=0x" + hwnd.ToString("x") +
                     " client-origin=" + origin.x + "," + origin.y +
                     " dpi=" + Native.GetDpiForWindow(hwnd) + " scale=" + scale);
            Zone("source", source, origin, scale);
            Zone("drop", drop, origin, scale);
        }

        void Zone(string name, FrameworkElement el, POINTL origin, double scale)
        {
            var p = el.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
            int sx = origin.x + (int)(p.X * scale);
            int sy = origin.y + (int)(p.Y * scale);
            int sw = (int)(el.ActualWidth * scale);
            int sh = (int)(el.ActualHeight * scale);
            Log.Line("winui ZONE " + name + " x=" + sx + " y=" + sy + " w=" + sw + " h=" + sh +
                     " centre=" + (sx + sw / 2) + "," + (sy + sh / 2));
            if (name == "drop") { dropCentre = new POINTL { x = sx + sw / 2, y = sy + sh / 2 }; }
        }

        // --- the XAML source ------------------------------------------------

        async void OnDragStarting(UIElement sender, DragStartingEventArgs args)
        {
            var def = args.GetDeferral();
            try
            {
                args.Data.RequestedOperation = DataPackageOperation.Copy | DataPackageOperation.Move;
                args.Data.SetText("kaya drag text");
                // TWO FLAVOURS OF THE SAME CUSTOM ID, because the bridge is
                // documented per-flavour: a plain string value, and the
                // RandomAccessStream the SetData reference page names.
                args.Data.SetData(CUSTOM, "kaya-note-from-winrt");
                var ms = new InMemoryRandomAccessStream();
                var writer = new DataWriter(ms.GetOutputStreamAt(0));
                writer.WriteBytes(Encoding.UTF8.GetBytes("kaya-note-stream-bytes"));
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
                ms.Seek(0);
                args.Data.SetData(CUSTOM_STREAM, ms);
                Log.Line("winui DragStarting: SetText + SetData(\"" + CUSTOM +
                         "\", string) + SetData(\"" + CUSTOM_STREAM + "\", IRandomAccessStream); " +
                         "requested=" + args.Data.RequestedOperation);
            }
            catch (Exception ex)
            {
                Log.Line("winui DragStarting THREW " + ex.GetType().Name + ": " + ex.Message);
            }
            finally { def.Complete(); }
        }

        void OnDropCompleted(UIElement sender, DropCompletedEventArgs args)
        {
            Log.Line("winui DropCompleted: result=" + args.DropResult);
        }

        // --- the XAML destination -------------------------------------------

        int overs;

        static string Formats(DataPackageView v)
        {
            try { return "[" + string.Join(", ", v.AvailableFormats) + "]"; }
            catch (Exception e) { return "<AvailableFormats threw " + e.GetType().Name + ">"; }
        }

        void OnDragEnter(object sender, DragEventArgs e)
        {
            Log.Line("winui XAML DragEnter: formats=" + Formats(e.DataView) +
                     " storageitems=" + e.DataView.Contains(StandardDataFormats.StorageItems) +
                     " at " + e.GetPosition(null).X + "," + e.GetPosition(null).Y);
            e.AcceptedOperation = DataPackageOperation.Copy;
        }

        void OnDragOver(object sender, DragEventArgs e)
        {
            overs++;
            if (overs <= 3 || overs % 25 == 0)
                Log.Line("winui XAML DragOver #" + overs + ": formats=" + Formats(e.DataView) +
                         " storageitems=" + e.DataView.Contains(StandardDataFormats.StorageItems));
            e.AcceptedOperation = DataPackageOperation.Copy;
        }

        void OnDragOverRoot(object sender, DragEventArgs e)
        {
            Log.Line("winui XAML DragOver(ROOT GRID): formats=" + Formats(e.DataView));
            e.AcceptedOperation = DataPackageOperation.Copy;
        }

        void OnDragLeave(object sender, DragEventArgs e)
        {
            Log.Line("winui XAML DragLeave (after " + overs + " DragOver)");
        }

        async void OnDrop(object sender, DragEventArgs e)
        {
            var v = e.DataView;
            Log.Line("winui XAML Drop on " + (sender == drop ? "zone" : "root") +
                     ": formats=" + Formats(v) +
                     " storageitems=" + v.Contains(StandardDataFormats.StorageItems) +
                     " text=" + v.Contains(StandardDataFormats.Text));
            var def = e.GetDeferral();
            try
            {
                foreach (var id in new[] { CUSTOM, CUSTOM_STREAM })
                {
                    if (!v.Contains(id)) { Log.Line("winui XAML Drop: \"" + id + "\" ABSENT from AvailableFormats"); continue; }
                    try
                    {
                        object o = await v.GetDataAsync(id);
                        Log.Line("winui XAML Drop: \"" + id + "\" -> " + Describe(o));
                    }
                    catch (Exception ex)
                    {
                        Log.Line("winui XAML Drop: \"" + id + "\" GetDataAsync THREW " +
                                 ex.GetType().Name + ": " + ex.Message);
                    }
                }
                if (v.Contains(StandardDataFormats.StorageItems))
                {
                    try
                    {
                        var items = await v.GetStorageItemsAsync();
                        var names = new List<string>();
                        foreach (var it in items) names.Add(it.Path);
                        Log.Line("winui XAML Drop: storage items (" + names.Count + "): " +
                                 string.Join(" | ", names));
                    }
                    catch (Exception ex)
                    {
                        Log.Line("winui XAML Drop: GetStorageItemsAsync THREW " + ex.GetType().Name +
                                 ": " + ex.Message);
                    }
                }
                if (v.Contains(StandardDataFormats.Text))
                    Log.Line("winui XAML Drop: text=\"" + await v.GetTextAsync() + "\"");
                e.AcceptedOperation = DataPackageOperation.Copy;
            }
            finally { def.Complete(); }
            Log.Line("winui XAML Drop done");
        }

        static string Describe(object o)
        {
            if (o == null) return "<null>";
            var s = o as string;
            if (s != null) return "string \"" + s + "\"";
            var ras = o as IRandomAccessStream;
            if (ras != null)
            {
                try
                {
                    var reader = new DataReader(ras.GetInputStreamAt(0));
                    var n = (uint)Math.Min(ras.Size, 256);
                    reader.LoadAsync(n).AsTask().Wait();
                    var buf = new byte[n];
                    reader.ReadBytes(buf);
                    return "IRandomAccessStream size=" + ras.Size + " " + Fmt.Show(buf);
                }
                catch (Exception e) { return "IRandomAccessStream size=" + ras.Size + " <read threw " + e.GetType().Name + ">"; }
            }
            return o.GetType().FullName + " \"" + o.ToString() + "\"";
        }
    }
}
