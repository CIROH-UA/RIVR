# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Mapbox
-keep class com.mapbox.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}
