import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystoreProperties = Properties()
val releaseKeystorePropertiesFile = rootProject.file("key.properties")
if (releaseKeystorePropertiesFile.exists()) {
    releaseKeystorePropertiesFile.inputStream().use(releaseKeystoreProperties::load)
}
val releaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}
val releaseAbiFilters = listOf("arm64-v8a", "x86_64")
val easyTierProApplicationId = "net.easytier.pro"
if (releaseBuildRequested) {
    val missingReleaseKeys = listOf(
        "storeFile",
        "storePassword",
        "keyAlias",
        "keyPassword",
    ).filter { key -> releaseKeystoreProperties[key]?.toString().isNullOrBlank() }
    if (missingReleaseKeys.isNotEmpty()) {
        throw GradleException(
            "Release signing requires android/key.properties with: ${missingReleaseKeys.joinToString()}",
        )
    }
}

android {
    namespace = "com.example.easytier_pro_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = easyTierProApplicationId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += releaseAbiFilters
        }
    }

    splits {
        abi {
            isEnable = releaseBuildRequested
            reset()
            include(*releaseAbiFilters.toTypedArray())
            isUniversalApk = false
        }
    }

    signingConfigs {
        if (releaseKeystorePropertiesFile.exists()) {
            create("release") {
                storeFile = releaseKeystoreProperties["storeFile"]
                    ?.toString()
                    ?.let { rootProject.file(it) }
                storePassword = releaseKeystoreProperties["storePassword"]?.toString()
                keyAlias = releaseKeystoreProperties["keyAlias"]?.toString()
                keyPassword = releaseKeystoreProperties["keyPassword"]?.toString()
            }
        }
    }

    buildTypes {
        release {
            if (releaseKeystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86/**")
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
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
