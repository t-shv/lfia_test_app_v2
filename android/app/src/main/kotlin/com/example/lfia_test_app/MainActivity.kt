package com.example.lfia_test_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.lfia_test_app.ImageValidator

class MainActivity : FlutterActivity() {
    private val channelName = "lfia/opencv"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "checkImageQuality") {
                    val imagePath = call.argument<String>("imagePath")

                    if (imagePath == null) {
                        result.error("NO_PATH", "Image path is missing", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val quality = ImageValidator.evaluateSingleImage(imagePath)

                        result.success(
                            hashMapOf<String, Any>(
                                "usable" to quality.usable,
                                "contrastExposure" to quality.contrastExposure,
                                "blurriness" to quality.blurriness
                            )
                        )
                    } catch (e: Exception) {
                        result.error("OPENCV_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}