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

// A STANDALONE gradle build, deliberately outside android/'s: a
// harness-only APK must never be able to affect what the lane ships, and
// a module in the real build is one `assemble` away from doing exactly
// that.
//
// This one is no longer a throwaway probe — tools/android/run-emulator.sh
// builds it and installs it on every pool device before any leg runs, so
// it is the clipboard scene's foreign app rather than the campaign that
// measured one (docs/clipboard-plan.md §7).
rootProject.name = "kaya-clip-helper"
include(":app")
