package com.example.justice_chain

import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keeps the app's content out of the recent-apps preview and out of
        // screenshots. Debug builds skip it so the team can take screenshots.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    /**
     * One engine for the whole process, kept when the screen closes, so the
     * AI, recording and uploads in Dart go on after Sakshya is swiped away
     * while ProtectionService holds the process. Reopening the app attaches
     * to the same running engine instead of starting main() again.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineCache.getInstance().get(ENGINE_ID)
            ?: FlutterEngine(context.applicationContext).also { FlutterEngineCache.getInstance().put(ENGINE_ID, it) }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Background protection (ProtectionService). The application context,
        // because the engine outlives this activity.
        val app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.sakshya/protection")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            ProtectionService.start(app, call.argument<Boolean>("disguised") == true)
                            result.success(true)
                        }
                        "stop" -> {
                            ProtectionService.stop(app)
                            result.success(true)
                        }
                        "setDisguised" -> {
                            ProtectionService.setDisguised(call.argument<Boolean>("disguised") == true)
                            result.success(true)
                        }
                        "isRunning" -> result.success(ProtectionService.running)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // E.g. ForegroundServiceStartNotAllowedException when asked from the background.
                    result.error("protection_failed", e.toString(), null)
                }
            }
        // Disguise mode: which launcher face (AndroidManifest.xml) is shown.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.sakshya/disguise")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLauncherFace" -> result.success(launcherFace())
                    "setLauncherFace" -> {
                        val face = call.argument<String>("face")
                        if (face != SAKSHYA && face != CALCULATOR) {
                            result.error("bad_face", "Unknown launcher face: $face", null)
                        } else {
                            setLauncherFace(face)
                            result.success(launcherFace())
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun component(name: String) =
        ComponentName(packageName, "${MainActivity::class.java.`package`!!.name}.$name")

    private fun isEnabled(name: String, enabledByDefault: Boolean): Boolean =
        when (packageManager.getComponentEnabledSetting(component(name))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> enabledByDefault
            else -> false
        }

    private fun launcherFace(): String =
        if (isEnabled("CalculatorFace", false) && !isEnabled("SakshyaFace", true)) CALCULATOR else SAKSHYA

    /** Enables the new face before disabling the old one, so there is always a launcher entry. */
    private fun setLauncherFace(face: String) {
        val (show, hide) =
            if (face == CALCULATOR) "CalculatorFace" to "SakshyaFace" else "SakshyaFace" to "CalculatorFace"
        packageManager.setComponentEnabledSetting(
            component(show), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        packageManager.setComponentEnabledSetting(
            component(hide), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
    }

    private companion object {
        const val SAKSHYA = "sakshya"
        const val CALCULATOR = "calculator"
        const val ENGINE_ID = "sakshya_main"
    }
}
