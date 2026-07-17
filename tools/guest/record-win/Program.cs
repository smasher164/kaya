// record-win: window-scoped capture of kaya guest windows via
// Windows.Graphics.Capture, for recording mode.
//
//   record-win <outdir>
//
// Why WGC: GDI-family APIs (gdigrab, PrintWindow even with
// PW_RENDERFULLCONTENT, BitBlt) return a blank client area for WinUI's
// DirectComposition content — DComp windows carry
// WS_EX_NOREDIRECTIONBITMAP, so there is no GDI surface to read. WGC
// composites the true DWM output, works over WARP in GPU-less VMs, and
// window scoping makes captures occlusion-proof and crop-free — the
// same shape as the macOS recorder.
//
// Watches for windows titled "kaya*"; while one exists, saves frames
// as <epoch_ms>.png into <outdir> (throttled to ~5 fps). When the
// window closes, goes back to watching — one invocation films every
// serial leg of a suite run. Exits when <outdir>\stop appears. The
// epoch in each filename is this machine's clock, the same clock the
// harness transcripts stamp, so extraction needs no other anchor.
//
// The interop follows robmikh's ManagedScreenshotDemo / CsWinRT
// interop docs verbatim; Vortice supplies D3D11 (no hand-rolled COM
// vtables — the exact code category where guessed slot orders fail).

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

    [DllImport("d3d11.dll", EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice",
        SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    private static extern uint CreateDirect3D11DeviceFromDXGIDevice(
        IntPtr dxgiDevice, out IntPtr graphicsDevice);

    // typeof(GraphicsCaptureItem).GUID is WRONG under CsWinRT (it
    // yields the projected class's guid); the riid must be the
    // interface's, hardcoded — robmikh's samples carry the same note.
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

    private static IntPtr FindKayaWindow()
    {
        var found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString().StartsWith("kaya", StringComparison.OrdinalIgnoreCase))
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
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

        // Hardware first, WARP fallback (the WPFCaptureSample order):
        // in this VM the "GPU" is the Basic Render Driver and WARP is
        // the working path; DWM itself composites via WARP here.
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

        // Vortice's own generic helper casts via GetObjectForIUnknown
        // and breaks under CsWinRT — marshal the raw pointer with
        // MarshalInterface, per Vortice discussion #227.
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
        while (!File.Exists(stopFile))
        {
            var hwnd = FindKayaWindow();
            if (hwnd == IntPtr.Zero)
            {
                Thread.Sleep(100);
                continue;
            }
            try
            {
                CaptureWindow(d3d, device, hwnd, outdir, stopFile);
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"record-win: capture cycle: {e.Message}");
                Thread.Sleep(250);
            }
        }
        return 0;
    }

    private static void CaptureWindow(ID3D11Device d3d, IDirect3DDevice device,
        IntPtr hwnd, string outdir, string stopFile)
    {
        // Screenshot-by-session: on this VM's WARP compositor a
        // capture session delivers exactly ONE frame (the compositor
        // never signals further updates — FrameArrived stays silent
        // and Recreate rejects same-size pools). Attaching a fresh
        // session each cycle reliably yields one frame of the CURRENT
        // composited content, so the recorder polls sessions at ~3fps
        // of true pixels.
        Console.WriteLine($"CAPTURING {hwnd:x}");
        var t0 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        long saved = 0;
        while (IsWindow(hwnd) && !File.Exists(stopFile))
        {
            try
            {
                if (CaptureOneFrame(d3d, device, hwnd, outdir))
                    saved++;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"record-win: shot: {e.Message} (0x{e.HResult:x})");
            }
            Thread.Sleep(150);
        }
        Console.WriteLine($"WINDOW_GONE {hwnd:x} frames_saved={saved} lifetime_ms={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - t0}");
    }

    private static bool CaptureOneFrame(ID3D11Device d3d, IDirect3DDevice device,
        IntPtr hwnd, string outdir)
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
            // The window died between discovery and capture; the
            // caller's IsWindow check ends the cycle.
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
        try
        {
            SaveFrame(d3d, frame, Path.Combine(outdir, $"{now}.png"));
        }
        finally
        {
            frame.Dispose();
        }
        return true;
    }

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
        var ctx = d3d.ImmediateContext;
        ctx.CopyResource(staging, tex);
        var mapped = ctx.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            using var bmp = new System.Drawing.Bitmap(width, height,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            var data = bmp.LockBits(
                new System.Drawing.Rectangle(0, 0, width, height),
                System.Drawing.Imaging.ImageLockMode.WriteOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            // Row by row: RowPitch generally exceeds width*4.
            for (var y = 0; y < height; y++)
            {
                var row = new byte[width * 4];
                Marshal.Copy(mapped.DataPointer + y * (int)mapped.RowPitch, row, 0, row.Length);
                Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
            }
            bmp.UnlockBits(data);
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        finally
        {
            ctx.Unmap(staging, 0);
        }
    }
}
