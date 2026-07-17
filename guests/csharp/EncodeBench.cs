// The encode benchmark: pins "derives target the encoder, not a value
// tree" (DESIGN.md, milestone 3) as a suite leg. Encodes N
// collection_insert records through the generated wire encoder and
// requires a floor rate with ~10x headroom — only a structural
// regression (per-record reflection, tree building) can trip it.

static class EncodeBench
{
    public static void Run()
    {
        const int n = 200_000;
        const int floor = 100_000; // records/second

        var sw = System.Diagnostics.Stopwatch.StartNew();
        long sink = 0;
        for (int i = 0; i < n; i++)
        {
            byte[] rec = KayaWire.TxCollectionInsert(1, System.Array.Empty<object>(),
                $"k{i & 1023}", new object[] { "send report", false });
            sink += rec.Length;
        }
        sw.Stop();

        int rate = (int)(n / sw.Elapsed.TotalSeconds);
        if (rate >= floor)
        {
            System.Console.WriteLine($"ENCODE_BENCH: OK (csharp: {rate} rec/s)");
            _ = sink;
            return;
        }
        System.Console.Error.WriteLine(
            $"ENCODE_BENCH: FAIL (csharp: {rate} rec/s, floor {floor})");
        System.Environment.Exit(1);
    }
}
