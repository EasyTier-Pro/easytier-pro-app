package com.example.easytier_pro_app

import android.content.Context
import android.os.Build
import java.util.Locale
import java.util.UUID

object EasyTierAndroidIdentity {
    const val preferencesName = "easytier_core_runtime"
    private const val machineIdKey = "machine_id"

    fun machineId(context: Context): String {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val existing = preferences.getString(machineIdKey, null)?.trim()
        if (!existing.isNullOrEmpty()) {
            return existing
        }
        val generated = UUID.randomUUID().toString()
        preferences.edit().putString(machineIdKey, generated).apply()
        return generated
    }

    fun hostname(): String {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val raw = listOf(manufacturer, model)
            .filter { it.isNotEmpty() }
            .joinToString("-")
            .ifEmpty { "android-device" }
        return sanitizeHostname(raw)
    }

    fun sanitizeHostname(value: String): String {
        return value
            .lowercase(Locale.US)
            .replace(Regex("[^a-z0-9-]+"), "-")
            .trim('-')
            .ifEmpty { "android-device" }
    }
}
