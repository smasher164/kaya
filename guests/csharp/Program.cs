// The one guest binary's scene selector: KAYA_SELFTEST names the scene,
// KAYA_CHECK the headless invariant check.
static class Program
{
    // WinUI 3 hosts its UI on a single-threaded COM apartment, and the OLE
    // drag route (docs/dnd-plan.md §5, D10) needs it too — OleInitialize
    // returns RPC_E_CHANGED_MODE on the default MTA main thread and the
    // drag's modal loop never runs. The framework's own generated Main
    // carries this; kaya's hand-rolled one must too.
    [System.STAThread]
    static void Main()
    {
        if (System.Environment.GetEnvironmentVariable("KAYA_CHECK") == "abort")
        {
            AbortCheck.Run();
            System.Environment.Exit(0);
        }
        switch (System.Environment.GetEnvironmentVariable("KAYA_SELFTEST"))
        {
            case "a11y": A11yScene.Run(); break;
            case "a11yrows": A11yrowsScene.Run(); break;
            case "entry": EntryScene.Run(); break;
            case "gallery": GalleryScene.Run(); break;
            case "todos": TodosScene.Run(); break;
            case "reorder": ReorderScene.Run(); break;
            case "table": TableScene.Run(); break;
            case "feed": Feed.FeedScene.Run(); break;
            case "align": AlignScene.Run(); break;
            case "window": WindowScene.Run(); break;
            case "panels": PanelsScene.Run(); break;
            case "nav": NavScene.Run(); break;
            case "background": BackgroundScene.Run(); break;
            case "stall": StallScene.Run(); break;
            case "split": SplitScene.Run(); break;
            case "panes": PanesScene.Run(); break;
            case "pickers": PickersScene.Run(); break;
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
            case "save": SaveScene.Run(); break;
            case "clipboard": ClipboardScene.Run(); break;
            case "undo": UndoScene.Run(); break;
            case "dirty": DirtyScene.Run(); break;
            case "dnd": DndScene.Run(); break;
            case "ranges": RangesScene.Run(); break;
            case "grow": GrowScene.Run(); break;
            case "layout": LayoutScene.Run(); break;
            case "styling": StylingScene.Run(); break;
            case "toolbar": ToolbarScene.Run(); break;
            case "typeface": TypefaceScene.Run(); break;
            case "identity": IdentityScene.Run(); break;
            case "assets": AssetsScene.Run(); break;
            case "sizepolicy": SizepolicyScene.Run(); break;
            case "adaptive": AdaptiveScene.Run(); break;
            case "encodebench": EncodeBench.Run(); break;
            default: Milestone2Scene.Run(); break;
        }
    }
}
