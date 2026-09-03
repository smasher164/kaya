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

rootProject.name = "kaya-android"

// :pyhost is one APK carrying every python scene
// (docs/python-mobile-plan.md).
include(":kaya", ":rusthost", ":javahost", ":gohost", ":pyhost")
