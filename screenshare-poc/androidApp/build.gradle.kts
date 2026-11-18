plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.kotlinAndroid)
}

android {
    namespace = "com.trackensure.screenshare.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.trackensure.screensharepoc"
        minSdk = 26 // notification channels for the capture notification
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":shared"))
    implementation(libs.livekit.android)
    implementation(libs.kotlinx.coroutines.android)
}
