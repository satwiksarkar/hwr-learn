# Keep native JNI methods
-keepclasseswithmembernames class * {
    native <methods>;
}

-keep class com.hwrlearn.app.HwrNative { *; }
