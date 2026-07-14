// Milestone 1 through the direct ring tier: C# reads the occurrence ring
// with Volatile loads and stores, and answers with packed transaction
// records through kaya_submit. The scene arrives as one transaction; the
// label's text is a signal binding this guest writes on every click.
// P/Invoke is crossed only to start the core, to wait on an empty ring,
// and to submit.
//
// Build the library first (cargo xwin build --release), keep kaya.dll on
// PATH or next to the app, then: dotnet run

using System;
using System.IO;
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
    public static extern void kaya_submit(byte[] records, nuint len);
}

static class Program
{
    const ushort RecButtonClicked = 1;

    // KAYA_TX_* record kinds and value/source tags from kaya.h.
    const ushort TxCreateSignal = 1;
    const ushort TxWriteSignal = 2;
    const ushort TxCreateWidget = 3;
    const ushort TxSetProperty = 4;
    const ushort TxAddChild = 5;
    const ushort TxMount = 6;
    const uint KindColumn = 1;
    const uint KindButton = 2;
    const uint KindLabel = 3;
    const uint PropText = 1;
    const uint SourceConst = 0;
    const uint SourceSignal = 1;
    const uint ValueStr = 4;

    // Guest-allocated ids, counted from 1 per space.
    const ulong SigText = 1;
    const ulong WColumn = 1;
    const ulong WButton = 2;
    const ulong WLabel = 3;

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

    // --- Transaction packing (KAYA_TX_* layouts from kaya.h) -----------

    sealed class Tx
    {
        readonly MemoryStream stream = new();
        readonly BinaryWriter w;

        public Tx() => w = new BinaryWriter(stream); // little-endian

        // Start a record: {u32 size, u16 kind, u16 flags}; the body
        // follows. Returns the record's start for Finish.
        public long Record(ushort kind)
        {
            long start = stream.Position;
            w.Write(0u);
            w.Write(kind);
            w.Write((ushort)0);
            return start;
        }

        public void U32(uint v) => w.Write(v);
        public void U64(ulong v) => w.Write(v);

        public void Str(string s)
        {
            byte[] utf8 = Encoding.UTF8.GetBytes(s);
            w.Write(ValueStr);
            w.Write((uint)utf8.Length);
            w.Write(utf8);
        }

        public void Finish(long start)
        {
            while (stream.Position % 8 != 0)
                w.Write((byte)0);
            long end = stream.Position;
            stream.Position = start;
            w.Write((uint)(end - start));
            stream.Position = end;
        }

        public void Submit()
        {
            byte[] bytes = stream.ToArray();
            Kaya.kaya_submit(bytes, (nuint)bytes.Length);
        }
    }

    static void SceneTx()
    {
        var tx = new Tx();
        long s;

        s = tx.Record(TxCreateSignal); tx.U64(SigText); tx.Str("Clicked 0 times"); tx.Finish(s);
        s = tx.Record(TxCreateWidget); tx.U64(WColumn); tx.U32(KindColumn); tx.U32(0); tx.Finish(s);
        s = tx.Record(TxCreateWidget); tx.U64(WButton); tx.U32(KindButton); tx.U32(0); tx.Finish(s);
        s = tx.Record(TxSetProperty); tx.U64(WButton); tx.U32(PropText); tx.U32(SourceConst); tx.Str("Click me"); tx.Finish(s);
        s = tx.Record(TxCreateWidget); tx.U64(WLabel); tx.U32(KindLabel); tx.U32(0); tx.Finish(s);
        s = tx.Record(TxSetProperty); tx.U64(WLabel); tx.U32(PropText); tx.U32(SourceSignal); tx.U64(SigText); tx.Finish(s);
        s = tx.Record(TxAddChild); tx.U64(WColumn); tx.U64(WButton); tx.Finish(s);
        s = tx.Record(TxAddChild); tx.U64(WColumn); tx.U64(WLabel); tx.Finish(s);
        s = tx.Record(TxMount); tx.U64(0); tx.U64(WColumn); tx.Finish(s); // window 0: the default
        tx.Submit();
    }

    static void WriteTx(string text)
    {
        var tx = new Tx();
        long s = tx.Record(TxWriteSignal);
        tx.U64(SigText);
        tx.Str(text);
        tx.Finish(s);
        tx.Submit();
    }

    static unsafe void App(Kaya.RingInfo info)
    {
        uint* head = (uint*)info.Head;
        uint* tail = (uint*)info.Tail;
        byte* data = (byte*)info.Data;
        uint mask = info.Capacity - 1;

        SceneTx();

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
                WriteTx($"Clicked {count} {noun}");
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
