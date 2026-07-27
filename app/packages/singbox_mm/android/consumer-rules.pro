# Keep gomobile bridge classes/methods required by native libbox.
-keep class go.Seq { *; }
-keep class go.** { *; }
-keep class go.**$* { *; }

# Keep libbox JNI entry points and models from obfuscation/shrinking.
-keep class io.nekohasekai.libbox.** { *; }
-keep class io.nekohasekai.libbox.**$* { *; }

# Same for the Xray core bound alongside it. Its Protector is implemented on
# the Kotlin side and called from Go for every socket the core opens, so R8
# must not rename the interface out from under the native lookup.
-keep class io.nekohasekai.fatxray.** { *; }
-keep class io.nekohasekai.fatxray.**$* { *; }

# Keep plugin-side classes that are invoked from platform services.
-keep class com.signbox.singbox_mm.** { *; }

# Keep native methods signatures intact.
-keepclassmembers class * {
    native <methods>;
}
