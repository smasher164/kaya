// The stock Win32/OLE side of the drag probe. Two modes:
//   StockOle.exe target [x y w h]   an OLE drop target that reports every
//                                   format the drag offered it
//   StockOle.exe source [x y w h]   an OLE drag source offering a
//                                   registered custom format plus text,
//                                   plus CF_HDROP for $KAYA_DP_FILE when
//                                   that names one (the foreign FILE drag
//                                   the dnd witness legs need, docs/
//                                   dnd-plan.md §5 step 7)
// Both print a READY line with the window rect in SCREEN pixels, which is
// what the SendInput driver aims at, and both exit on their own after
// KAYA_DP_TTL seconds so a probe run leaves nothing behind.
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using KayaDragProbe.Shared;

namespace KayaDragProbe
{
    static class StockProgram
    {
        const string CUSTOM = "dev.kaya/note";

        /// DROPFILES: the 20-byte header (pFiles=20, pt={0,0}, fNC=0,
        /// fWide=1) then the double-NUL-terminated UTF-16 list — the shape
        /// crates/kaya/src/winui/mod.rs's parse_dropfiles reads back.
        static byte[] DropFiles(string path)
        {
            var names = Encoding.Unicode.GetBytes(path + "\0\0");
            var buf = new byte[20 + names.Length];
            BitConverter.GetBytes(20).CopyTo(buf, 0);
            BitConverter.GetBytes(1).CopyTo(buf, 16);
            names.CopyTo(buf, 20);
            return buf;
        }

        [STAThread]
        static void Main(string[] args)
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            string mode = args.Length > 0 ? args[0] : "target";
            int x = args.Length > 4 ? int.Parse(args[1]) : 520;
            int y = args.Length > 4 ? int.Parse(args[2]) : 0;
            int w = args.Length > 4 ? int.Parse(args[3]) : 480;
            int h = args.Length > 4 ? int.Parse(args[4]) : 700;

            Native.OleInitialize(IntPtr.Zero);

            var form = new Form
            {
                Text = "kaya stock OLE " + mode,
                StartPosition = FormStartPosition.Manual,
                Bounds = new Rectangle(x, y, w, h),
                BackColor = mode == "source" ? Color.FromArgb(220, 235, 255) : Color.FromArgb(255, 235, 220),
                TopMost = true,
            };
            var label = new Label
            {
                Dock = DockStyle.Fill,
                Text = "stock OLE " + mode,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Segoe UI", 14),
            };
            form.Controls.Add(label);

            LoggingDropTarget target = null;
            form.Shown += (s, e) =>
            {
                var r = form.Bounds;
                Log.Line("stock READY mode=" + mode + " hwnd=0x" + form.Handle.ToString("x") +
                         " rect=" + r.Left + "," + r.Top + "," + r.Right + "," + r.Bottom +
                         " dpi=" + Native.GetDpiForWindow(form.Handle));
                if (mode == "target")
                {
                    // UIPI: a lower-integrity source cannot post the drag
                    // messages to an elevated window unless they are let
                    // through by hand. Asked for unconditionally so the
                    // elevated and non-elevated runs differ in nothing else.
                    Native.ChangeWindowMessageFilterEx(form.Handle, 0x0233 /* WM_DROPFILES */, 1, IntPtr.Zero);
                    Native.ChangeWindowMessageFilterEx(form.Handle, 0x0049 /* WM_COPYGLOBALDATA */, 1, IntPtr.Zero);
                    Native.ChangeWindowMessageFilterEx(form.Handle, 0x004A /* WM_COPYDATA */, 1, IntPtr.Zero);
                    target = new LoggingDropTarget("stock", CUSTOM);
                    int hr = Native.RegisterDragDrop(form.Handle, target);
                    Log.Line("stock RegisterDragDrop hr=0x" + hr.ToString("x8"));
                }
            };

            if (mode == "source")
            {
                MouseEventHandler down = (s, e) =>
                {
                    if (e.Button != MouseButtons.Left) return;
                    var data = new SimpleDataObject();
                    uint cf = Native.RegisterClipboardFormatW(CUSTOM);
                    var payload = Encoding.UTF8.GetBytes("kaya-note-from-win32-ole");
                    data.Add(cf, payload);
                    data.Add(Native.CF_UNICODETEXT,
                             Encoding.Unicode.GetBytes("kaya stock text\0"));
                    string file = Environment.GetEnvironmentVariable("KAYA_DP_FILE");
                    if (!string.IsNullOrEmpty(file))
                    {
                        data.Add(Native.CF_HDROP, DropFiles(file));
                        Log.Line("stock offering CF_HDROP \"" + file + "\"");
                    }
                    Log.Line("stock DoDragDrop begin: custom \"" + CUSTOM + "\" cf=" + cf +
                             " " + Fmt.Show(payload) + " + CF_UNICODETEXT");
                    int effect;
                    int hr = Drag.DoDragDrop(data, new SimpleDropSource(), 1 | 2, out effect);
                    Log.Line("stock DoDragDrop returned hr=0x" + hr.ToString("x8") + " effect=" + effect);
                };
                form.MouseDown += down;
                label.MouseDown += down;
            }

            int ttl;
            if (!int.TryParse(Environment.GetEnvironmentVariable("KAYA_DP_TTL"), out ttl) || ttl <= 0)
                ttl = 150;
            var timer = new System.Windows.Forms.Timer { Interval = ttl * 1000 };
            timer.Tick += (s, e) => { Log.Line("stock TTL reached, exiting"); Application.Exit(); };
            timer.Start();

            Application.Run(form);
            if (target != null) Native.RevokeDragDrop(form.Handle);
            Log.Line("stock EXIT mode=" + mode);
        }
    }
}
