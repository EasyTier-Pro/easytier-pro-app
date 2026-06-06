package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.lang.reflect.InvocationTargetException
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierAndroidErrorClassifierInstrumentedTest {
    @Test
    fun classifiesMissingJniAsUnavailable() {
        val error = IllegalStateException(
            "EasyTier Android JNI is unavailable. Build libeasytier_android_jni.so into jniLibs first.",
        )

        assertEquals(
            EasyTierAndroidErrorClassifier.jniUnavailable,
            EasyTierAndroidErrorClassifier.code(error),
        )
    }

    @Test
    fun classifiesNativeStatusFailuresAsRuntimeErrors() {
        val error = IllegalStateException(
            "EasyTier JNI retainNetworkInstance failed: native status -1",
        )

        assertEquals(
            EasyTierAndroidErrorClassifier.androidRuntimeError,
            EasyTierAndroidErrorClassifier.code(error),
        )
    }

    @Test
    fun classifiesWrappedMissingJniAsUnavailable() {
        val error = InvocationTargetException(
            IllegalStateException(
                "EasyTier Android JNI is unavailable. Build libeasytier_android_jni.so into jniLibs first.",
            ),
        )

        assertEquals(
            EasyTierAndroidErrorClassifier.jniUnavailable,
            EasyTierAndroidErrorClassifier.code(error),
        )
    }
}
