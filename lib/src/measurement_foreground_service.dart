import 'dart:io';

import 'package:flutter/services.dart';

class MeasurementForegroundService {
  static const MethodChannel _channel =
      MethodChannel('de.lasli.app/measurement_service');

  static Future<void> start({
    required bool usesMicrophone,
    required bool usesConnectedDevice,
    required bool trainingActive,
  }) async {
    if (!Platform.isAndroid || (!usesMicrophone && !usesConnectedDevice)) {
      return;
    }

    await _channel.invokeMethod<void>('start', {
      'usesMicrophone': usesMicrophone,
      'usesConnectedDevice': usesConnectedDevice,
      'trainingActive': trainingActive,
    });
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>(
          'isIgnoringBatteryOptimizations',
        ) ??
        true;
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
  }
}
