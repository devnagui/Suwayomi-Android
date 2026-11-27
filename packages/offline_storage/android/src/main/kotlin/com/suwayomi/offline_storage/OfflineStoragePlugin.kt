package com.suwayomi.offline_storage

import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File

class OfflineStoragePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val dataRoot = binding.applicationContext.applicationInfo.dataDir
        channel = MethodChannel(binding.binaryMessenger, "suwayomi/offline_storage").also {
            it.setMethodCallHandler { call, result ->
                if (call.method != "availableBytes") {
                    result.notImplemented()
                } else {
                    try {
                        val path = call.argument<String>("path")
                            ?: throw IllegalArgumentException()
                        val directory = File(path).canonicalFile
                        val root = File(dataRoot).canonicalFile
                        if (!directory.isDirectory ||
                            !directory.path.startsWith(root.path + File.separator)) {
                            throw IllegalArgumentException()
                        }
                        result.success(StatFs(directory.path).availableBytes)
                    } catch (_: Exception) {
                        result.error("storage_unavailable", "Storage capacity unavailable", null)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
