import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'app_monotonic_clock.dart';
import 'models.dart';
import 'processing.dart';
import 'timestamped_audio_recorder.dart';

class YamnetAudioEnergyFrame {
  const YamnetAudioEnergyFrame({
    required this.centerMonotonicUs,
    required this.rmsDb,
  });

  final int centerMonotonicUs;
  final double rmsDb;
}

class YamnetAudioBurst {
  const YamnetAudioBurst({
    required this.startMonotonicUs,
    required this.endMonotonicUs,
  });

  final int startMonotonicUs;
  final int endMonotonicUs;
}

YamnetAudioBurst? localizeYamnetAudioBurst(
  List<YamnetAudioEnergyFrame> frames, {
  required int inferenceStartMonotonicUs,
  required int inferenceCenterMonotonicUs,
  required int inferenceEndMonotonicUs,
}) {
  if (frames.length < 12 ||
      inferenceEndMonotonicUs <= inferenceStartMonotonicUs) {
    return null;
  }

  const searchLeadUs = 1500000;
  const frameHalfWidthUs = 5000;
  const releaseGapUs = 120000;
  const onsetFrames = 3;
  final searchStartUs = inferenceStartMonotonicUs - searchLeadUs;
  final selected = frames
      .where(
        (frame) =>
            frame.centerMonotonicUs >= searchStartUs &&
            frame.centerMonotonicUs <= inferenceEndMonotonicUs,
      )
      .toList(growable: false);
  if (selected.length < 12) return null;

  final smoothed = List<double>.filled(selected.length, -120);
  for (var index = 0; index < selected.length; index++) {
    var sum = 0.0;
    var count = 0;
    final first = math.max(0, index - 2);
    final last = math.min(selected.length - 1, index + 2);
    for (var neighbor = first; neighbor <= last; neighbor++) {
      sum += selected[neighbor].rmsDb;
      count++;
    }
    smoothed[index] = sum / count;
  }

  var baselineValues = <double>[
    for (var index = 0; index < selected.length; index++)
      if (selected[index].centerMonotonicUs < inferenceStartMonotonicUs)
        smoothed[index],
  ];
  if (baselineValues.length < 20) baselineValues = [...smoothed];
  final inferenceValues = <double>[
    for (var index = 0; index < selected.length; index++)
      if (selected[index].centerMonotonicUs >= inferenceStartMonotonicUs)
        smoothed[index],
  ];
  if (inferenceValues.length < 8) return null;
  baselineValues.sort();
  inferenceValues.sort();
  final baseline = _orderedPercentile(baselineValues, 25);
  final peak = _orderedPercentile(inferenceValues, 92);
  final dynamicRange = peak - baseline;
  if (!dynamicRange.isFinite || dynamicRange < 3.5) return null;

  final onsetThreshold = baseline + math.max(2.4, dynamicRange * 0.30);
  final releaseThreshold = baseline + math.max(1.2, dynamicRange * 0.14);
  final runs = <YamnetAudioBurst>[];
  var onsetStreak = 0;
  int? runStartIndex;
  int? lastAboveReleaseIndex;

  void closeRun() {
    final startIndex = runStartIndex;
    final endIndex = lastAboveReleaseIndex;
    runStartIndex = null;
    lastAboveReleaseIndex = null;
    onsetStreak = 0;
    if (startIndex == null || endIndex == null || endIndex < startIndex) return;
    final startUs = selected[startIndex].centerMonotonicUs - frameHalfWidthUs;
    final endUs = selected[endIndex].centerMonotonicUs + frameHalfWidthUs;
    if (endUs - startUs >= 120000) {
      runs.add(
        YamnetAudioBurst(
          startMonotonicUs: startUs,
          endMonotonicUs: endUs,
        ),
      );
    }
  }

  for (var index = 0; index < selected.length; index++) {
    final value = smoothed[index];
    if (runStartIndex == null) {
      onsetStreak = value >= onsetThreshold ? onsetStreak + 1 : 0;
      if (onsetStreak < onsetFrames) continue;
      var startIndex = index - onsetFrames + 1;
      for (var back = startIndex - 1; back >= 0; back--) {
        if (smoothed[back] < releaseThreshold) break;
        startIndex = back;
      }
      runStartIndex = startIndex;
      lastAboveReleaseIndex = index;
      continue;
    }

    if (value >= releaseThreshold) {
      lastAboveReleaseIndex = index;
      continue;
    }
    final lastAbove = lastAboveReleaseIndex;
    if (lastAbove != null &&
        selected[index].centerMonotonicUs -
                selected[lastAbove].centerMonotonicUs >
            releaseGapUs) {
      closeRun();
    }
  }
  if (runStartIndex != null) closeRun();
  if (runs.isEmpty) return null;

  YamnetAudioBurst? best;
  var bestScore = -double.infinity;
  for (final run in runs) {
    final overlapStart =
        math.max(run.startMonotonicUs, inferenceStartMonotonicUs);
    final overlapEnd = math.min(run.endMonotonicUs, inferenceEndMonotonicUs);
    final overlapUs = math.max(0, overlapEnd - overlapStart);
    if (overlapUs < 80000) continue;
    final midpointUs = (run.startMonotonicUs + run.endMonotonicUs) ~/ 2;
    final centerDistanceUs = (midpointUs - inferenceCenterMonotonicUs).abs();
    final durationUs = run.endMonotonicUs - run.startMonotonicUs;
    final score = overlapUs +
        math.min(durationUs, 2000000) * 0.12 -
        centerDistanceUs * 0.04;
    if (score > bestScore) {
      bestScore = score;
      best = run;
    }
  }
  return best;
}

double _orderedPercentile(List<double> ordered, int percentile) {
  if (ordered.isEmpty) return double.nan;
  final position =
      (ordered.length - 1) * percentile.clamp(0, 100).toDouble() / 100.0;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return ordered[lower];
  final fraction = position - lower;
  return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction;
}

class YamnetInferenceFrame {
  const YamnetInferenceFrame({
    required this.inferenceId,
    required this.startMonotonicUs,
    required this.centerMonotonicUs,
    required this.endMonotonicUs,
    required this.score,
    required this.candidate,
    required this.rmsDb,
  });

  final int inferenceId;
  final int startMonotonicUs;
  final int centerMonotonicUs;
  final int endMonotonicUs;
  final double score;
  final bool candidate;
  final double rmsDb;
}

class YamnetClassifier {
  YamnetClassifier._(this._interpreter, this._snoreIndex);

  final Interpreter _interpreter;
  final int _snoreIndex;

  static Future<YamnetClassifier> create() async {
    final interpreter = await Interpreter.fromAsset(
      'assets/models/yamnet.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    final classMap = await rootBundle.loadString(
      'assets/models/yamnet_class_map.csv',
    );
    return YamnetClassifier._(interpreter, _findSnoreIndex(classMap));
  }

  double score(Float32List samples) {
    if (samples.length != yamnetInputSamples) {
      throw ArgumentError('YAMNet expects $yamnetInputSamples samples.');
    }

    var mean = 0.0;
    for (final value in samples) {
      mean += value;
    }
    mean /= samples.length;

    final input = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      input[i] = samples[i] - mean;
    }

    final output = List.generate(1, (_) => List<double>.filled(521, 0));
    _interpreter.run(input, output);
    return output.first[_snoreIndex];
  }

  void close() => _interpreter.close();

  static int _findSnoreIndex(String csv) {
    final lines = csv.split(RegExp(r'\r?\n'));
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split(',');
      if (parts.length >= 3 && parts[2].trim().toLowerCase() == 'snoring') {
        return int.parse(parts[0]);
      }
    }
    throw StateError("YAMNet class 'Snoring' not found.");
  }
}

class AudioSnoreDetector {
  AudioSnoreDetector({
    this.onInference,
    this.onEnergyFrame,
    this.inferenceSeconds = yamnetInferenceSeconds,
  });

  final void Function(YamnetInferenceFrame frame)? onInference;
  final void Function(YamnetAudioEnergyFrame frame)? onEnergyFrame;
  final double inferenceSeconds;

  final AudioRecorder _recorder = AudioRecorder();
  TimestampedNativeAudioRecorder? _timestampedRecorder;
  YamnetClassifier? _classifier;
  StreamSubscription<Uint8List>? _subscription;
  final Float32List _audioWindow = Float32List(yamnetInputSamples);
  final ListQueue<YamnetAudioEnergyFrame> _energyHistory =
      ListQueue<YamnetAudioEnergyFrame>();

  var _bufferedSamples = 0;
  var _samplesSinceInference = 0;
  var _isSnoring = false;
  var _currentScore = 0.0;
  var _currentRmsDb = -120.0;
  var _quietSeconds = 0.0;
  var _snoreCount = 0;
  var _inferenceId = 0;
  var _rawScore = 0.0;
  var _rawCandidate = false;
  DateTime? _rawWindowCenterAt;
  int? _rawWindowStartMonotonicUs;
  int? _rawWindowCenterMonotonicUs;
  int? _rawWindowEndMonotonicUs;
  YamnetAudioBurst? _rawEnergyBurst;
  int? _fallbackAudioOriginMonotonicUs;
  int? _latestAudioSampleEndMonotonicUs;
  int? _energyFrameStartMonotonicUs;
  var _totalSamples = 0;
  var _energySamples = 0;
  var _energySumSquares = 0.0;
  var _state = const SnoreState.empty();

  SnoreState get snapshot => _state;
  double get rawScore => _rawScore;
  bool get rawCandidate => _rawCandidate;
  int get rawInferenceId => _inferenceId;
  DateTime? get rawWindowCenterAt => _rawWindowCenterAt;
  int? get rawWindowStartMonotonicUs => _rawWindowStartMonotonicUs;
  int? get rawWindowCenterMonotonicUs => _rawWindowCenterMonotonicUs;
  int? get rawWindowEndMonotonicUs => _rawWindowEndMonotonicUs;
  YamnetAudioBurst? get rawEnergyBurst => _rawEnergyBurst;
  double get rmsDb => _currentRmsDb;

  Future<void> start() async {
    _resetAudioTimeline();
    _classifier = await YamnetClassifier.create();
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw StateError('Mikrofonberechtigung fehlt.');
    }

    final timestampedRecorder = TimestampedNativeAudioRecorder();
    try {
      await timestampedRecorder.start(
        onChunk: (chunk) {
          if (chunk.sampleRate != audioSamplingRate) return;
          _consumePcm(
            chunk.pcm,
            firstSampleMonotonicUs: chunk.firstSampleMonotonicUs,
          );
        },
      );
      _timestampedRecorder = timestampedRecorder;
      return;
    } catch (_) {
      try {
        await timestampedRecorder.stop();
      } catch (_) {}
    }

    final startBeforeUs = AppMonotonicClock.nowUs();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: audioSamplingRate,
        numChannels: 1,
      ),
    );
    final startAfterUs = AppMonotonicClock.nowUs();
    _fallbackAudioOriginMonotonicUs =
        startBeforeUs + (startAfterUs - startBeforeUs) ~/ 2;
    _subscription = stream.listen(_consumePcm);
  }

  Future<void> stop() async {
    final timestampedRecorder = _timestampedRecorder;
    _timestampedRecorder = null;
    if (timestampedRecorder != null) {
      await timestampedRecorder.stop();
    }
    await _subscription?.cancel();
    _subscription = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorder.dispose();
    _classifier?.close();
    _classifier = null;
  }

  void _resetAudioTimeline() {
    _audioWindow.fillRange(0, _audioWindow.length, 0);
    _energyHistory.clear();
    _bufferedSamples = 0;
    _samplesSinceInference = 0;
    _fallbackAudioOriginMonotonicUs = null;
    _latestAudioSampleEndMonotonicUs = null;
    _energyFrameStartMonotonicUs = null;
    _totalSamples = 0;
    _energySamples = 0;
    _energySumSquares = 0;
    _rawEnergyBurst = null;
  }

  void _consumePcm(
    Uint8List bytes, {
    int? firstSampleMonotonicUs,
  }) {
    if (bytes.length < 32) return;
    final samples = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final samplesBeforeChunk = _totalSamples;
    final fallbackOrigin = _fallbackAudioOriginMonotonicUs;
    final chunkFirstSampleUs = firstSampleMonotonicUs ??
        (fallbackOrigin == null
            ? AppMonotonicClock.nowUs() -
                samples.length *
                    Duration.microsecondsPerSecond ~/
                    audioSamplingRate
            : fallbackOrigin +
                samplesBeforeChunk *
                    Duration.microsecondsPerSecond ~/
                    audioSamplingRate);
    _latestAudioSampleEndMonotonicUs = chunkFirstSampleUs +
        samples.length * Duration.microsecondsPerSecond ~/ audioSamplingRate;
    _appendEnergyFrames(samples, chunkFirstSampleUs);

    _appendSamples(samples);
    _samplesSinceInference += samples.length;
    final inferenceSamples = (inferenceSeconds * audioSamplingRate).round();
    if (_bufferedSamples >= yamnetInputSamples &&
        _samplesSinceInference >= inferenceSamples) {
      final elapsed = _samplesSinceInference / audioSamplingRate;
      _samplesSinceInference = 0;
      _runInference(elapsed);
    }
  }

  void _appendEnergyFrames(
    Float32List samples,
    int firstSampleMonotonicUs,
  ) {
    const frameSamples = audioSamplingRate ~/ 100;
    for (var index = 0; index < samples.length; index++) {
      final sample = samples[index];
      if (_energySamples == 0) {
        _energyFrameStartMonotonicUs = firstSampleMonotonicUs +
            index * Duration.microsecondsPerSecond ~/ audioSamplingRate;
      }
      _energySumSquares += sample * sample;
      _energySamples++;
      _totalSamples++;
      if (_energySamples < frameSamples) continue;
      final rms = math.sqrt(_energySumSquares / _energySamples + 1e-12);
      final centerUs =
          (_energyFrameStartMonotonicUs ?? firstSampleMonotonicUs) +
              _energySamples *
                  Duration.microsecondsPerSecond ~/
                  (2 * audioSamplingRate);
      final frame = YamnetAudioEnergyFrame(
        centerMonotonicUs: centerUs,
        rmsDb: 20 * log10(rms + 1e-12),
      );
      _energyHistory.addLast(frame);
      final historyCutoffUs = centerUs - 8000000;
      while (_energyHistory.isNotEmpty &&
          _energyHistory.first.centerMonotonicUs < historyCutoffUs) {
        _energyHistory.removeFirst();
      }
      onEnergyFrame?.call(frame);
      _energySamples = 0;
      _energySumSquares = 0;
      _energyFrameStartMonotonicUs = null;
    }
  }

  void _appendSamples(Float32List samples) {
    if (samples.length >= yamnetInputSamples) {
      _audioWindow.setAll(
          0, samples.sublist(samples.length - yamnetInputSamples));
      _bufferedSamples = yamnetInputSamples;
      return;
    }

    final shift = samples.length;
    if (_bufferedSamples + shift <= yamnetInputSamples) {
      _audioWindow.setAll(_bufferedSamples, samples);
      _bufferedSamples += shift;
      return;
    }

    final overflow = _bufferedSamples + shift - yamnetInputSamples;
    final keepExisting = _bufferedSamples - overflow;
    _audioWindow.setRange(0, keepExisting, _audioWindow, overflow);
    _audioWindow.setAll(keepExisting, samples);
    _bufferedSamples = yamnetInputSamples;
  }

  void _runInference(double elapsed) {
    final classifier = _classifier;
    if (classifier == null) return;
    _inferenceId++;

    var sumSquares = 0.0;
    for (final sample in _audioWindow) {
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / _audioWindow.length + 1e-12);
    _currentRmsDb = 20 * log10(rms + 1e-12);

    final snoreScore = classifier.score(_audioWindow);
    _rawScore = snoreScore;
    _rawCandidate = snoreScore >= yamnetRawTeacherSnoreThreshold;
    _rawWindowEndMonotonicUs =
        _latestAudioSampleEndMonotonicUs ?? AppMonotonicClock.nowUs();
    _rawWindowStartMonotonicUs = _rawWindowEndMonotonicUs! -
        (yamnetInputSamples *
            Duration.microsecondsPerSecond ~/
            audioSamplingRate);
    _rawWindowCenterMonotonicUs =
        (_rawWindowStartMonotonicUs! + _rawWindowEndMonotonicUs!) ~/ 2;
    // Measurement detection is deliberately more sensitive than automatic
    // teacher labels, so precise boundaries must also be available below the
    // high-confidence teacher threshold.
    _rawEnergyBurst = snoreScore >= yamnetMeasurementSnoreThreshold
        ? localizeYamnetAudioBurst(
            _energyHistory.toList(growable: false),
            inferenceStartMonotonicUs: _rawWindowStartMonotonicUs!,
            inferenceCenterMonotonicUs: _rawWindowCenterMonotonicUs!,
            inferenceEndMonotonicUs: _rawWindowEndMonotonicUs!,
          )
        : null;
    _rawWindowCenterAt =
        AppMonotonicClock.wallTime(_rawWindowCenterMonotonicUs!);
    _currentScore = yamnetScoreSmoothing * _currentScore +
        (1 - yamnetScoreSmoothing) * snoreScore;
    final candidate = _currentScore >= yamnetSnoreThreshold;

    if (candidate) {
      _quietSeconds = 0;
      if (!_isSnoring) {
        _isSnoring = true;
        _snoreCount++;
      }
    } else if (_isSnoring) {
      _quietSeconds += elapsed;
      if (_quietSeconds >= snoreOffsetSeconds) {
        _isSnoring = false;
        _quietSeconds = 0;
      }
    }

    final windowCenterAt = _isSnoring || candidate ? _rawWindowCenterAt : null;
    _state = SnoreState(
      isSnoring: _isSnoring,
      detectedNow: candidate,
      score: _currentScore,
      rmsDb: _currentRmsDb,
      snoreCount: _snoreCount,
      backend: 'yamnet',
      inferenceId: _inferenceId,
      windowCenterAt: windowCenterAt,
    );
    onInference?.call(
      YamnetInferenceFrame(
        inferenceId: _inferenceId,
        startMonotonicUs: _rawWindowStartMonotonicUs!,
        centerMonotonicUs: _rawWindowCenterMonotonicUs!,
        endMonotonicUs: _rawWindowEndMonotonicUs!,
        score: _rawScore,
        candidate: _rawCandidate,
        rmsDb: _currentRmsDb,
      ),
    );
  }
}
