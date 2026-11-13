package com.example.skilltrack

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import android.provider.Settings
import android.util.AtomicFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity() {
    // Not restored by Android backup: another installation performs its own check.
    private fun stateFile() = AtomicFile(File(noBackupFilesDir, "notification_onboarding.json"))
    private fun readState(): JSONObject {
        val file = stateFile()
        return if (file.baseFile.exists()) JSONObject(String(file.readFully(), Charsets.UTF_8)) else JSONObject()
    }
    private fun saveState(state: JSONObject) {
        val file = stateFile()
        val stream = file.startWrite()
        try { stream.write(state.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "skilltrack/notification_permission")
            .setMethodCallHandler { call, result ->
                try {
                    val state = readState()
                    when (call.method) {
                        "status" -> {
                            val manager = getSystemService(NotificationManager::class.java)
                            val runtime = Build.VERSION.SDK_INT >= 33
                            val granted = manager.areNotificationsEnabled() && (!runtime ||
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
                            val rationale = runtime && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
                            val requests = state.optInt("requests", 0)
                            // Firebase denied is ambiguous. Persist requests, bound retries,
                            // and consult Android's current rationale signal instead.
                            val canRequest = runtime && !granted && (requests == 0 || (requests < 2 && rationale))
                            val user = call.argument<String>("user") ?: ""
                            result.success(mapOf("granted" to granted, "canRequest" to canRequest,
                                "handled" to state.optBoolean("handled"), "optedOut" to state.optBoolean("optout:$user")))
                        }
                        "handled" -> { state.put("handled", true); saveState(state); result.success(null) }
                        "requested" -> { state.put("handled", true); state.put("requests", state.optInt("requests", 0) + 1); saveState(state); result.success(null) }
                        "choice" -> {
                            val user = call.argument<String>("user") ?: throw IllegalArgumentException()
                            state.put("handled", true); state.put("optout:$user", call.argument<Boolean>("enabled") != true)
                            saveState(state); result.success(null)
                        }
                        "settings" -> {
                            val intent = if (Build.VERSION.SDK_INT >= 26) {
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            } else {
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                            }
                            startActivity(intent)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) { result.error("notification_settings_unavailable", "Unable to check notification settings.", null) }
            }
    }
}
