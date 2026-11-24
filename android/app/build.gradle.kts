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

dependencies {
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
    testImplementation(libs.junit)
}
