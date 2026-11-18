rootProject.name = "screenshare-poc"

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        // LiveKit Android depends on com.github.davidliu:audioswitch, published only there.
        maven("https://jitpack.io") { content { includeGroup("com.github.davidliu") } }
    }
}

include(":shared", ":androidApp")
