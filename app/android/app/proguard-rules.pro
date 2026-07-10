# R8/ProGuard keep rules for release builds.
#
# flutter_local_notifications persists scheduled notifications via Gson, which
# reads generic type information (the Signature attribute) at runtime through
# `TypeToken`. R8 strips Signature by default, so without these rules the
# release APK throws "TypeToken must be created with a type argument … make
# sure that generic signatures are preserved" and local expiry reminders break.
# Debug builds don't run R8, which is why this only surfaces in release.
# See: https://github.com/MaikuB/flutter_local_notifications (Gson/ProGuard).

-keepattributes Signature
-keepattributes *Annotation*

# The plugin's own classes are (de)serialized by Gson.
-keep class com.dexterous.** { *; }

# Gson: keep TypeToken generic signatures and adapter/serializer interfaces.
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
-dontwarn sun.misc.**
