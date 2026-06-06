package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
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
    fun collectNetworkInfosReturnsJsonObject() {
        val output = EasyTierNative.collectNetworkInfos(2 * 1024 * 1024)
        val parsed = JSONObject(output)

        assertTrue(parsed.has("map") || parsed.length() == 0)
    }
}
