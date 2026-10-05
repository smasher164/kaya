package dev.kaya;

public final class TimecodeCheck {
    private static void publicNull() {
        try {
            KayaApp.fmt().parseTimecode(null, new KayaApp.TimecodeRate(25, 1, false));
            throw new AssertionError("null timecode text was accepted");
        } catch (NullPointerException e) {
            if (!"kaya: fmt.parseTimecode needs text".equals(e.getMessage())) {
                throw new AssertionError("null timecode refusal did not name text", e);
            }
        } catch (UnsatisfiedLinkError e) {
            throw new AssertionError("null timecode text reached JNI", e);
        }
    }

    public static void main(String[] args) {
        publicNull();
        if (args.length > 0 && args[0].equals("--native")) {
            System.load(System.getenv("KAYA_LIB"));
            KayaRing.attach();
            try {
                KayaRing.fmtParseTimecode(null, 25, 1, false);
                throw new AssertionError("JNI null timecode did not report its read failure");
            } catch (IllegalArgumentException e) {
                if (!e.getMessage().startsWith("kaya: reading timecode text failed: ")) {
                    throw new AssertionError("JNI timecode read failure lost its measured cause", e);
                }
                System.out.println("timecode-check: native read failure: " + e.getMessage());
            }
            if (KayaRing.fmtParseTimecode("00:00:00:00\u0000ignored", 25, 1, false) != -1) {
                throw new AssertionError("JNI timecode truncated embedded NUL");
            }
        }
        System.out.println("timecode-check: OK");
    }
    private TimecodeCheck() {}
}
