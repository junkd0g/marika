plugins {
    kotlin("jvm") version "2.3.10"
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.10"
    id("org.jetbrains.compose") version "1.10.2"
    application
}
repositories { google(); mavenCentral() }
dependencies {
    implementation(compose.desktop.currentOs)
    implementation("org.jetbrains.compose.material:material:1.10.2")
}
application { mainClass.set("ComposeReferenceKt") }
tasks.named<JavaExec>("run") {
    args(providers.gradleProperty("referencePath").orNull ?: error("Set -PreferencePath=<output PNG>"))
}
