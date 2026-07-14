// Milestone 0 through the direct ring tier: C# reads the occurrence ring
// with Volatile loads and stores. P/Invoke is crossed only to start the
// core, to wait on an empty ring, and to send commands.
//
// Build the library first (cargo xwin build --release), keep kaya.dll on
// PATH or next to the app, then: dotnet run

using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class Kaya
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RingInfo
    {
        public IntPtr Data;
        public uint Capacity;
        public IntPtr Head;
        public IntPtr Tail;
    }

    [DllImport("kaya")]
    public static extern int kaya_run();

    [DllImport("kaya")]
    public static extern void kaya_occurrence_ring(out RingInfo info);

    [DllImport("kaya")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool kaya_wait_occurrences();

    [DllImport("kaya")]
    public static extern void kaya_set_text(ulong widgetId, byte[] text, nuint len);
}

static class Program
{
    const ushort RecButtonClicked = 1;
    const ulong LabelWidget = 2;

    // Mirrors KayaRecordHeader / KayaRecordButtonClicked from kaya.h.
    [StructLayout(LayoutKind.Sequential)]
    struct RecordHeader
    {
        public uint Size;
        public ushort Kind;
        public ushort Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RecordButtonClicked
    {
        public RecordHeader Header;
        public ulong WidgetId;
    }

    static unsafe void App(Kaya.RingInfo info)
    {
        uint* head = (uint*)info.Head;
        uint* tail = (uint*)info.Tail;
        byte* data = (byte*)info.Data;
        uint mask = info.Capacity - 1;

        int count = 0;
        uint h = Volatile.Read(ref *head);
        while (true)
        {
            uint t = Volatile.Read(ref *tail); // acquire: records below are visible
            if (h == t)
            {
                if (!Kaya.kaya_wait_occurrences())
                    return; // shutdown
                continue;
            }
            RecordHeader* header = (RecordHeader*)(data + (h & mask));
            if (header->Kind == RecButtonClicked)
            {
                var record = (RecordButtonClicked*)header;
                _ = record->WidgetId;
                count++;
                string noun = count == 1 ? "time" : "times";
                byte[] text = Encoding.UTF8.GetBytes($"Clicked {count} {noun}");
                Kaya.kaya_set_text(LabelWidget, text, (nuint)text.Length);
            }
            h += header->Size;
            Volatile.Write(ref *head, h); // release: hand the space back
        }
    }

    static void Main()
    {
        // On Windows, "kaya" resolves to kaya.dll via PATH. Elsewhere,
        // point KAYA_LIB at the built library (e.g. target/debug/libkaya.dylib).
        NativeLibrary.SetDllImportResolver(typeof(Program).Assembly, (name, _, _) =>
        {
            string env = Environment.GetEnvironmentVariable("KAYA_LIB");
            if (name == "kaya" && env != null && NativeLibrary.TryLoad(env, out IntPtr handle))
                return handle;
            return IntPtr.Zero;
        });

        Kaya.kaya_occurrence_ring(out var info);
        var appThread = new Thread(() => { unsafe { App(info); } });
        appThread.Start();
        int code = Kaya.kaya_run(); // takes over the main thread until the app exits
        appThread.Join();           // shutdown has been signalled; the drain loop ends
        Environment.Exit(code);
    }
}
