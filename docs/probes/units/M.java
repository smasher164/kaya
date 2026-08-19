import java.nio.charset.StandardCharsets;
import java.text.BreakIterator;
public class M {
  public static void main(String[] a) {
    String s1 = "ab😀cd", s2 = "ab👨‍👩‍👧‍👦cd", s3 = "abécd";
    System.out.println("LANG java");
    System.out.println("natural_len_S1 " + s1.length());
    System.out.println("natural_len_S2 " + s2.length());
    System.out.println("natural_index_cd_S2 " + s2.indexOf("cd"));
    System.out.println("scalars_len_S2 " + s2.codePointCount(0, s2.length()));
    System.out.println("bytes_len_S2 " + s2.getBytes(StandardCharsets.UTF_8).length);
    String cut = s1.substring(0, 3);
    StringBuilder hex = new StringBuilder();
    for (byte b : cut.getBytes(StandardCharsets.UTF_8)) hex.append(String.format("%02x ", b));
    System.out.println("split_utf16_S1 len=" + cut.length() + " utf8bytes=" + hex
        + " lone_surrogate=" + Character.isHighSurrogate(cut.charAt(2)));
    BreakIterator bi = BreakIterator.getCharacterInstance();
    bi.setText(s2); int n = 0; while (bi.next() != BreakIterator.DONE) n++;
    System.out.println("graphemes_len_S2 " + n + " (java.text.BreakIterator, stdlib)");
    System.out.println("split_grapheme_S3 " + s3.substring(0, 3).length());
  }
}
