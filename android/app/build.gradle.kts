import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing config from key.properties if it exists
val keystoreProperties = Properties()
// rootProject here is `android/`, so this resolves to android/app/key.properties.
// It is gitignored under both spellings; see .gitignore.
val keystorePropertiesFile = rootProject.file("app/key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.surviveai.survive_ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.surviveai.survive_ai"
        minSdk = 24  // Android 7.0 — covers ~98% of active Android devices
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // MediaPipe LLM Inference currently only supports arm64-v8a on Android
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // `abiFilters` above trims Flutter's own engine, but not the native
            // libraries that arrive inside third-party AARs. MediaPipe and ONNX
            // Runtime each ship every ABI, so a build that already declared
            // itself arm64-only was carrying x86_64 and armeabi-v7a copies of
            // both, for architectures it cannot run on. Measured on the CI
            // artifact: 268 MB before, 172 MB after.
            excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Debug signing is a local-development convenience and must never
            // leave this machine. A debug key is the publicly shared Android
            // one, so anything signed with it can be replaced by an "update"
            // from anyone — which for a sideloaded safety app is the whole
            // threat. The release workflow refuses to publish unless a real
            // keystore is present, so this fallback cannot reach a user.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}


