// One guest binary hosts every scene, the Android APK pattern brought
// to the desktop: the KAYA_SELFTEST value doubles as the scene selector
// (and "1", the plain selftest flag, means the milestone-2 scene).
static class Program
{
    static void Main()
    {
        // Headless invariant checks ride the same binary (the bindings
        // compile into this assembly): KAYA_CHECK selects one, no
        // window, no Run().
        if (System.Environment.GetEnvironmentVariable("KAYA_CHECK") == "abort")
        {
            AbortCheck.Run();
            System.Environment.Exit(0);
        }
        switch (System.Environment.GetEnvironmentVariable("KAYA_SELFTEST"))
        {
            case "a11y": A11yScene.Run(); break;
            case "entry": EntryScene.Run(); break;
            case "gallery": GalleryScene.Run(); break;
            case "todos": TodosScene.Run(); break;
            case "reorder": ReorderScene.Run(); break;
            case "feed": Feed.FeedScene.Run(); break;
            case "align": AlignScene.Run(); break;
            case "window": WindowScene.Run(); break;
            case "panels": PanelsScene.Run(); break;
            case "nav": NavScene.Run(); break;
            case "background": BackgroundScene.Run(); break;
            case "stall": StallScene.Run(); break;
            case "split": SplitScene.Run(); break;
            case "listdetail": SplitScene.Run(); break;
            case "scroll": ScrollScene.Run(); break;
            case "progress": ProgressScene.Run(); break;
            case "select": SelectScene.Run(); break;
            case "radio": RadioScene.Run(); break;
            case "grid": GridScene.Run(); break;
            case "textarea": TextareaScene.Run(); break;
            case "sections": SectionsScene.Run(); break;
            case "menus": MenusScene.Run(); break;
            case "commands": CommandsScene.Run(); break;
            case "confirm": ConfirmScene.Run(); break;
            case "filedialog": FileDialogScene.Run(); break;
            case "clipboard": ClipboardScene.Run(); break;
            case "undo": UndoScene.Run(); break;
            case "dirty": DirtyScene.Run(); break;
            case "grow": GrowScene.Run(); break;
            case "layout": LayoutScene.Run(); break;
            case "encodebench": EncodeBench.Run(); break;
            default: Milestone2Scene.Run(); break;
        }
    }
}
