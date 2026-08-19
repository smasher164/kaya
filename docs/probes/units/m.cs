using System; using System.Text; using System.Globalization;
class M {
  static void Main() {
    string s1 = "ab😀cd", s2 = "ab👨‍👩‍👧‍👦cd", s3 = "abécd";
    Console.WriteLine("LANG csharp");
    Console.WriteLine("natural_len_S1 " + s1.Length);
    Console.WriteLine("natural_len_S2 " + s2.Length);
    Console.WriteLine("natural_index_cd_S2 " + s2.IndexOf("cd", StringComparison.Ordinal));
    Console.WriteLine("bytes_len_S2 " + Encoding.UTF8.GetByteCount(s2));
    var si = new StringInfo(s2);
    Console.WriteLine("graphemes_len_S2 " + si.LengthInTextElements + " (StringInfo, stdlib)");
    string cut = s1.Substring(0, 3);
    var bytes = Encoding.UTF8.GetBytes(cut);
    Console.WriteLine("split_utf16_S1 len=" + cut.Length + " utf8bytes=" + BitConverter.ToString(bytes)
        + " lone_surrogate=" + char.IsHighSurrogate(cut[2]));
    Console.WriteLine("split_grapheme_S3 " + s3.Substring(0,3).Length);
  }
}
