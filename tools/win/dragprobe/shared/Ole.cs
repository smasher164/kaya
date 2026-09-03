// The classic-Win32 half of the drag probe, shared by both probe apps
// (docs/dnd-plan.md §2 probes 1 and 2): an IDropTarget that says what it
// was handed, and the readers that turn a FORMATETC into bytes.
//
// EVERY BRANCH PRINTS WHAT IT MEASURED. A reader that cannot tell "the
// format was absent" from "the format was there and empty" would answer
// the probe's question wrongly in the direction that costs most, so the
// two are separate lines.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace KayaDragProbe.Shared
{
    public static class Log
    {
        static readonly object Gate = new object();
        public static string Path =
            Environment.GetEnvironmentVariable("KAYA_DP_LOG") ?? @"C:\kaya\dragprobe\log.txt";

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

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL { public int x; public int y; }

    [ComImport, Guid("00000122-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IOleDropTarget
    {
        [PreserveSig] int DragEnter(IDataObject pDataObj, int grfKeyState, POINTL pt, ref int pdwEffect);
        [PreserveSig] int DragOver(int grfKeyState, POINTL pt, ref int pdwEffect);
        [PreserveSig] int DragLeave();
        [PreserveSig] int Drop(IDataObject pDataObj, int grfKeyState, POINTL pt, ref int pdwEffect);
    }

    public static class Native
    {
        [DllImport("ole32.dll")] public static extern int OleInitialize(IntPtr r);
        [DllImport("ole32.dll")] public static extern int RegisterDragDrop(IntPtr hwnd,
            [MarshalAs(UnmanagedType.Interface)] IOleDropTarget target);
        [DllImport("ole32.dll")] public static extern int RevokeDragDrop(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClipboardFormatNameW(uint format, StringBuilder name, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern uint RegisterClipboardFormatW(string name);
        [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
        [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
        [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint DragQueryFileW(IntPtr hDrop, uint i, StringBuilder buf, uint cch);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINTL pt);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after,
            int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool ChangeWindowMessageFilterEx(
            IntPtr hwnd, uint message, uint action, IntPtr pChangeFilterStruct);
        [DllImport("shell32.dll")] public static extern void DragAcceptFiles(IntPtr hwnd, bool accept);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINTL pt);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(ref POINTL pt);
        public delegate bool EnumChildProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc cb, IntPtr lp);
        [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassNameW(IntPtr hwnd, StringBuilder buf, int max);

        public static string ClassOf(IntPtr hwnd)
        {
            var sb = new StringBuilder(256);
            GetClassNameW(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public const uint CF_HDROP = 15;
        public const uint CF_UNICODETEXT = 13;
        public const uint CF_TEXT = 1;
    }

    public static class Fmt
    {
        public static string Name(uint cf)
        {
            var sb = new StringBuilder(512);
            int n = Native.GetClipboardFormatNameW(cf, sb, sb.Capacity);
            if (n > 0) return sb.ToString();
            switch (cf)
            {
                case 1: return "CF_TEXT";
                case 2: return "CF_BITMAP";
                case 3: return "CF_METAFILEPICT";
                case 8: return "CF_DIB";
                case 13: return "CF_UNICODETEXT";
                case 15: return "CF_HDROP";
                case 16: return "CF_LOCALE";
                case 17: return "CF_DIBV5";
                default: return "cf#" + cf;
            }
        }

        // THE FORMATS THE RECEIVER ENUMERATES, in the source's own order.
        public static List<string> Enumerate(IDataObject data)
        {
            var outp = new List<string>();
            IEnumFORMATETC en = null;
            try { en = data.EnumFormatEtc(DATADIR.DATADIR_GET); }
            catch (Exception e) { outp.Add("<EnumFormatEtc threw " + e.GetType().Name + ": " + e.Message + ">"); return outp; }
            if (en == null) { outp.Add("<EnumFormatEtc returned null>"); return outp; }
            var one = new FORMATETC[1];
            var got = new int[1];
            while (en.Next(1, one, got) == 0 && got[0] == 1)
            {
                outp.Add(string.Format("{0}(cf={1},tymed={2},aspect={3})",
                    Name((uint)(ushort)one[0].cfFormat), (ushort)one[0].cfFormat,
                    one[0].tymed, one[0].dwAspect));
                if (outp.Count > 64) { outp.Add("<truncated at 64>"); break; }
            }
            return outp;
        }

        static FORMATETC Etc(uint cf, TYMED tymed)
        {
            return new FORMATETC
            {
                cfFormat = (short)cf,
                dwAspect = DVASPECT.DVASPECT_CONTENT,
                lindex = -1,
                ptd = IntPtr.Zero,
                tymed = tymed,
            };
        }

        /// Reads one format's BYTES, or null with the reason on `why`.
        /// ONE TYMED PER CALL, and every attempt reported: asking for
        /// HGLOBAL|ISTREAM at once was refused with E_INVALIDARG by the
        /// WinRT data object (measured 2026-09-03), and a reader that
        /// stopped there would have called a format that IS there absent.
        public static byte[] Bytes(IDataObject data, uint cf, out string why)
        {
            var tried = new List<string>();
            foreach (var t in new[] { TYMED.TYMED_ISTREAM, TYMED.TYMED_HGLOBAL })
            {
                string one;
                var b = BytesOfTymed(data, cf, t, out one);
                if (b != null) { why = null; return b; }
                tried.Add(t + ": " + one);
            }
            why = string.Join("; ", tried);
            return null;
        }

        static byte[] BytesOfTymed(IDataObject data, uint cf, TYMED tymed, out string why)
        {
            why = null;
            var etc = Etc(cf, tymed);
            int q = data.QueryGetData(ref etc);
            if (q != 0) { why = "QueryGetData=0x" + q.ToString("x8"); return null; }
            STGMEDIUM med;
            try { data.GetData(ref etc, out med); }
            catch (Exception e) { why = "GetData threw " + e.GetType().Name + ": " + e.Message; return null; }
            try
            {
                if (med.tymed == TYMED.TYMED_HGLOBAL)
                {
                    IntPtr p = Native.GlobalLock(med.unionmember);
                    if (p == IntPtr.Zero) { why = "GlobalLock failed"; return null; }
                    try
                    {
                        int len = (int)Native.GlobalSize(med.unionmember);
                        var buf = new byte[len];
                        Marshal.Copy(p, buf, 0, len);
                        return buf;
                    }
                    finally { Native.GlobalUnlock(med.unionmember); }
                }
                if (med.tymed == TYMED.TYMED_ISTREAM)
                {
                    var stm = (IStream)Marshal.GetObjectForIUnknown(med.unionmember);
                    // THE STREAM'S OWN SIZE IS READ AND REPORTED: a
                    // handed-over stream can arrive seeked to its end, and
                    // "read 0 bytes" would then be indistinguishable from
                    // "the bridge sent nothing".
                    long size = -1;
                    try { System.Runtime.InteropServices.ComTypes.STATSTG st; stm.Stat(out st, 1); size = st.cbSize; }
                    catch (Exception e) { why = "Stat threw " + e.GetType().Name; }
                    try { stm.Seek(0, 0, IntPtr.Zero); } catch { }
                    var ms = new MemoryStream();
                    var chunk = new byte[4096];
                    IntPtr readPtr = Marshal.AllocHGlobal(4);
                    try
                    {
                        while (true)
                        {
                            stm.Read(chunk, chunk.Length, readPtr);
                            int n = Marshal.ReadInt32(readPtr);
                            if (n <= 0) break;
                            ms.Write(chunk, 0, n);
                            if (ms.Length > 1 << 20) break;
                        }
                    }
                    finally { Marshal.FreeHGlobal(readPtr); }
                    var bytes = ms.ToArray();
                    Log.Line("      (ISTREAM Stat cbSize=" + size + ", read " + bytes.Length + " bytes)");
                    return bytes;
                }
                why = "tymed=" + med.tymed + " (not HGLOBAL or ISTREAM)";
                return null;
            }
            finally { ReleaseStgMedium(ref med); }
        }

        [DllImport("ole32.dll")] static extern void ReleaseStgMedium(ref STGMEDIUM med);

        public static string[] Hdrop(IDataObject data, out string why)
        {
            why = null;
            var etc = Etc(Native.CF_HDROP, TYMED.TYMED_HGLOBAL);
            int q = data.QueryGetData(ref etc);
            if (q != 0) { why = "QueryGetData=0x" + q.ToString("x8"); return null; }
            STGMEDIUM med;
            try { data.GetData(ref etc, out med); }
            catch (Exception e) { why = "GetData threw " + e.GetType().Name; return null; }
            try
            {
                IntPtr h = med.unionmember;
                uint count = Native.DragQueryFileW(h, 0xFFFFFFFF, null, 0);
                var outp = new List<string>();
                for (uint i = 0; i < count && i < 32; i++)
                {
                    var sb = new StringBuilder(1024);
                    Native.DragQueryFileW(h, i, sb, (uint)sb.Capacity);
                    outp.Add(sb.ToString());
                }
                return outp.ToArray();
            }
            finally { ReleaseStgMedium(ref med); }
        }

        public static string Show(byte[] b)
        {
            if (b == null) return "<null>";
            var sb = new StringBuilder();
            sb.Append("len=").Append(b.Length).Append(" hex=");
            for (int i = 0; i < b.Length && i < 24; i++) sb.Append(b[i].ToString("x2"));
            if (b.Length > 24) sb.Append("..");
            sb.Append(" utf8=\"");
            int n = Math.Min(b.Length, 48);
            for (int i = 0; i < n; i++) sb.Append(b[i] >= 32 && b[i] < 127 ? (char)b[i] : '.');
            sb.Append('"');
            return sb.ToString();
        }
    }

    /// The stock reader: an OLE drop target that reports every format it
    /// was offered and the bytes behind the two the probe asks about.
    public class LoggingDropTarget : IOleDropTarget
    {
        public string Tag;
        public string CustomFormat;
        public LoggingDropTarget(string tag, string customFormat) { Tag = tag; CustomFormat = customFormat; }

        const int DROPEFFECT_COPY = 1;

        void Report(string what, IDataObject data)
        {
            if (data == null) { Log.Line(Tag + " " + what + ": pDataObj=NULL"); return; }
            Log.Line(Tag + " " + what + ": formats=[" + string.Join(", ", Fmt.Enumerate(data)) + "]");
        }

        public int DragEnter(IDataObject pDataObj, int grfKeyState, POINTL pt, ref int pdwEffect)
        {
            Log.Line(Tag + " OLE DragEnter at " + pt.x + "," + pt.y + " keys=" + grfKeyState +
                     " allowed=" + pdwEffect);
            Report("OLE DragEnter", pDataObj);
            pdwEffect = DROPEFFECT_COPY;
            return 0;
        }

        int overs;
        POINTL last;
        public int DragOver(int grfKeyState, POINTL pt, ref int pdwEffect)
        {
            overs++;
            last = pt;
            if (overs <= 3 || overs % 10 == 0)
                Log.Line(Tag + " OLE DragOver #" + overs + " at " + pt.x + "," + pt.y +
                         " keys=" + grfKeyState);
            pdwEffect = DROPEFFECT_COPY;
            return 0;
        }

        public int DragLeave()
        {
            // WHERE THE POINTER WAS WHEN IT LEFT: a leave with the cursor
            // still inside the window is a different finding from a leave
            // because the drag moved out, and the two are indistinguishable
            // without this.
            var now = new POINTL();
            Native.GetCursorPos(ref now);
            Log.Line(Tag + " OLE DragLeave after " + overs + " DragOver; last DragOver at " +
                     last.x + "," + last.y + ", cursor now " + now.x + "," + now.y);
            return 0;
        }

        public int Drop(IDataObject pDataObj, int grfKeyState, POINTL pt, ref int pdwEffect)
        {
            Log.Line(Tag + " OLE Drop at " + pt.x + "," + pt.y);
            Report("OLE Drop", pDataObj);
            if (pDataObj != null)
            {
                string why;
                uint cf = Native.RegisterClipboardFormatW(CustomFormat);
                var bytes = Fmt.Bytes(pDataObj, cf, out why);
                Log.Line(Tag + " OLE custom \"" + CustomFormat + "\" (cf=" + cf + "): " +
                         (bytes == null ? "ABSENT (" + why + ")" : Fmt.Show(bytes)));
                uint cf2 = Native.RegisterClipboardFormatW(CustomFormat + ".stream");
                var b2 = Fmt.Bytes(pDataObj, cf2, out why);
                Log.Line(Tag + " OLE custom \"" + CustomFormat + ".stream\" (cf=" + cf2 + "): " +
                         (b2 == null ? "ABSENT (" + why + ")" : Fmt.Show(b2)));
                var txt = Fmt.Bytes(pDataObj, Native.CF_UNICODETEXT, out why);
                Log.Line(Tag + " OLE CF_UNICODETEXT: " +
                         (txt == null ? "ABSENT (" + why + ")" : "\"" +
                          Encoding.Unicode.GetString(txt).TrimEnd('\0') + "\""));
                var files = Fmt.Hdrop(pDataObj, out why);
                Log.Line(Tag + " OLE CF_HDROP: " +
                         (files == null ? "ABSENT (" + why + ")" : files.Length + " path(s): " +
                          string.Join(" | ", files)));
            }
            pdwEffect = DROPEFFECT_COPY;
            Log.Line(Tag + " OLE Drop done");
            return 0;
        }
    }
}

namespace KayaDragProbe.Shared
{
    /// A hand-rolled Win32 OLE data object: exactly the formats the probe
    /// says it offers, each an HGLOBAL, with no toolkit's conversion layer
    /// in between. WinForms' own DataObject would have been shorter, but
    /// it decides for itself how a managed value becomes bytes, and this
    /// probe's whole question is WHICH BYTES CROSS.
    public class SimpleDataObject : IDataObject
    {
        public readonly List<KeyValuePair<uint, byte[]>> Items = new List<KeyValuePair<uint, byte[]>>();

        public void Add(uint cf, byte[] bytes) { Items.Add(new KeyValuePair<uint, byte[]>(cf, bytes)); }

        public int QueryGetData(ref FORMATETC f)
        {
            foreach (var it in Items)
                if ((ushort)f.cfFormat == it.Key && (f.tymed & TYMED.TYMED_HGLOBAL) != 0)
                    return 0;
            return unchecked((int)0x80040064); // DV_E_FORMATETC
        }

        public void GetData(ref FORMATETC f, out STGMEDIUM m)
        {
            m = new STGMEDIUM();
            foreach (var it in Items)
            {
                if ((ushort)f.cfFormat != it.Key) continue;
                IntPtr h = GlobalAlloc(0x0042 /* GMEM_MOVEABLE|GMEM_ZEROINIT */, (UIntPtr)it.Value.Length);
                IntPtr p = Native.GlobalLock(h);
                Marshal.Copy(it.Value, 0, p, it.Value.Length);
                Native.GlobalUnlock(h);
                m.tymed = TYMED.TYMED_HGLOBAL;
                m.unionmember = h;
                m.pUnkForRelease = null;
                return;
            }
            Marshal.ThrowExceptionForHR(unchecked((int)0x80040064));
        }

        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

        public void GetDataHere(ref FORMATETC f, ref STGMEDIUM m)
        { Marshal.ThrowExceptionForHR(unchecked((int)0x80004001)); }
        public int GetCanonicalFormatEtc(ref FORMATETC f, out FORMATETC o)
        { o = f; return 1; /* DATA_S_SAMEFORMATETC */ }
        public void SetData(ref FORMATETC f, ref STGMEDIUM m, bool release)
        { Marshal.ThrowExceptionForHR(unchecked((int)0x80004001)); }
        public IEnumFORMATETC EnumFormatEtc(DATADIR dir)
        {
            if (dir != DATADIR.DATADIR_GET) Marshal.ThrowExceptionForHR(unchecked((int)0x80004001));
            return new SimpleEnum(this);
        }
        public int DAdvise(ref FORMATETC f, ADVF a, IAdviseSink sink, out int conn)
        { conn = 0; return unchecked((int)0x80040003); /* OLE_E_ADVISENOTSUPPORTED */ }
        public void DUnadvise(int conn) { Marshal.ThrowExceptionForHR(unchecked((int)0x80040003)); }
        public int EnumDAdvise(out IEnumSTATDATA e) { e = null; return unchecked((int)0x80040003); }

        class SimpleEnum : IEnumFORMATETC
        {
            readonly SimpleDataObject Owner; int Pos;
            public SimpleEnum(SimpleDataObject o) { Owner = o; }
            public int Next(int celt, FORMATETC[] rgelt, int[] fetched)
            {
                int n = 0;
                while (n < celt && Pos < Owner.Items.Count)
                {
                    rgelt[n] = new FORMATETC
                    {
                        cfFormat = (short)Owner.Items[Pos].Key,
                        dwAspect = DVASPECT.DVASPECT_CONTENT,
                        lindex = -1,
                        ptd = IntPtr.Zero,
                        tymed = TYMED.TYMED_HGLOBAL,
                    };
                    n++; Pos++;
                }
                if (fetched != null && fetched.Length > 0) fetched[0] = n;
                return n == celt ? 0 : 1;
            }
            public int Skip(int celt) { Pos += celt; return Pos <= Owner.Items.Count ? 0 : 1; }
            public int Reset() { Pos = 0; return 0; }
            public void Clone(out IEnumFORMATETC c) { var e = new SimpleEnum(Owner); e.Pos = Pos; c = e; }
        }
    }

    [ComImport, Guid("00000121-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IOleDropSource
    {
        [PreserveSig] int QueryContinueDrag(int fEscapePressed, int grfKeyState);
        [PreserveSig] int GiveFeedback(int dwEffect);
    }

    public class SimpleDropSource : IOleDropSource
    {
        const int S_OK = 0;
        const int DRAGDROP_S_DROP = 0x00040100;
        const int DRAGDROP_S_CANCEL = 0x00040101;
        const int DRAGDROP_S_USEDEFAULTCURSORS = 0x00040102;
        const int MK_LBUTTON = 0x0001;

        public int QueryContinueDrag(int fEscapePressed, int grfKeyState)
        {
            if (fEscapePressed != 0) { Log.Line("src IDropSource: escape -> cancel"); return DRAGDROP_S_CANCEL; }
            if ((grfKeyState & MK_LBUTTON) == 0) { Log.Line("src IDropSource: button up -> drop"); return DRAGDROP_S_DROP; }
            return S_OK;
        }
        public int GiveFeedback(int dwEffect) { return DRAGDROP_S_USEDEFAULTCURSORS; }
    }

    public static class Drag
    {
        [DllImport("ole32.dll")]
        public static extern int DoDragDrop(IDataObject data, IOleDropSource src, int okEffects, out int effect);
    }
}
