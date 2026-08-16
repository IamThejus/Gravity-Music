package com.iamthejus.gravitymusic

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val channel = "com.saragama/battery"
    private val installerChannel = "com.saragama/installer"
    private val systemSettingsChannel = "com.saragama/system_settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── In-app updater: install the downloaded APK ──────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("no_path", "APK path missing", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── System settings we can't change ourselves ───────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemSettingsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAccessibilitySettings" -> {
                        openAccessibilitySettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Mono audio is an Android accessibility setting (Settings.Secure
    // "master_mono"). Writing it needs WRITE_SECURE_SETTINGS, a signature
    // permission we can't hold, so the most an app can do is open the screen
    // that owns the switch.
    private fun openAccessibilitySettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            // Some OEM ROMs rename or remove the accessibility activity —
            // fall back to the top-level settings app rather than nothing.
            try {
                startActivity(
                    Intent(Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
            }
        }
    }

    // Android 8+ gates sideloaded installs behind a per-app "install unknown
    // apps" permission; below 8 it's always allowed.
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (_: Exception) {
        }
    }

    // Hand the downloaded APK to the system package installer via a FileProvider
    // content:// URI (a file:// URI throws FileUriExposedException on N+).
    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    // Opens the system "allow this app to ignore battery optimizations?" dialog.
    // The exemption stops Doze from freezing the process and cutting network
    // while the screen is off, which is what stalls streamed playback.
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (isIgnoringBatteryOptimizations()) return
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (e: Exception) {
            // Some OEM ROMs reject the direct request intent — fall back to the
            // battery-optimization settings list so the user can toggle it.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }
}
