package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.lang.reflect.InvocationTargetException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierNativeInstrumentedTest {
    @Test
    fun androidIdentityPersistsMachineId() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context
            .getSharedPreferences(EasyTierAndroidIdentity.preferencesName, 0)
            .edit()
            .clear()
            .commit()

        val first = EasyTierAndroidIdentity.machineId(context)
        val second = EasyTierAndroidIdentity.machineId(context)

        assertTrue(first.isNotBlank())
        assertEquals(first, second)
    }

    @Test
    fun androidIdentitySanitizesHostname() {
        assertEquals(
            "android-phone-01",
            EasyTierAndroidIdentity.sanitizeHostname(" Android Phone 01 "),
        )
        assertEquals("android-device", EasyTierAndroidIdentity.sanitizeHostname(" --- "))
    }

    @Test
    fun loadsEasyTierJniAndReadsBasicState() {
        assertFalse(EasyTierNative.isConfigServerClientConnected())
        assertNotNull(EasyTierNative.getLastError())
    }

    @Test
    fun listInstancesReturnsJsonObject() {
        val output = EasyTierNative.listInstances(64)
        val parsed = JSONObject(output)

        assertNotNull(parsed)
    }

    @Test
    fun callJsonRpcMethodIsAvailable() {
        val output = try {
            EasyTierNative.callJsonRpc(
                "api.instance.PeerManageRpcService",
                "show_node_info",
                null,
                "{}",
            )
        } catch (error: IllegalStateException) {
            assertTrue(error.message.orEmpty().isNotBlank())
            return
        }

        assertNotNull(JSONObject(output))
    }

    @Test
    fun stopAllInstancesIsAvailable() {
        EasyTierNative.stopAllInstances()
    }

    @Test
    fun unwrapsReflectedNativeExceptions() {
        val invoke = EasyTierNative::class.java.getDeclaredMethod(
            "invoke",
            java.lang.reflect.Method::class.java,
            Array<Any?>::class.java,
        )
        invoke.isAccessible = true
        val throwingMethod = ThrowingNativeMethods::class.java.getDeclaredMethod(
            "throwNativeError",
        )

        try {
            invoke.invoke(EasyTierNative, throwingMethod, emptyArray<Any?>())
            fail("Expected native exception")
        } catch (error: InvocationTargetException) {
            assertTrue(error.targetException is IllegalStateException)
            assertEquals(
                "EasyTier JNI setTunFd failed: native status -7",
                error.targetException.message,
            )
        }
    }

    private object ThrowingNativeMethods {
        @JvmStatic
        fun throwNativeError() {
            throw IllegalStateException("EasyTier JNI setTunFd failed: native status -7")
        }
    }
}
