// record-win <outdir>: window-scoped capture of kaya guest windows via
// Windows.Graphics.Capture. WHY WGC: DComp windows carry
// WS_EX_NOREDIRECTIONBITMAP, so gdigrab/PrintWindow/BitBlt read WinUI's
// client area as blank. Frames are <slot>-<epoch_ms>.png in THIS
// machine's clock, the one the harness transcripts stamp; exits when
// <outdir>\stop appears. The interop follows robmikh's samples.

using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

internal static class Program
{
    private delegate bool EnumProc(IntPtr hwnd, IntPtr lp);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc cb, IntPtr lp);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);

    [DllImport("d3d11.dll", EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice",
        SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    private static extern uint CreateDirect3D11DeviceFromDXGIDevice(
        IntPtr dxgiDevice, out IntPtr graphicsDevice);

    // typeof(GraphicsCaptureItem).GUID is WRONG under CsWinRT (it yields
    // the projected class's guid); the riid must be the interface's.
    private static readonly Guid GraphicsCaptureItemGuid =
        new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    private static readonly Guid ID3D11Texture2DGuid =
        new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    [ComImport]
    [Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [ComVisible(true)]
    private interface IGraphicsCaptureItemInterop
    {
        void CreateForWindow([In] IntPtr window, [In] ref Guid iid, out IntPtr result);
        void CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid, out IntPtr result);
    }

    [ComImport]
    [Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDirect3DDxgiInterfaceAccess
    {
        IntPtr GetInterface([In] ref Guid iid);
    }

    // A GUEST WINDOW IS A WinUI WINDOW, not one whose title starts with
    // "kaya": a scene that titles its own window was filmed NOT AT ALL by
    // the title test, and the leg still passed. The class is the whole
    // identification (this VM runs no other WinUI app); the title test
    // stays for any window a future helper names "kaya*".
    private const string WinUiClass = "WinUIDesktopWin32WindowClass";

    private static List<IntPtr> FindKayaWindows()
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(256);
            GetWindowText(h, sb, 256);
            var cls = new System.Text.StringBuilder(256);
            GetClassName(h, cls, 256);
            if (sb.ToString().StartsWith("kaya", StringComparison.OrdinalIgnoreCase)
                || cls.ToString() == WinUiClass)
                found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The tiling slot rides the window TITLE ("kaya milestone 2 [3]"), so
    // each window's frames carry an unambiguous leg identity.
    private static string WindowSlot(IntPtr hwnd)
    {
        var sb = new System.Text.StringBuilder(256);
        GetWindowText(hwnd, sb, 256);
        var t = sb.ToString();
        var open = t.LastIndexOf('[');
        var close = t.LastIndexOf(']');
        if (open >= 0 && close > open)
            return t.Substring(open + 1, close - open - 1);
        return "0";
    }

    private static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("usage: record-win <outdir>");
            return 2;
        }
        var outdir = args[0];
        Directory.CreateDirectory(outdir);
        var stopFile = Path.Combine(outdir, "stop");

        // Hardware first, WARP fallback: in this VM the "GPU" is the
        // Basic Render Driver and WARP is the working path.
        ID3D11Device d3d;
        var hr = D3D11.D3D11CreateDevice(null, DriverType.Hardware,
            DeviceCreationFlags.BgraSupport, null, out d3d);
        if (hr.Failure)
            hr = D3D11.D3D11CreateDevice(null, DriverType.Warp,
                DeviceCreationFlags.BgraSupport, null, out d3d);
        if (hr.Failure || d3d == null)
        {
            Console.Error.WriteLine($"record-win: no D3D11 device ({hr})");
            return 1;
        }

        // Vortice's generic helper casts via GetObjectForIUnknown and
        // breaks under CsWinRT (Vortice discussion #227).
        using var dxgi = d3d.QueryInterface<IDXGIDevice>();
        var rc = CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspPtr);
        if (rc != 0)
        {
            Console.Error.WriteLine($"record-win: interop device failed (0x{rc:x})");
            return 1;
        }
        var device = MarshalInterface<IDirect3DDevice>.FromAbi(inspPtr);
        Marshal.Release(inspPtr);

        Console.WriteLine("RECORDER_READY");
        // KAYA_RECORD_LANES > 1 puts SEVERAL workers on one window,
        // staggered: a cycle is mostly WAITING, so overlapping cycles is
        // the only way to raise the true frame rate. A WinUI leg is
        // FASTER THAN THE RECORDER — undo_rust's 90 steps run in 313ms,
        // two frames at one lane.
        var lanes = 1;
        if (int.TryParse(Environment.GetEnvironmentVariable("KAYA_RECORD_LANES"),
                out var l) && l >= 1 && l <= 8)
            lanes = l;
        var workers = new Dictionary<IntPtr, List<Thread>>();
        while (!File.Exists(stopFile))
        {
            foreach (var hwnd in FindKayaWindows())
            {
                if (workers.TryGetValue(hwnd, out var ts) && ts.Exists(t => t.IsAlive))
                    continue;
                var started = new List<Thread>();
                for (var i = 0; i < lanes; i++)
                {
                    var lane = i;
                    var thread = new Thread(() =>
                    {
                        try
                        {
                            CaptureWindow(d3d, device, hwnd, outdir, stopFile, lane, lanes);
                        }
                        catch (Exception e)
                        {
                            Console.Error.WriteLine($"record-win: capture cycle: {e.Message}");
                        }
                    });
                    thread.IsBackground = true;
                    thread.Start();
                    started.Add(thread);
                }
                workers[hwnd] = started;
            }
            Thread.Sleep(100);
        }
        foreach (var ts in workers.Values)
            foreach (var t in ts)
                t.Join(2000);
        return 0;
    }

    private static void CaptureWindow(ID3D11Device d3d, IDirect3DDevice device,
        IntPtr hwnd, string outdir, string stopFile, int lane = 0, int lanes = 1)
    {
        // Screenshot-by-session: on this VM's WARP compositor a session
        // delivers exactly ONE frame (FrameArrived then stays silent and
        // Recreate rejects same-size pools), so a fresh session each
        // cycle is what yields the CURRENT composited content.
        var slot = WindowSlot(hwnd);
        var title = new System.Text.StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        var cls = new System.Text.StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        if (lane == 0)
            Console.WriteLine($"CAPTURING {hwnd:x} slot={slot} title=\"{title}\" class={cls} lanes={lanes}");
        // 150ms (~3fps of true pixels): enough for the extractor's
        // covering frame, cheap on a VM running four legs at once.
        var period = 150;
        if (int.TryParse(Environment.GetEnvironmentVariable("KAYA_RECORD_PERIOD_MS"),
                out var p) && p >= 10 && p <= 5000)
            period = p;
        var t0 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        long saved = 0;
        var staggered = lane == 0;
        while (IsWindow(hwnd) && !File.Exists(stopFile))
        {
            var c0 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            try
            {
                if (CaptureOneFrame(d3d, device, hwnd, outdir, slot))
                    saved++;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"record-win: shot: {e.Message} (0x{e.HResult:x})");
            }
            // SPREAD THE LANES OVER A MEASURED CYCLE, not over the
            // sleep: a cycle is the sleep PLUS the session round trip
            // (~90ms here), so staggering by the sleep alone leaves four
            // lanes firing within a few ms of each other.
            if (!staggered)
            {
                var cycle = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - c0 + period;
                Thread.Sleep((int)(cycle * lane / lanes));
                staggered = true;
            }
            Thread.Sleep(period);
        }
        Console.WriteLine($"WINDOW_GONE {hwnd:x} lane={lane} frames_saved={saved} lifetime_ms={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - t0}");
    }

    private static bool CaptureOneFrame(ID3D11Device d3d, IDirect3DDevice device,
        IntPtr hwnd, string outdir, string slot)
    {
        GraphicsCaptureItem item;
        try
        {
            var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
            var iid = GraphicsCaptureItemGuid;
            interop.CreateForWindow(hwnd, ref iid, out var raw);
            item = GraphicsCaptureItem.FromAbi(raw);
            Marshal.Release(raw);
        }
        catch
        {
            // The window died between discovery and capture.
            return false;
        }

        using var got = new ManualResetEventSlim(false);
        Direct3D11CaptureFrame frame = null;
        using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
        pool.FrameArrived += (p, _) =>
        {
            var f = p.TryGetNextFrame();
            if (f == null) return;
            if (Interlocked.CompareExchange(ref frame, f, null) == null)
                got.Set();
            else
                f.Dispose();
        };
        using var session = pool.CreateCaptureSession(item);
        // Win11-only properties; cosmetic if they throw.
        try { session.IsBorderRequired = false; } catch { }
        try { session.IsCursorCaptureEnabled = false; } catch { }
        session.StartCapture();
        if (!got.Wait(1500))
            return false;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var path = ReserveName(outdir, slot, now);
        try
        {
            SaveFrame(d3d, frame, path);
        }
        catch
        {
            // A reserved name never written reaches the film assembly as
            // a zero-byte png.
            try { File.Delete(path); } catch { }
            throw;
        }
        finally
        {
            frame.Dispose();
        }
        return true;
    }

    private static readonly object NameLock = new();

    // <slot>-<epoch_ms>.png is the contract the host-side extraction
    // parses, so a colliding lane takes the next millisecond rather than
    // a suffix. RESERVED, not just checked: the encode comes later, so
    // two lanes would both pass an existence test.
    private static string ReserveName(string outdir, string slot, long now)
    {
        lock (NameLock)
        {
            var path = Path.Combine(outdir, $"{slot}-{now}.png");
            while (File.Exists(path))
                path = Path.Combine(outdir, $"{slot}-{++now}.png");
            File.Create(path).Dispose();
            return path;
        }
    }

    // ID3D11Device is thread-safe; its ImmediateContext is NOT — the
    // per-window workers serialize the copy/map/encode section.
    private static readonly object CtxLock = new();

    private static void SaveFrame(ID3D11Device d3d, Direct3D11CaptureFrame frame, string path)
    {
        // Explicit receiver: both SharpGen (Vortice) and CsWinRT ship
        // an As<T> extension, and the compiler rightly refuses to pick.
        var access = WinRT.CastExtensions.As<IDirect3DDxgiInterfaceAccess>(frame.Surface);
        var iid = ID3D11Texture2DGuid;
        var texPtr = access.GetInterface(ref iid);
        using var tex = new ID3D11Texture2D(texPtr);

        var desc = tex.Description;
        // The pool texture tracks item.Size and can lag a resize; the
        // valid region is ContentSize.
        var width = Math.Min(frame.ContentSize.Width, (int)desc.Width);
        var height = Math.Min(frame.ContentSize.Height, (int)desc.Height);

        using var staging = d3d.CreateTexture2D(new Texture2DDescription
        {
            Width = desc.Width,
            Height = desc.Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = desc.Format,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            BindFlags = BindFlags.None,
            CPUAccessFlags = CpuAccessFlags.Read,
            MiscFlags = ResourceOptionFlags.None,
        });
        // ONLY THE CONTEXT WORK IS SERIALIZED: with the PNG encode inside
        // this lock the lanes convoy and return to the compositor in
        // step, sampling one instant several times over (measured: 40
        // frames arriving as 10 instants).
        var stride = width * 4;
        var pixels = new byte[stride * height];
        lock (CtxLock)
        {
            var ctx = d3d.ImmediateContext;
            ctx.CopyResource(staging, tex);
            var mapped = ctx.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            try
            {
                // Row by row: RowPitch generally exceeds width*4.
                for (var y = 0; y < height; y++)
                    Marshal.Copy(mapped.DataPointer + y * (int)mapped.RowPitch,
                        pixels, y * stride, stride);
            }
            finally
            {
                ctx.Unmap(staging, 0);
            }
        }
        using var bmp = new System.Drawing.Bitmap(width, height,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(
            new System.Drawing.Rectangle(0, 0, width, height),
            System.Drawing.Imaging.ImageLockMode.WriteOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        for (var y = 0; y < height; y++)
            Marshal.Copy(pixels, y * stride, data.Scan0 + y * data.Stride, stride);
        bmp.UnlockBits(data);
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
}
