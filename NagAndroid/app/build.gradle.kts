plugins {
    id("com.android.application")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
}
android {
    namespace = "dev.nag.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.nag.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }
}
dependencies {
    implementation(project(":core"))
    implementation("org.jetbrains.compose.material3:material3:1.9.0")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.glance:glance-appwidget:1.1.1")
}
