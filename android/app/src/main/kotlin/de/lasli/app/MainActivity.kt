package de.lasli.app

import android.media.AudioManager
import android.media.ToneGenerator
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private var measurementToneGenerator: ToneGenerator? = null
    private var timestampedAudioCapture: TimestampedAudioCapture? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val audioCapture = TimestampedAudioCapture(this)
        timestampedAudioCapture = audioCapture
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.lasli.app/timestamped_audio_events",
        ).setStreamHandler(audioCapture)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.lasli.app/timestamped_audio",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "clockMonotonicNs" -> result.success(System.nanoTime())
                "start" -> {
                    try {
                        audioCapture.start()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("AUDIO_START_FAILED", error.message, null)
                    }
                }
                "stop" -> {
                    audioCapture.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.lasli.app/audio",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playMeasurementStartTone" -> {
                    try {
                        measurementToneGenerator?.release()
                        val generator = ToneGenerator(AudioManager.STREAM_ALARM, 100)
                        measurementToneGenerator = generator
                        generator.startTone(ToneGenerator.TONE_PROP_BEEP2, 350)
                        window.decorView.postDelayed({
                            generator.release()
                            if (measurementToneGenerator === generator) {
                                measurementToneGenerator = null
                            }
                        }, 500)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "MEASUREMENT_TONE_FAILED",
                            error.message,
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.lasli.app/measurement_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val usesMicrophone = call.argument<Boolean>("usesMicrophone") ?: false
                    val usesConnectedDevice =
                        call.argument<Boolean>("usesConnectedDevice") ?: false
                    val trainingActive =
                        call.argument<Boolean>("trainingActive") ?: false
                    try {
                        LasliForegroundService.start(
                            this,
                            usesMicrophone,
                            usesConnectedDevice,
                            trainingActive,
                        )
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "FOREGROUND_SERVICE_START_FAILED",
                            error.message,
                            null,
                        )
                    }
                }
                "stop" -> {
                    try {
                        LasliForegroundService.stop(this)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "FOREGROUND_SERVICE_STOP_FAILED",
                            error.message,
                            null,
                        )
                    }
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "BATTERY_OPTIMIZATION_REQUEST_FAILED",
                            error.message,
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.lasli.app/network",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bindToWifi" -> result.success(bindProcessToWifi())
                "clearBinding" -> {
                    clearNetworkBinding()
                    result.success(null)
                }
                "openWifiSettings" -> {
                    startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        timestampedAudioCapture?.stop()
        timestampedAudioCapture = null
        super.onDestroy()
    }

    private fun bindProcessToWifi(): Boolean {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return false
        val wifiNetwork = manager.allNetworks.firstOrNull { network ->
            manager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        } ?: return false

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.bindProcessToNetwork(wifiNetwork)
        } else {
            @Suppress("DEPRECATION")
            ConnectivityManager.setProcessDefaultNetwork(wifiNetwork)
        }
    }

    private fun clearNetworkBinding() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.bindProcessToNetwork(null as Network?)
        } else {
            @Suppress("DEPRECATION")
            ConnectivityManager.setProcessDefaultNetwork(null)
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(PowerManager::class.java) ?: return false
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (isIgnoringBatteryOptimizations()) return

        val packageUri = Uri.parse("package:$packageName")
        val requestIntent =
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = packageUri
            }
        try {
            startActivity(requestIntent)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }
}
