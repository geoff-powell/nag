plugins {
    id("com.android.application")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
}
val sharedConfig = providers.fileContents(rootProject.layout.projectDirectory.file("../Config/Base.xcconfig")).asText
val marketingVersion = sharedConfig.map { config ->
    val assignment = Regex("""MARKETING_VERSION\s*=\s*([0-9]+(?:\.[0-9]+){1,2})""")
    config.lineSequence().firstNotNullOfOrNull { assignment.matchEntire(it.trim())?.groupValues?.get(1) }
        ?: error("Missing MARKETING_VERSION in Config/Base.xcconfig")
}
val androidBuildNumber = providers.gradleProperty("nagAndroidVersionCode").map {
    val code = it.toIntOrNull()
    require(code != null && code in 1..2_100_000_000) { "nagAndroidVersionCode must be between 1 and 2100000000" }
    code
}.orElse(1)

android {
    namespace = "dev.nag.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.nag.android"
        minSdk = 26
        targetSdk = 36
        versionCode = androidBuildNumber.get()
        versionName = marketingVersion.get()
    }
}
dependencies {
    implementation(project(":core"))
    implementation("org.jetbrains.compose.material3:material3:1.9.0")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.glance:glance-appwidget:1.1.1")
}
