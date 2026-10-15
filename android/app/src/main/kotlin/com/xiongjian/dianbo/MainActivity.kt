package com.xiongjian.dianbo

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Flutter 授时页面的音频桥接；窗口和生命周期操作只在主线程执行。 */
class MainActivity : FlutterActivity() {
    private var signalEngine: SignalAudioEngine? = null
    private var signalChannel: MethodChannel? = null
    private var preferencesChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.xiongjian.dianbo/signal")
        signalChannel = channel
        signalEngine = SignalAudioEngine(applicationContext) { status ->
            val active = status["state"] == "running" || status["state"] == "calibrating"
            if (active) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            signalChannel?.invokeMethod("status", status)
        }
        channel.setMethodCallHandler { call, result ->
            val engine = signalEngine
            if (engine == null) result.error("AUDIO_CLOSED", "音频引擎已关闭", null)
            else engine.handle(call, result)
        }
        val preferences = applicationContext.getSharedPreferences("dianbo.preferences", MODE_PRIVATE)
        preferencesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.xiongjian.dianbo/preferences").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(preferences.getString("settings", null))
                    "write" -> {
                        val raw = call.arguments as? String
                        if (raw == null || raw.length > 4096) result.error("PREFERENCES_ARGUMENT", "配置内容无效", null)
                        else { preferences.edit().putString("settings", raw).apply(); result.success(null) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onStop() {
        signalEngine?.stop("应用进入后台，发波已停止")
        window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onStop()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        signalChannel?.setMethodCallHandler(null)
        signalChannel = null
        preferencesChannel?.setMethodCallHandler(null)
        preferencesChannel = null
        signalEngine?.close()
        signalEngine = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
