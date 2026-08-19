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
rootProject.name = "kaya-picker-probe"
include(":app")
