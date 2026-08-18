package dev.kaya.milestone2kt;

import dev.kaya.KayaRing;

/**
 * The desktop twin of the Android shell's MainActivity: load the cdylib
 * (KAYA_LIB when set, the library path otherwise), attach the KayaRing
 * natives, spawn the scene thread, and give the main thread to
 * kaya_run. KAYA_SELFTEST selects the scene; any unrecognized value
 * (including the bare "1" the harness sets) runs milestone2.
 *
 * <p>Same package as the scenes (their app() entries are
 * package-private), different source root: the Android build's srcDirs
 * sweep guests/java wholesale, and this file must never compile there
 * — KayaRing.attach() has no Activity on the desktop.
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
            case "a11y":
                app = A11y::app;
                break;
            case "a11yrows":
                app = A11yRows::app;
                break;
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
            case "filedialog":
                app = FileDialog::app;
                break;
            case "save":
                app = Save::app;
                break;
            case "clipboard":
                app = Clipboard::app;
                break;
            case "nav":
                app = Nav::app;
                break;
            case "background":
                app = Background::app;
                break;
            case "stall":
                app = Stall::app;
                break;
            // One app behind both list-detail scripts.
            case "split":
            case "listdetail":
                app = Split::app;
                break;
            case "scroll":
                app = Scroll::app;
                break;
            case "progress":
                app = Progress::app;
                break;
            case "select":
                app = Select::app;
                break;
            case "radio":
                app = Radio::app;
                break;
            case "grid":
                app = GridScene::app;
                break;
            case "textarea":
                app = TextareaScene::app;
                break;
            case "sections":
                app = Sections::app;
                break;
            case "menus":
                app = Menus::app;
                break;
            case "commands":
                app = Commands::app;
                break;
            case "undo":
                app = Undo::app;
                break;
            case "dirty":
                app = Dirty::app;
                break;
            case "ranges":
                app = Ranges::app;
                break;
            case "styling":
                app = Styling::app;
                break;
            case "toolbar":
                app = Toolbar::app;
                break;
            case "typeface":
                app = Typeface::app;
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
