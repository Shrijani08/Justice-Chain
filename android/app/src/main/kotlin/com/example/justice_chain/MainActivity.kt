package com.example.justice_chain

import android.content.ComponentName
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }
}
