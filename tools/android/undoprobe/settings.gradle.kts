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

// A STANDALONE gradle build, deliberately outside android/'s: the probe
// must never be able to affect what the lane ships, and a module in the
// real build is one `assemble` away from doing exactly that.
rootProject.name = "kaya-undo-probe"
include(":app")
