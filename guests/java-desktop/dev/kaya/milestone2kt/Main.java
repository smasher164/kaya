package dev.kaya.milestone2kt;

import dev.kaya.KayaRing;

/**
 * The desktop twin of the Android shell's MainActivity: load the
 * cdylib (KAYA_LIB's absolute path when set, the library path
 * otherwise — the same resolution the C# guests use), attach the
 * KayaRing natives, spawn the scene thread, and give the main thread
 * to kaya_run. Same package as the scenes (their app() entries are
 * package-private), different source root: the Android build's
 * srcDirs sweep guests/java wholesale, and this file must never
 * compile there (KayaRing.attach() has no Activity on the desktop).
 *
 * KAYA_SELFTEST selects the scene exactly as on Android; any
 * unrecognized value (including the bare "1" the harness sets by
 * default) runs milestone2.
 */
public final class Main {
    public static void main(String[] args) {
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();

        String scene = System.getenv("KAYA_SELFTEST");
        Runnable app;
        switch (scene == null ? "" : scene) {
            case "entry":
                app = Entry::app;
                break;
            case "gallery":
                app = Gallery::app;
                break;
            case "todos":
                app = Todos::app;
                break;
            case "reorder":
                app = Reorder::app;
                break;
            case "feed":
                app = Feed::app;
                break;
            case "align":
                app = Align::app;
                break;
            case "grow":
                app = Grow::app;
                break;
            case "layout":
                app = Layout::app;
                break;
            case "window":
                app = Window::app;
                break;
            case "panels":
                app = Panels::app;
                break;
            case "confirm":
                app = Confirm::app;
                break;
            case "nav":
                app = Nav::app;
                break;
            case "scroll":
                app = Scroll::app;
                break;
            case "progress":
                app = Progress::app;
                break;
            default:
                app = Milestone2::app;
                break;
        }
        new Thread(app, "kaya-app").start();
        System.exit(KayaRing.run());
    }

    private Main() {}
}
