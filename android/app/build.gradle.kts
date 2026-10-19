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
            signingConfig = when {
                hasReleaseKeystore -> signingConfigs.getByName("release")
                allowDebugSigning -> {
                    logger.warn("WARNING: android/key.properties not found — release build is DEBUG-SIGNED because -Pdastavez.allowDebugSigning=true. Never upload this build. See android/KEYSTORE_SETUP.md.")
                    signingConfigs.getByName("debug")
                }
                else -> throw GradleException(
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
