import 'dart:collection';

import 'app_monotonic_clock.dart';
import 'models.dart';
import 'processing.dart';
import 'yamnet_snore_detector.dart';

const int yamnetBoundaryUncertaintyMilliseconds = 260;
const double yamnetBoundaryUncertaintySeconds =
    yamnetBoundaryUncertaintyMilliseconds / 1000;
const int yamnetStartLookbackMicroseconds = yamnetInputSamples *
    Duration.microsecondsPerSecond ~/
    (2 * audioSamplingRate);

class YamnetRawSnoreWindow {
  const YamnetRawSnoreWindow({
    required this.startAt,
    required this.endAt,
  });

  final DateTime startAt;
  final DateTime endAt;

  double get widthMs =>
      endAt.difference(startAt).inMicroseconds /
      Duration.microsecondsPerMillisecond;
}

YamnetRawSnoreWindow yamnetReportedSnoreInterval(DateTime center) {
  return YamnetRawSnoreWindow(
    startAt: center.subtract(
      const Duration(microseconds: yamnetStartLookbackMicroseconds),
    ),
    endAt: center.add(
      const Duration(milliseconds: yamnetBoundaryUncertaintyMilliseconds),
    ),
  );
}

TimeWindow? yamnetWindowOnTimeline(
  YamnetRawSnoreWindow window, {
  required DateTime fallbackStartedAt,
  DateTime? timelineAnchorAt,
  double? timelineAnchorS,
}) {
  final durationS = window.endAt.difference(window.startAt).inMicroseconds /
      Duration.microsecondsPerSecond;
  if (!durationS.isFinite || durationS <= 0) return null;

  final fallbackStartS =
      window.startAt.difference(fallbackStartedAt).inMicroseconds /
          Duration.microsecondsPerSecond;
  final hasAnchor = timelineAnchorAt != null &&
      timelineAnchorS != null &&
      timelineAnchorS.isFinite;
  final mappedStartS = hasAnchor
      ? timelineAnchorS +
          window.startAt.difference(timelineAnchorAt).inMicroseconds /
              Duration.microsecondsPerSecond
      : fallbackStartS;
  if (!mappedStartS.isFinite) return null;

  final mappedEndS = mappedStartS + durationS;
  if (!mappedEndS.isFinite || mappedEndS <= mappedStartS) return null;
  return TimeWindow(
    mappedStartS < 0 ? 0 : mappedStartS,
    mappedEndS < 0 ? 0 : mappedEndS,
  );
}

class YamnetRawSnoreResult {
  const YamnetRawSnoreResult({
    required this.available,
    required this.active,
    required this.detectedNow,
    required this.rawScore,
    required this.inferenceId,
    required this.windowId,
    required this.updatedAt,
    required this.rmsDb,
    this.activeStartAt,
    this.activeEndAt,
    this.completedWindow,
    this.snoreRatePerMin,
  });

  const YamnetRawSnoreResult.empty()
      : available = false,
        active = false,
        detectedNow = false,
        rawScore = 0,
        inferenceId = 0,
        windowId = 0,
        updatedAt = null,
        rmsDb = -120,
        activeStartAt = null,
        activeEndAt = null,
        completedWindow = null,
        snoreRatePerMin = null;

  final bool available;
  final bool active;
  final bool detectedNow;
  final double rawScore;
  final int inferenceId;
  final int windowId;
  final DateTime? updatedAt;
  final double rmsDb;
  final DateTime? activeStartAt;
  final DateTime? activeEndAt;
  final YamnetRawSnoreWindow? completedWindow;
  final double? snoreRatePerMin;

  double? get activeWidthMs {
    final start = activeStartAt;
    final end = activeEndAt;
    if (!active || start == null || end == null || !end.isAfter(start)) {
      return null;
    }
    return end.difference(start).inMicroseconds /
        Duration.microsecondsPerMillisecond;
  }

  double? get completedWidthMs => completedWindow?.widthMs;

  DateTime? get currentWindowEndAt =>
      completedWindow?.endAt ?? activeEndAt ?? updatedAt;
}

class YamnetRawSnoreTracker {
  YamnetRawSnoreTracker();

  static final _mergeGap = Duration(
    milliseconds: (yamnetRawTeacherWindowMergeGapSeconds * 1000).round(),
  );
  static const _minimumWindow = Duration(milliseconds: 160);
  static const _staleTimeout = Duration(seconds: 2);

  final Queue<DateTime> _completedWindowEnds = Queue<DateTime>();

  var _result = const YamnetRawSnoreResult.empty();
  int _lastInferenceId = 0;
  int _windowId = 0;
  DateTime? _activeStartAt;
  DateTime? _activeEndAt;

  YamnetRawSnoreResult get snapshot => _result;

  void reset() {
    _completedWindowEnds.clear();
    _result = const YamnetRawSnoreResult.empty();
    _lastInferenceId = 0;
    _windowId = 0;
    _activeStartAt = null;
    _activeEndAt = null;
  }

  YamnetRawSnoreResult update(AudioSnoreDetector? detector, DateTime now) {
    if (detector == null || detector.rawInferenceId <= 0) {
      return _expireIfStale(now);
    }
    if (detector.rawInferenceId == _lastInferenceId) {
      return _expireIfStale(now);
    }
    _lastInferenceId = detector.rawInferenceId;

    final center = detector.rawWindowCenterAt ?? now;
    final energyBurst = detector.rawEnergyBurst;
    final interval = energyBurst == null
        ? yamnetReportedSnoreInterval(center)
        : YamnetRawSnoreWindow(
            startAt: AppMonotonicClock.wallTime(
              energyBurst.startMonotonicUs,
            ),
            endAt: AppMonotonicClock.wallTime(
              energyBurst.endMonotonicUs,
            ),
          );
    final intervalStart = interval.startAt;
    final intervalEnd = interval.endAt;
    final candidate = detector.rawScore >= yamnetRawTeacherSnoreThreshold;
    YamnetRawSnoreWindow? completedWindow;
    var detectedNow = false;

    if (candidate) {
      final activeEnd = _activeEndAt;
      if (_activeStartAt == null ||
          activeEnd == null ||
          intervalStart.isAfter(activeEnd.add(_mergeGap))) {
        completedWindow = _closeWindow();
        _activeStartAt = intervalStart;
        _activeEndAt = intervalEnd;
        _windowId++;
        detectedNow = true;
      } else if (intervalEnd.isAfter(activeEnd)) {
        _activeEndAt = intervalEnd;
      }
    } else {
      final activeEnd = _activeEndAt;
      if (activeEnd != null &&
          intervalStart.isAfter(activeEnd.add(_mergeGap))) {
        completedWindow = _closeWindow();
      }
    }

    _result = YamnetRawSnoreResult(
      available: true,
      active: _activeStartAt != null,
      detectedNow: detectedNow,
      rawScore: detector.rawScore,
      inferenceId: detector.rawInferenceId,
      windowId: _windowId,
      updatedAt: now,
      rmsDb: detector.rmsDb,
      activeStartAt: _activeStartAt,
      activeEndAt: _activeEndAt,
      completedWindow: completedWindow,
      snoreRatePerMin: _snoreRatePerMin(),
    );
    return _result;
  }

  YamnetRawSnoreWindow? finish(DateTime now) {
    final completedWindow = _closeWindow();
    _result = YamnetRawSnoreResult(
      available: _result.available,
      active: false,
      detectedNow: false,
      rawScore: _result.rawScore,
      inferenceId: _lastInferenceId,
      windowId: _windowId,
      updatedAt: now,
      rmsDb: _result.rmsDb,
      completedWindow: completedWindow,
      snoreRatePerMin: _snoreRatePerMin(),
    );
    return completedWindow;
  }

  YamnetRawSnoreResult _expireIfStale(DateTime now) {
    final updatedAt = _result.updatedAt;
    if (updatedAt == null || now.difference(updatedAt) <= _staleTimeout) {
      return _result;
    }
    final completedWindow = _closeWindow();
    _result = YamnetRawSnoreResult(
      available: false,
      active: false,
      detectedNow: false,
      rawScore: 0,
      inferenceId: _lastInferenceId,
      windowId: _windowId,
      updatedAt: now,
      rmsDb: _result.rmsDb,
      completedWindow: completedWindow,
      snoreRatePerMin: _snoreRatePerMin(),
    );
    return _result;
  }

  YamnetRawSnoreWindow? _closeWindow() {
    final start = _activeStartAt;
    final end = _activeEndAt;
    _activeStartAt = null;
    _activeEndAt = null;
    if (start == null || end == null || !end.isAfter(start)) return null;
    final window = YamnetRawSnoreWindow(startAt: start, endAt: end);
    if (window.endAt.difference(window.startAt) < _minimumWindow) {
      return null;
    }
    _completedWindowEnds.addLast(window.endAt);
    while (_completedWindowEnds.length > 8) {
      _completedWindowEnds.removeFirst();
    }
    return window;
  }

  double? _snoreRatePerMin() {
    if (_completedWindowEnds.length < 3) return null;
    final ends = _completedWindowEnds.toList(growable: false);
    final intervals = <double>[];
    for (var i = 1; i < ends.length; i++) {
      final interval = ends[i].difference(ends[i - 1]).inMilliseconds / 1000.0;
      if (interval >= 1.4 && interval <= 12.0) intervals.add(interval);
    }
    if (intervals.length < 2) return null;
    final period = median(intervals);
    if (!period.isFinite || period <= 0) return null;
    return 60.0 / period;
  }
}
