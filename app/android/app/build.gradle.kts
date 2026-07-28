import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material never enters the repository: android/key.properties
// names the keystore and carries its passwords, and both it and *.jks are
// gitignored (see android/.gitignore). A machine without that file — a fresh
// clone, CI — still builds, falling back to the debug key, because that is what
// `flutter run --release` needs; the fallback only cannot be published.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val releaseKeystore = keystoreProperties.getProperty("storeFile")?.let(::file)
val hasReleaseKeystore = releaseKeystore?.exists() == true

android {
    namespace = "com.fatvpn.fatvpn_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (uses java.time APIs).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fatvpn.fatvpn_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // libbox.so is ~60 MB per ABI, so a universal APK carrying all four lands at
    // ~236 MB — past both Play limits (100 MB APK / 200 MB base module). Split
    // the bundle by ABI so a device downloads only its own; languages stay in
    // the base module because Flutter ships its own localizations and Play's
    // language split would strip the resources it resolves against.
    bundle {
        abi { enableSplit = true }
        density { enableSplit = true }
        language { enableSplit = false }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "No android/key.properties (or its keystore is missing) — " +
                        "signing the release build with the DEBUG key. Such an APK " +
                        "cannot go to Google Play and cannot upgrade a properly " +
                        "signed install.",
                )
                signingConfigs.getByName("debug")
            }
            // Flutter enables R8 for release; make the shrinking explicit and wire
            // our keep rules so Gson generic signatures survive (see
            // proguard-rules.pro — fixes flutter_local_notifications in release).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// x86/x86_64 exist only for emulators and, at ~60 MB of libbox each, were more
// than half the native weight of the build. Dropped from release only, so debug
// still installs on the x86_64 emulator used day to day.
//
// Done here rather than with `ndk { abiFilters }`: the Flutter Gradle plugin
// puts its own ABI list into defaultConfig, and AGP *unions* abiFilters across
// defaultConfig and build types instead of intersecting them — so a filter
// there quietly widens the set rather than narrowing it (verified: the AAB
// still shipped x86_64). The variant packaging API is per-variant and final.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll("**/x86/**", "**/x86_64/**")
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
    // Backport of java.time for flutter_local_notifications on older Android.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
