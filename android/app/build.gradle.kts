// android/app/build.gradle.kts
// RivrFlow - Upgraded with Firebase, notifications, and production configurations

import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // Firebase Configuration
    id("com.google.gms.google-services")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.byuhydroinformatics.rivr"
    compileSdk = 35 // Updated for latest Firebase and notification support
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Enable core library desugaring for flutter_local_notifications and modern Java features
        isCoreLibraryDesugaringEnabled = true
        
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.byuhydroinformatics.rivr"
        minSdk = 30 // Raised for better performance and modern features
        targetSdk = 35 // Updated for latest Android features and Firebase compatibility
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Enable multidex support for Firebase and other large dependencies
        multiDexEnabled = true
    }

    // Signing configuration for release builds (only if key.properties exists)
    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // Enable BuildConfig generation for environment-specific configurations
    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        getByName("debug") {
            buildConfigField("String", "ENV", "\"development\"")
            isDebuggable = true
            isMinifyEnabled = false
            isShrinkResources = false
        }
        getByName("release") {
            // Only set signing config if key.properties exists
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            buildConfigField("String", "ENV", "\"production\"")
            isMinifyEnabled = true
            isShrinkResources = true
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

dependencies {
    // Core library desugaring for modern Java features and flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    
    // Multidex support for large app with Firebase and other dependencies
    implementation("androidx.multidex:multidex:2.0.1")
    
    // Kotlin standard library
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.10")
}