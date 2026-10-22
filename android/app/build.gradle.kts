import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Real release signing, loaded from android/key.properties (gitignored —
// see android/.gitignore and android/KEYSTORE_SETUP.md).
//
// A release build WITHOUT key.properties fails, on purpose. It used to fall
// back to debug signing with only a log warning, so a release built on a
// machine without the keystore was debug-signed and nothing stopped it being
// handed around or uploaded (security audit, 2026-10-19). A local experiment
// can still ask for the old behaviour explicitly:
//   flutter build apk --release -Pdastavez.allowDebugSigning=true
//
// The check runs when a release artifact is about to be packaged or signed
// (the doFirst below), not while this file is evaluated: evaluation happens
// for every build, so the first version failed every debug and profile build
// on a Mac without the keystore too (found by DAS-109, 2026-10-22).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
val allowDebugSigning = (project.findProperty("dastavez.allowDebugSigning") as String?) == "true"
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.dastavez.bahi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dastavez.bahi"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // End-to-end tests (DAS-109, Patrol). androidTest only: the shipped
        // APK carries none of this. clearPackageData wipes the app's data
        // between tests, so every flow starts as on a fresh install.
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Without the keystore this is the debug key, and the guard below
            // stops a release build before anything is packaged with it.
            signingConfig = if (hasReleaseKeystore) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    testOptions {
        // One process per Patrol test, so a failed test cannot leak state into the next.
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }
}

// The release-keystore guard. Only a task that packages or signs a RELEASE
// artifact carries it, so debug and profile builds never see it.
tasks.configureEach {
    val releaseArtifact = name.contains("Release") &&
        (name.startsWith("package") || name.startsWith("sign") || name.startsWith("bundle"))
    if (releaseArtifact && !hasReleaseKeystore) {
        doFirst {
            if (allowDebugSigning) {
                logger.warn("WARNING: android/key.properties not found — release build is DEBUG-SIGNED because -Pdastavez.allowDebugSigning=true. Never upload this build. See android/KEYSTORE_SETUP.md.")
            } else {
                throw GradleException(
                    "android/key.properties not found: a release build must be signed with the release keystore. " +
                        "See android/KEYSTORE_SETUP.md, or pass -Pdastavez.allowDebugSigning=true for a local, never-uploaded experiment."
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The orchestrator the testOptions above name (Patrol's documented version).
    androidTestUtil("androidx.test:orchestrator:1.5.1")
}
