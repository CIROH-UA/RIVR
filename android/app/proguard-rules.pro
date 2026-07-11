# RIVR — ProGuard / R8 keep rules for release builds.
# Release config: build.gradle.kts uses proguard-android-OPTIMIZE.txt (aggressive)
# + isMinifyEnabled + isShrinkResources, with Dart --obfuscate layered on top.
# Each block below documents WHY the rule exists so future maintainers can
# evaluate whether a dependency upgrade lets us drop it.

# --- Flutter engine + plugin glue (reflection-loaded from Java side) ---
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# --- Firebase: broad keep across all Firebase + GMS surface ---
# firebase_core, firebase_auth, cloud_firestore, firebase_messaging,
# firebase_analytics, firebase_crashlytics all use reflection internally.
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
# Crashlytics ships event delivery via the datatransport library, which lives
# under a different package root than gms.**.
-keep class com.google.android.datatransport.** { *; }

# --- Crashlytics stack-trace readability ---
# Without these, every production crash report has obfuscated class/method
# names AND no line numbers — making Crashlytics nearly useless.
-keepattributes SourceFile,LineNumberTable
-keepattributes *Annotation*
-renamesourcefileattribute SourceFile

# --- Mapbox SDK (native + JNI bridges, vector tile rendering) ---
-keep class com.mapbox.** { *; }

# --- AndroidX startup (Firebase 32+ uses Initializer<T> via the manifest provider) ---
-keep class androidx.startup.** { *; }

# --- flutter_secure_storage: Android Keystore + cipher access via reflection ---
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# --- Play Core stubs referenced by the Flutter engine for deferred components.
# RIVR does not use deferred components, so suppress warnings rather than keep.
-dontwarn com.google.android.play.core.**

# --- Transitive compile-time-only annotations from Google/Firebase deps.
# These show up as R8 warnings; suppressing them prevents strict-mode failures.
-dontwarn javax.annotation.**
-dontwarn javax.lang.model.element.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.codehaus.mojo.animal_sniffer.**

# --- HTTP stack pulled in transitively by Firebase/Mapbox ---
-dontwarn okhttp3.**
-dontwarn okio.**

# --- JNI native method retention ---
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Enum values()/valueOf(): the -optimize variant can rewrite these and
# break any reflection-based enum lookup (e.g., Json (de)serialization paths
# in transitive deps).
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# --- Parcelable CREATOR retention (Bundle marshalling across plugin channels) ---
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator CREATOR;
}
