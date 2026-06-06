package com.example.easytier_pro_app

object EasyTierAndroidErrorClassifier {
    const val jniUnavailable = "JNI_UNAVAILABLE"
    const val androidRuntimeError = "ANDROID_RUNTIME_ERROR"

    fun code(error: Throwable): String {
        var current: Throwable? = error
        while (current != null) {
            if (isJniUnavailable(current.message.orEmpty())) {
                return jniUnavailable
            }
            current = current.cause
        }
        return androidRuntimeError
    }

    private fun isJniUnavailable(message: String): Boolean {
        return message.contains("Android JNI is unavailable", ignoreCase = true) ||
            message.contains("JNI class is unavailable", ignoreCase = true) ||
            message.contains("JNI receiver is unavailable", ignoreCase = true) ||
            message.contains("JNI method not found", ignoreCase = true) ||
            message.contains("libeasytier_android_jni.so", ignoreCase = true) ||
            message.contains("Build libeasytier_android_jni.so", ignoreCase = true)
    }
}
