// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Built-in Kotlin compiles the Kotlin sources; no kotlin-android plugin.
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// rootProject is android/android; the Rust workspace and scripts are at the repo root.
val repoRoot = rootProject.projectDir.parentFile.parentFile
val rustBackendDir = repoRoot.resolve("rust_backend")
val supportedRustAndroidAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
val rustAndroidAbis = providers.environmentVariable("KALAO_RUST_ANDROID_ABIS")
    .orElse(supportedRustAndroidAbis.joinToString(","))
    .get()
    .split(",")
require(rustAndroidAbis.size == rustAndroidAbis.toSet().size) {
    "KALAO_RUST_ANDROID_ABIS must not contain duplicate ABIs"
}
require(rustAndroidAbis.all { it in supportedRustAndroidAbis }) {
    "KALAO_RUST_ANDROID_ABIS must contain only $supportedRustAndroidAbis"
}

android {
    namespace = "com.brinsley.kalao"
    compileSdk = 37
    ndkVersion = "30.0.16248370"

    buildFeatures {
        buildConfig = true
    }

    sourceSets.getByName("main") {
        // Built-in Kotlin compiles only kotlin source directories.
        kotlin.directories += "src/rust/kotlin"
        kotlin.directories += rustBackendDir.resolve("target/bindings/kotlin").path
        jniLibs.srcDir(rustBackendDir.resolve("target/android/jniLibs"))
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_25
        targetCompatibility = JavaVersion.VERSION_25
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = true
            }
        }
    }

    defaultConfig {
        applicationId = "com.brinsley.kalao"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        minSdk = 26
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters += rustAndroidAbis
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // Local builds sign with key.properties when present; CI signs the
            // unsigned release APKs in release.yml.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            include(*rustAndroidAbis.toTypedArray())
            isUniversalApk = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_25)
    }
}

val buildRustBackend = tasks.register<Exec>("buildRustBackend") {
    workingDir(repoRoot)
    commandLine("bash", "scripts/build_rust_backend.sh", "android")
    environment("KALAO_RUST_ANDROID_ABIS", rustAndroidAbis.joinToString(","))
    environment(
        "ANDROID_NDK_HOME",
        System.getenv("ANDROID_NDK_HOME")
            ?: android.sdkDirectory.resolve("ndk/30.0.16248370").absolutePath,
    )
    inputs.files(fileTree(rustBackendDir) {
        include("**/*.rs", "**/*.toml", "**/*.lock", "**/*.tsv", "**/*.pem")
        exclude("target/**")
    })
    inputs.property("KALAO_RUST_ANDROID_ABIS", rustAndroidAbis.joinToString(","))
    inputs.file(repoRoot.resolve("scripts/build_rust_backend.sh"))
    outputs.dir(rustBackendDir.resolve("target/bindings/kotlin"))
    outputs.dir(rustBackendDir.resolve("target/android/jniLibs"))
}
tasks.named("preBuild").configure { dependsOn(buildRustBackend) }

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("net.java.dev.jna:jna:5.19.1@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("androidx.core:core-ktx:1.17.0")

    testImplementation("junit:junit:4.13.2")
}
