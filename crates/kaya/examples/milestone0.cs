// The milestone-2 scene through the direct ring tier: C# reads the
// occurrence ring with Volatile loads and stores, and answers with
// packed transaction records through kaya_submit. The scene declares a
// When (the extras banner) and a nested For (groups holding items);
// clicks on stamped remove buttons come back as a template node id plus
// key path, and the app answers by removing that entry. P/Invoke is
// crossed only to start the core, to wait on an empty ring, and to
// submit.
//
// Build the library first (cargo xwin build --release), keep kaya.dll on
// PATH or next to the app, then: dotnet run

using System;
using System.Collections.Generic;
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
    const ushort TxCreateCollection = 7;
    const ushort TxCollectionInsert = 8;
    const ushort TxCollectionUpdate = 9;
    const ushort TxCollectionRemove = 10;
    const ushort TxCreateFor = 11;
    const ushort TxCreateWhen = 12;
    const ushort TxTemplateEnd = 13;
    const uint KindColumn = 1;
    const uint KindButton = 2;
    const uint KindLabel = 3;
    const uint PropText = 1;
    const uint SourceConst = 0;
    const uint SourceSignal = 1;
    const uint SourceElement = 2;
    const uint ValueBool = 1;
    const uint ValueStr = 4;

    // Guest-allocated ids, counted from 1 per space.
    const ulong SigStatus = 1;
    const ulong SigExtras = 2;
    const ulong WColumn = 1;
    const ulong WStep = 2;
    const ulong WStatus = 3;
    const ulong WWhen = 4;
    const ulong WGroups = 5;
    const ulong CGroups = 1;
    const ulong CItems = 2;
    const ulong NBanner = 1;
    const ulong NGroupCol = 2;
    const ulong NGroupLbl = 3;
    const ulong NItemsFor = 4;
    const ulong NItemRow = 5;
    const ulong NItemText = 6;
    const ulong NRemove = 7;

    // Mirrors KayaRecordHeader from kaya.h.
    [StructLayout(LayoutKind.Sequential)]
    struct RecordHeader
    {
        public uint Size;
        public ushort Kind;
        public ushort Flags;
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

        void Pad()
        {
            while (stream.Position % 8 != 0)
                w.Write((byte)0);
        }

        // Values are self-padded to 8: they concatenate inside bodies.
        public void Str(string s)
        {
            byte[] utf8 = Encoding.UTF8.GetBytes(s);
            w.Write(ValueStr);
            w.Write((uint)utf8.Length);
            w.Write(utf8);
            Pad();
        }

        public void Bool(bool v)
        {
            w.Write(ValueBool);
            w.Write(1u);
            w.Write((byte)(v ? 1 : 0));
            Pad();
        }

        // A key path: {u32 count, u32 reserved, count values}.
        public void Path(params string[] keys)
        {
            w.Write((uint)keys.Length);
            w.Write(0u);
            foreach (string k in keys)
                Str(k);
        }

        public void Finish(long start)
        {
            Pad();
            long end = stream.Position;
            stream.Position = start;
            w.Write((uint)(end - start));
            stream.Position = end;
        }

        public void Widget(ulong id, uint kind)
        {
            long s = Record(TxCreateWidget); U64(id); U32(kind); U32(0); Finish(s);
        }

        public void TextConst(ulong id, string text)
        {
            long s = Record(TxSetProperty); U64(id); U32(PropText); U32(SourceConst); Str(text); Finish(s);
        }

        public void TextElement(ulong id, uint level)
        {
            long s = Record(TxSetProperty); U64(id); U32(PropText); U32(SourceElement); U32(level); U32(0); Finish(s);
        }

        public void TwoU64(ushort kind, ulong a, ulong b)
        {
            long s = Record(kind); U64(a); U64(b); Finish(s);
        }

        public void Collection(ulong id)
        {
            long s = Record(TxCreateCollection); U64(id); Finish(s);
        }

        public void TemplateEnd()
        {
            long s = Record(TxTemplateEnd); Finish(s);
        }

        public void Insert(ulong coll, string[] at, string key, string value)
        {
            long s = Record(TxCollectionInsert); U64(coll); Path(at); Str(key); Str(value); Finish(s);
        }

        public void Update(ulong coll, string[] at, string key, string value)
        {
            long s = Record(TxCollectionUpdate); U64(coll); Path(at); Str(key); Str(value); Finish(s);
        }

        public void Remove(ulong coll, string[] at, string key)
        {
            long s = Record(TxCollectionRemove); U64(coll); Path(at); Str(key); Finish(s);
        }

        public void WriteStr(ulong sig, string text)
        {
            long s = Record(TxWriteSignal); U64(sig); Str(text); Finish(s);
        }

        public void WriteBool(ulong sig, bool v)
        {
            long s = Record(TxWriteSignal); U64(sig); Bool(v); Finish(s);
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

        s = tx.Record(TxCreateSignal); tx.U64(SigStatus); tx.Str("step 0"); tx.Finish(s);
        s = tx.Record(TxCreateSignal); tx.U64(SigExtras); tx.Bool(false); tx.Finish(s);

        tx.Widget(WColumn, KindColumn);
        tx.Widget(WStep, KindButton);
        tx.TextConst(WStep, "step");
        tx.Widget(WStatus, KindLabel);
        s = tx.Record(TxSetProperty); tx.U64(WStatus); tx.U32(PropText); tx.U32(SourceSignal); tx.U64(SigStatus); tx.Finish(s);

        // When(extras): a banner label. The scope brackets the blueprint.
        tx.TwoU64(TxCreateWhen, WWhen, SigExtras);
        tx.Widget(NBanner, KindLabel);
        tx.TextConst(NBanner, "extras on");
        tx.TemplateEnd();

        // For over groups, nesting a For over items.
        tx.Collection(CGroups);
        tx.TwoU64(TxCreateFor, WGroups, CGroups);
        tx.Widget(NGroupCol, KindColumn);
        tx.Widget(NGroupLbl, KindLabel);
        tx.TextElement(NGroupLbl, 0);
        tx.TwoU64(TxAddChild, NGroupCol, NGroupLbl);
        tx.Collection(CItems);
        tx.TwoU64(TxCreateFor, NItemsFor, CItems);
        tx.Widget(NItemRow, KindColumn);
        tx.Widget(NItemText, KindLabel);
        tx.TextElement(NItemText, 0);
        tx.Widget(NRemove, KindButton);
        tx.TextConst(NRemove, "remove");
        tx.TwoU64(TxAddChild, NItemRow, NItemText);
        tx.TwoU64(TxAddChild, NItemRow, NRemove);
        tx.TemplateEnd();
        tx.TwoU64(TxAddChild, NGroupCol, NItemsFor);
        tx.TemplateEnd();

        tx.TwoU64(TxAddChild, WColumn, WStep);
        tx.TwoU64(TxAddChild, WColumn, WStatus);
        tx.TwoU64(TxAddChild, WColumn, WWhen);
        tx.TwoU64(TxAddChild, WColumn, WGroups);
        tx.TwoU64(TxMount, 0, WColumn); // window 0: the default
        tx.Submit();
    }

    // One click record: header, u64 id, u32 path_len, u32 pad, values.
    static unsafe (ulong id, List<string> keys) ParseClick(byte* rec)
    {
        ulong id = *(ulong*)(rec + 8);
        uint pathLen = *(uint*)(rec + 16);
        var keys = new List<string>();
        int at = 24;
        for (uint i = 0; i < pathLen; i++)
        {
            int vlen = *(int*)(rec + at + 4);
            keys.Add(Encoding.UTF8.GetString(rec + at + 8, vlen));
            at += 8 + ((vlen + 7) & ~7);
        }
        return (id, keys);
    }

    static unsafe void App(Kaya.RingInfo info)
    {
        uint* head = (uint*)info.Head;
        uint* tail = (uint*)info.Tail;
        byte* data = (byte*)info.Data;
        uint mask = info.Capacity - 1;

        SceneTx();

        int steps = 0;
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
                var (id, keys) = ParseClick((byte*)header);
                if (keys.Count == 0 && id == WStep)
                {
                    steps++;
                    var tx = new Tx();
                    if (steps == 1)
                    {
                        tx.Insert(CGroups, Array.Empty<string>(), "g1", "Work");
                        tx.Insert(CItems, new[] { "g1" }, "a", "send report");
                        tx.Insert(CItems, new[] { "g1" }, "b", "buy milk");
                    }
                    else if (steps == 2)
                    {
                        tx.Insert(CGroups, Array.Empty<string>(), "g2", "Home");
                        tx.Insert(CItems, new[] { "g2" }, "a", "water plants");
                        tx.Update(CGroups, Array.Empty<string>(), "g1", "Office");
                    }
                    tx.WriteBool(SigExtras, steps == 1);
                    tx.WriteStr(SigStatus, $"step {steps}");
                    tx.Submit();
                }
                else if (keys.Count == 2 && id == NRemove)
                {
                    var tx = new Tx();
                    tx.Remove(CItems, new[] { keys[0] }, keys[1]);
                    tx.WriteStr(SigStatus, $"removed {keys[0]}/{keys[1]}");
                    tx.Submit();
                }
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
