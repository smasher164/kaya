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

// :kaya is the library's Kotlin half; :rusthost, :javahost and :gohost
// are the Rust-, JVM- and Go-guest validation apps; :pyhost is the
// python-guest app, one APK carrying every python scene
// (docs/python-mobile-plan.md).
include(":kaya", ":rusthost", ":javahost", ":gohost", ":pyhost")
