pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// STANDALONE, deliberately outside android/'s build: a module in the
// real build is one `assemble` away from affecting what the lane ships.
// Not a throwaway probe — tools/android/run-emulator.py installs this on
// every pool device as the clipboard scene's foreign app
// (docs/clipboard-plan.md §7).
rootProject.name = "kaya-clip-helper"
include(":app")
