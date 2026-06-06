package com.example.easytier_pro_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierServiceEventBufferInstrumentedTest {
    @Test
    fun drainsBufferedEventsInArrivalOrder() {
        val buffer = EasyTierServiceEventBuffer(maxSize = 3)
        val first = event("config_server_started")
        val second = event("config_server")
        val third = event("vpn_started")

        assertFalse(buffer.add(first))
        assertFalse(buffer.add(second))
        assertFalse(buffer.add(third))

        assertEquals(listOf(first, second, third), buffer.drain())
        assertEquals(emptyList<Map<String, Any?>>(), buffer.drain())
    }

    @Test
    fun dropsOldestEventWhenBufferIsFull() {
        val buffer = EasyTierServiceEventBuffer(maxSize = 2)
        val first = event("first")
        val second = event("second")
        val third = event("third")

        assertFalse(buffer.add(first))
        assertFalse(buffer.add(second))
        assertTrue(buffer.add(third))

        assertEquals(listOf(second, third), buffer.drain())
    }

    @Test
    fun rejectsNonPositiveBufferSize() {
        try {
            EasyTierServiceEventBuffer(maxSize = 0)
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty().contains("maxSize"))
            return
        }
        throw AssertionError("Expected IllegalArgumentException for maxSize=0")
    }

    private fun event(type: String): Map<String, Any?> {
        return mapOf(
            "type" to type,
            "payload" to mapOf("type" to type),
        )
    }
}
