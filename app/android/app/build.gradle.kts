import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM is opt-in per deployment: the google-services plugin hard-fails the build
// when google-services.json is absent, and the file is environment-specific
// (operator drops it in — see docs FCM relay setup runbook). Apply the plugin
// only when the file is present so a fresh clone / CI still builds; push simply
// stays inert until Firebase is configured.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Load upload-key credentials from key.properties (gitignored; written by CI from secrets).
// Falls back to debug signing when the file is absent (local dev without a keystore).
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().also { if (keyPropsFile.exists()) it.load(keyPropsFile.inputStream()) }

android {
    namespace = "ai.radhaai.antgrid"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // Keep native libs uncompressed and 16 KB zip-aligned in the APK so the
    // installer can mmap them directly on Android 15 16 KB-page devices.
    // Per-lib ELF LOAD-segment alignment is a separate concern (NDK r28+ /
    // upstream prebuilts) — this only governs how they're packed.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    signingConfigs {
        if (keyPropsFile.exists()) {
            create("release") {
                keyAlias = keyProps["keyAlias"] as String
                keyPassword = keyProps["keyPassword"] as String
                storeFile = file(keyProps["storeFile"] as String)
                storePassword = keyProps["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "ai.radhaai.antgrid"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (keyPropsFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
