package com.example.easytier_pro_app

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.zip.ZipFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EasyTierAndroidManifestInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val packageManager = context.packageManager

    @Test
    fun packageIdentityMatchesReleaseApplicationId() {
        assertEquals("net.easytier.pro", context.packageName)
    }

    @Test
    fun debugBuildAllowsLocalE2eCleartextHttp() {
        val applicationInfo = packageManager.getApplicationInfo(context.packageName, 0)

        assertTrue(
            applicationInfo.flags and ApplicationInfo.FLAG_USES_CLEARTEXT_TRAFFIC != 0,
        )
    }

    @Test
    fun packagesEasyTierJniForCurrentDeviceAbi() {
        val libraryName = "libeasytier_android_jni.so"
        val library = File(
            context.applicationInfo.nativeLibraryDir,
            libraryName,
        )
        if (library.isFile && library.length() > 0) {
            return
        }

        val expectedEntries = Build.SUPPORTED_ABIS
            .map { abi -> "lib/$abi/$libraryName" }
            .toSet()
        val apkFiles = listOf(context.applicationInfo.sourceDir) +
            context.applicationInfo.splitSourceDirs.orEmpty()
        val packaged = apkFiles.any { apkPath ->
            ZipFile(apkPath).use { apk ->
                expectedEntries.any { entry -> apk.getEntry(entry) != null }
            }
        }

        assertTrue(
            "Expected packaged JNI library in ${apkFiles.joinToString()} for ${Build.SUPPORTED_ABIS.joinToString()}",
            packaged,
        )
    }

    @Test
    fun declaresAndroidVpnPermissions() {
        val packageInfo = packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        val permissions = packageInfo.requestedPermissions?.toSet().orEmpty()

        assertTrue(permissions.contains(Manifest.permission.INTERNET))
        assertTrue(permissions.contains(Manifest.permission.ACCESS_NETWORK_STATE))
        assertTrue(permissions.contains(Manifest.permission.FOREGROUND_SERVICE))
        assertTrue(permissions.contains(Manifest.permission.POST_NOTIFICATIONS))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            assertTrue(permissions.contains(Manifest.permission.FOREGROUND_SERVICE_SPECIAL_USE))
        }
    }

    @Test
    fun declaresNonExportedVpnService() {
        val service = vpnServiceInfo()

        assertEquals(Manifest.permission.BIND_VPN_SERVICE, service.permission)
        assertFalse(service.exported)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            assertTrue(
                service.foregroundServiceType and
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE != 0,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            assertEquals(
                "User-visible EasyTier Pro VPN tunnel",
                packageManager.getProperty(
                    PackageManager.PROPERTY_SPECIAL_USE_FGS_SUBTYPE,
                    ComponentName(context, EasyTierVpnService::class.java),
                ).string,
            )
        }
    }

    @Test
    fun vpnServiceHandlesAndroidVpnAction() {
        val services = packageManager.queryIntentServices(
            Intent(VpnService.SERVICE_INTERFACE).setPackage(context.packageName),
            0,
        )

        assertTrue(
            services.any {
                it.serviceInfo.name == "com.example.easytier_pro_app.EasyTierVpnService"
            },
        )
    }

    @Test
    fun vpnServiceOverridesSystemRevokeCleanupHook() {
        val method = EasyTierVpnService::class.java.getDeclaredMethod("onRevoke")

        assertEquals(EasyTierVpnService::class.java, method.declaringClass)
    }

    @Test
    fun vpnPermissionFlowCanBePrepared() {
        val consentIntent = VpnService.prepare(context)
        if (consentIntent != null) {
            assertTrue(packageManager.queryIntentActivities(consentIntent, 0).isNotEmpty())
        }
    }

    private fun vpnServiceInfo(): ServiceInfo {
        val packageInfo = packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_SERVICES,
        )
        return packageInfo.services.orEmpty().first {
            it.name == "com.example.easytier_pro_app.EasyTierVpnService"
        }
    }
}
