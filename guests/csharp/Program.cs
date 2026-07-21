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
            case "entry": EntryScene.Run(); break;
            case "gallery": GalleryScene.Run(); break;
            case "todos": TodosScene.Run(); break;
            case "reorder": ReorderScene.Run(); break;
            case "feed": Feed.FeedScene.Run(); break;
            case "align": AlignScene.Run(); break;
            case "grow": GrowScene.Run(); break;
            case "layout": LayoutScene.Run(); break;
            case "encodebench": EncodeBench.Run(); break;
            default: Milestone2Scene.Run(); break;
        }
    }
}
