import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

/**
 * Embeds Fixtures/conformance/\*.json as string constants so common tests run the same fixtures on
 * every target, including the iOS simulator and Windows, without file access.
 */
abstract class GenerateConformanceFixtures : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fixtures: DirectoryProperty

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun generate() {
        val files = fixtures.get().asFile.listFiles { file -> file.extension == "json" }!!.sortedBy { it.name }
        val body = files.joinToString(",\n") { file ->
            val text = file.readText().replace("$", "\${'$'}")
            "    \"${file.nameWithoutExtension}\" to \"\"\"$text\"\"\""
        }
        val target = output.get().file("nag/rules/ConformanceFixtures.kt").asFile
        target.parentFile.mkdirs()
        target.writeText(
            """
            |// Generated from Fixtures/conformance. Do not edit.
            |package nag.rules
            |
            |internal val conformanceFixtures: Map<String, String> = mapOf(
            |$body,
            |)
            |""".trimMargin(),
        )
    }
}

val generateConformanceFixtures = tasks.register<GenerateConformanceFixtures>("generateConformanceFixtures") {
    fixtures.set(rootProject.layout.projectDirectory.dir("../Fixtures/conformance"))
    output.set(layout.buildDirectory.dir("generated/conformance"))
}

kotlin {
    jvm()

    val xcframework = XCFramework("NagRules")
    listOf(macosArm64(), iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "NagRules"
            // Static keeps the command-line consumer simple. An app with several extensions would
            // weigh this against linking the Kotlin runtime into each extension.
            isStatic = true
            xcframework.add(this)
        }
    }

    // A C ABI for Windows (.dll) and, for local checks of the same bridge, macOS (.dylib).
    mingwX64 { binaries.sharedLib { baseName = "nagrules" } }
    macosArm64 { binaries.sharedLib { baseName = "nagrules" } }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.serialization.json)
        }
        commonTest {
            kotlin.srcDir(generateConformanceFixtures.map { it.output })
            dependencies {
                implementation(kotlin("test"))
            }
        }
    }
}
