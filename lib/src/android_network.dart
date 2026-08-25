import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNetwork {
  const AndroidNetwork._();

  static const _channel = MethodChannel('de.lasli.app/network');

  static Future<bool> bindToWifi() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('bindToWifi') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> clearBinding() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearBinding');
    } on PlatformException {
      return;
    }
  }

  static Future<void> openWifiSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openWifiSettings');
    } on PlatformException {
      return;
    }
  }
}
