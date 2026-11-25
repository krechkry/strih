import java.net.URI
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "cz.krechler.bombocut"
    compileSdk = 36

    defaultConfig {
        applicationId = "cz.krechler.bombocut"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        // phones (64 and 32 bit ARM) and the x86_64 emulator; the old 32-bit x86 emulator is left out
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    sourceSets {
        // the iOS app's strings (English keys, Czech translations), one source for both apps
        getByName("main") { assets.srcDir(layout.buildDirectory.dir("generated/bombo-assets")) }
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}

kotlin {
    jvmToolchain(17)
}

/** Copies Bombocut/Localizable.xcstrings from the iOS app into the assets (read by `loc`). */
val copyStrings by tasks.registering(Copy::class) {
    from(rootProject.file("../Bombocut/Localizable.xcstrings"))
    into(layout.buildDirectory.dir("generated/bombo-assets"))
}
tasks.named("preBuild") { dependsOn(copyStrings) }

/**
 * sherpa-onnx (speech model runtime for captions, Apache 2.0): the release AAR, fetched once into app/libs (52 MB, not
 * in git) and checked by SHA-256, so CI and Android Studio build against the exact same file.
 */
val sherpaVersion = "2.0.3"
val sherpaSha256 = "4c766e2e74c9d33d595338c21fe3b305c73ba45d47e96a235675c33142a2ec50"
val sherpaAar = file("libs/sherpa-onnx-$sherpaVersion.aar")
fun sha256(f: File): String = MessageDigest.getInstance("SHA-256").let { md ->
    f.inputStream().use { i -> val b = ByteArray(1 shl 20); while (true) { val n = i.read(b); if (n < 0) break; md.update(b, 0, n) } }
    md.digest().joinToString("") { "%02x".format(it) }
}
if (!sherpaAar.exists() || sha256(sherpaAar) != sherpaSha256) {
    sherpaAar.parentFile.mkdirs()
    val tmp = File(sherpaAar.path + ".part")
    URI("https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpaVersion/sherpa-onnx-$sherpaVersion.aar")
        .toURL().openStream().use { i -> tmp.outputStream().use { i.copyTo(it) } }
    check(sha256(tmp) == sherpaSha256) { "sherpa-onnx AAR checksum mismatch" }
    tmp.renameTo(sherpaAar)
}

dependencies {
    implementation(files(sherpaAar))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.tooling.preview)
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation(libs.compose.tooling)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.serialization.json)
    implementation(libs.billing)
    testImplementation(libs.junit)
}

// CI log: every unit test with its result (a parity test that skipped for want of fixtures shows as SKIPPED)
tasks.withType<Test>().configureEach {
    testLogging { events("passed", "skipped", "failed") }
}
