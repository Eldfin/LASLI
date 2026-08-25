import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_monotonic_clock.dart';

class TimestampedAudioChunk {
  const TimestampedAudioChunk({
    required this.pcm,
    required this.firstSampleMonotonicUs,
    required this.sampleRate,
  });

  final Uint8List pcm;
  final int firstSampleMonotonicUs;
  final int sampleRate;
}

class TimestampedNativeAudioRecorder {
  static const _method = MethodChannel('de.lasli.app/timestamped_audio');
  static const _events = EventChannel('de.lasli.app/timestamped_audio_events');

  StreamSubscription<dynamic>? _subscription;
  int? _nativeToAppOffsetUs;

  Future<void> start({
    required void Function(TimestampedAudioChunk chunk) onChunk,
    void Function(Object error)? onError,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError(
        'Zeitgestempeltes Audio ist nur auf Android und iOS verfuegbar.',
      );
    }
    _nativeToAppOffsetUs = await _synchronizeClock();
    _subscription = _events.receiveBroadcastStream().listen(
          (event) => _consumeEvent(event, onChunk),
          onError: onError,
          cancelOnError: false,
        );
    try {
      await _method.invokeMethod<void>('start');
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } finally {
      await _subscription?.cancel();
      _subscription = null;
      _nativeToAppOffsetUs = null;
    }
  }

  Future<int> _synchronizeClock() async {
    int? bestOffsetUs;
    int? bestRoundTripUs;
    for (var attempt = 0; attempt < 9; attempt++) {
      final beforeUs = AppMonotonicClock.nowUs();
      final nativeNs = await _method.invokeMethod<int>('clockMonotonicNs');
      final afterUs = AppMonotonicClock.nowUs();
      if (nativeNs == null) continue;
      final roundTripUs = afterUs - beforeUs;
      final midpointUs = beforeUs + roundTripUs ~/ 2;
      final offsetUs = midpointUs - nativeNs ~/ 1000;
      if (bestRoundTripUs == null || roundTripUs < bestRoundTripUs) {
        bestRoundTripUs = roundTripUs;
        bestOffsetUs = offsetUs;
      }
    }
    if (bestOffsetUs == null) {
      throw StateError('Native Audiouhr konnte nicht synchronisiert werden.');
    }
    return bestOffsetUs;
  }

  void _consumeEvent(
    dynamic event,
    void Function(TimestampedAudioChunk chunk) onChunk,
  ) {
    if (event is! Map) return;
    final pcmValue = event['pcm'];
    final firstSampleNs = event['firstSampleTimeNs'];
    final sampleRate = event['sampleRate'];
    final offsetUs = _nativeToAppOffsetUs;
    if (pcmValue is! Uint8List ||
        firstSampleNs is! int ||
        sampleRate is! int ||
        sampleRate <= 0 ||
        offsetUs == null) {
      return;
    }
    onChunk(
      TimestampedAudioChunk(
        pcm: pcmValue,
        firstSampleMonotonicUs: firstSampleNs ~/ 1000 + offsetUs,
        sampleRate: sampleRate,
      ),
    );
  }
}
