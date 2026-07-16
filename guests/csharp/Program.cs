// One guest binary hosts every scene, the Android APK pattern brought
// to the desktop: the KAYA_SELFTEST value doubles as the scene selector
// (and "1", the plain selftest flag, means the milestone-2 scene).
static class Program
{
    static void Main()
    {
        switch (System.Environment.GetEnvironmentVariable("KAYA_SELFTEST"))
        {
            case "entry": EntryScene.Run(); break;
            case "gallery": GalleryScene.Run(); break;
            case "todos": TodosScene.Run(); break;
            default: Milestone2Scene.Run(); break;
        }
    }
}
