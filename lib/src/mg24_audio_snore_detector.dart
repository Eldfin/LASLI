import 'dart:collection';
import 'dart:math' as math;

import 'mg24_sensor_client.dart';
import 'models.dart';
import 'processing.dart';

class Mg24AudioFeatureSnoreWindow {
  const Mg24AudioFeatureSnoreWindow({
    required this.startAt,
    required this.endAt,
  });

  final DateTime startAt;
  final DateTime endAt;

  double get widthMs =>
      endAt.difference(startAt).inMicroseconds /
      Duration.microsecondsPerMillisecond;
}

class Mg24AudioFeatureSnoreResult {
  const Mg24AudioFeatureSnoreResult({
    required this.available,
    required this.active,
    required this.detectedNow,
    required this.rawProbability,
    required this.smoothedProbability,
    required this.inferenceId,
    required this.burstCounter,
    required this.updatedAt,
    this.activeStartAt,
    this.activeEndAt,
    this.completedWindow,
    this.snoreRatePerMin,
  });

  const Mg24AudioFeatureSnoreResult.empty()
      : available = false,
        active = false,
        detectedNow = false,
        rawProbability = 0,
        smoothedProbability = 0,
        inferenceId = 0,
        burstCounter = 0,
        updatedAt = null,
        activeStartAt = null,
        activeEndAt = null,
        completedWindow = null,
        snoreRatePerMin = null;

  final bool available;
  final bool active;
  final bool detectedNow;
  final double rawProbability;
  final double smoothedProbability;
  final int inferenceId;
  final int burstCounter;
  final DateTime? updatedAt;
  final DateTime? activeStartAt;
  final DateTime? activeEndAt;
  final Mg24AudioFeatureSnoreWindow? completedWindow;
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
}

class Mg24AudioFeatureSnoreDetector {
  Mg24AudioFeatureSnoreDetector();

  static const _featureCount = 12;
  static const _windowBlocks = 11;
  static const _delayBlocks = _windowBlocks ~/ 2;
  static const _blockPeriod = Duration(milliseconds: 80);
  static const _startThreshold = 0.45;
  static const _endThreshold = 0.27;
  static const _minimumWindow = Duration(milliseconds: 160);
  static const _staleTimeout = Duration(milliseconds: 900);

  static const _mean = <double>[
    25.1096878,
    28.0562248,
    6.74171686,
    63.2010536,
    56.2994461,
    16.3995991,
    -50.3606415,
    62.5770073,
    7.92938757,
    9.38821793,
    8.85846901,
    11.2469301,
  ];

  static const _scale = <double>[
    22.7537956,
    17.4500389,
    15.145937,
    17.1619682,
    20.0980129,
    14.7353649,
    12.2150278,
    19.3199883,
    3.49368119,
    4.81537867,
    4.92495918,
    6.66541576,
  ];

  static const _w1 = <double>[
    -3.37178516,
    0.125065535,
    -0.11998792,
    4.92384672,
    0.11722821,
    0.418417126,
    -0.299053997,
    -3.28549981,
    -0.217102751,
    4.92324448,
    0.815728307,
    0.390151501,
    0.938207984,
    -2.87422323,
    3.35234356,
    0.464851946,
    -0.133228108,
    3.73679709,
    0.315750539,
    -2.56985116,
    2.69956303,
    1.15498424,
    -2.06096482,
    1.57595634,
    2.20769119,
    -1.10152996,
    3.58019042,
    0.181676865,
    3.47097969,
    -1.2308898,
    1.49250638,
    1.52963448,
    -0.110719301,
    -0.326438934,
    -0.00819582772,
    -0.152101889,
    0.801109672,
    0.525281966,
    0.838145375,
    -0.167761326,
    0.687377274,
    1.50875866,
    0.582260787,
    0.0492538624,
    -0.210672721,
    0.412456453,
    0.285663664,
    0.0300103296,
    -0.922309458,
    0.0537557341,
    4.79936695,
    2.27473783,
    1.36715126,
    0.210210636,
    0.70007205,
    -1.9150461,
    1.95253146,
    -0.556707561,
    1.20945203,
    0.914090455,
    1.05080235,
    0.287334532,
    0.659242749,
    -2.66750097,
    3.61141491,
    -0.10910625,
    0.506342947,
    4.15627909,
    0.245281994,
    -2.18916202,
    0.546352744,
    -0.195655078,
    0.358633667,
    -0.156943828,
    0.242396027,
    -0.144955114,
    -0.195722535,
    0.0928373113,
    0.150755644,
    -0.140147179,
    1.0835253,
    -0.181234911,
    0.763022542,
    -0.277800947,
    0.388137311,
    1.53855968,
    0.107133053,
    0.617676854,
    1.1178335,
    -0.400371969,
    -1.75795567,
    -2.06783032,
    -3.53035784,
    0.149720803,
    -0.316540748,
    -1.74479485,
    -1.08544457,
    -1.36276639,
    -0.66592896,
    0.412024617,
    -0.683070183,
    2.1131022,
    0.421376139,
    0.906320751,
    -0.336089373,
    -0.604124486,
    1.95287097,
    0.335585535,
    -1.11732888,
    0.666016877,
    0.237264171,
    -0.504440308,
    0.164169118,
    -0.607388258,
    0.3017461,
    1.54845035,
    -0.912241995,
    0.169347823,
    -0.311976641,
    -0.695971727,
  ];

  static const _b1 = <double>[
    0.0391862839,
    0.766324937,
    -1.34536982,
    3.46901107,
    2.42525434,
    -2.36831784,
    1.99281907,
    2.42208076,
    2.63811803,
    0.359939992,
  ];

  static const _w2 = <double>[
    -5.82603121,
    2.40611148,
    3.77206707,
    -3.67719555,
    4.18302917,
    1.57540309,
    3.28395128,
    -3.51699686,
    2.27230048,
    3.68047881,
  ];

  static const _b2 = 9.44071253;

  final Queue<_FeatureProbability> _probabilities =
      Queue<_FeatureProbability>();
  final Queue<DateTime> _completedWindowEnds = Queue<DateTime>();

  var _result = const Mg24AudioFeatureSnoreResult.empty();
  var _inferenceId = 0;
  var _burstCounter = 0;
  DateTime? _activeStartAt;
  DateTime? _activeEndAt;
  DateTime? _lastFeatureAt;

  Mg24AudioFeatureSnoreResult get snapshot => _result;

  void reset() {
    _probabilities.clear();
    _completedWindowEnds.clear();
    _result = const Mg24AudioFeatureSnoreResult.empty();
    _inferenceId = 0;
    _burstCounter = 0;
    _activeStartAt = null;
    _activeEndAt = null;
    _lastFeatureAt = null;
  }

  Mg24AudioFeatureSnoreResult update(Mg24SensorSample sample) {
    if (sample.role != Mg24SensorRole.forehead) return _result;
    final features = _featuresFromSample(sample);
    if (features == null) {
      return _expireIfStale(sample.receivedAt);
    }

    _inferenceId++;
    final rawProbability = _mlProbability(features);
    final usableProbability = _isUsableFrame(sample) ? rawProbability : 0.0;
    final at = sample.receivedAt;
    _lastFeatureAt = at;
    _probabilities.addLast(_FeatureProbability(at, usableProbability));
    while (_probabilities.length > _windowBlocks) {
      _probabilities.removeFirst();
    }

    final ready = _probabilities.length >= _windowBlocks;
    final smoothedProbability = ready
        ? _probabilities
                .map((item) => item.probability)
                .reduce((a, b) => a + b) /
            _probabilities.length
        : 0.0;
    final evaluatedAt = ready
        ? _probabilities
            .elementAt(math.max(0, _probabilities.length - 1 - _delayBlocks))
            .receivedAt
        : at;

    Mg24AudioFeatureSnoreWindow? completedWindow;
    var detectedNow = false;
    final activeStart = _activeStartAt;
    final isActive = activeStart != null;
    if (!isActive && ready && smoothedProbability >= _startThreshold) {
      _activeStartAt = evaluatedAt;
      _activeEndAt = evaluatedAt;
      _burstCounter++;
      detectedNow = true;
    } else if (isActive && smoothedProbability >= _endThreshold) {
      _activeEndAt = evaluatedAt;
    } else if (isActive) {
      completedWindow = _closeWindow();
    }

    _result = Mg24AudioFeatureSnoreResult(
      available: ready,
      active: _activeStartAt != null,
      detectedNow: detectedNow,
      rawProbability: rawProbability,
      smoothedProbability: smoothedProbability,
      inferenceId: _inferenceId,
      burstCounter: _burstCounter,
      updatedAt: at,
      activeStartAt: _activeStartAt,
      activeEndAt: _activeEndAt,
      completedWindow: completedWindow,
      snoreRatePerMin: _snoreRatePerMin(),
    );
    return _result;
  }

  Mg24AudioFeatureSnoreResult _expireIfStale(DateTime at) {
    final lastFeatureAt = _lastFeatureAt;
    if (lastFeatureAt != null &&
        at.difference(lastFeatureAt) <= _staleTimeout) {
      return _result;
    }
    final completedWindow = _closeWindow();
    _probabilities.clear();
    _result = Mg24AudioFeatureSnoreResult(
      available: false,
      active: false,
      detectedNow: false,
      rawProbability: 0,
      smoothedProbability: 0,
      inferenceId: _inferenceId,
      burstCounter: _burstCounter,
      updatedAt: at,
      completedWindow: completedWindow,
      snoreRatePerMin: _snoreRatePerMin(),
    );
    return _result;
  }

  Mg24AudioFeatureSnoreWindow? _closeWindow() {
    final start = _activeStartAt;
    final end = _activeEndAt;
    _activeStartAt = null;
    _activeEndAt = null;
    if (start == null || end == null || !end.isAfter(start)) return null;
    final window = Mg24AudioFeatureSnoreWindow(
      startAt: start,
      endAt: end.add(_blockPeriod),
    );
    if (window.endAt.difference(window.startAt) < _minimumWindow) return null;
    _completedWindowEnds.addLast(window.endAt);
    while (_completedWindowEnds.length > 8) {
      _completedWindowEnds.removeFirst();
    }
    return window;
  }

  double? _snoreRatePerMin() {
    if (_completedWindowEnds.length < 3) return null;
    final intervals = <double>[];
    final ends = _completedWindowEnds.toList(growable: false);
    for (var i = 1; i < ends.length; i++) {
      final interval = ends[i].difference(ends[i - 1]).inMilliseconds / 1000.0;
      if (interval >= 1.4 && interval <= 12.0) {
        intervals.add(interval);
      }
    }
    if (intervals.length < 2) return null;
    final period = median(intervals);
    if (!period.isFinite || period <= 0) return null;
    return 60.0 / period;
  }

  List<double>? _featuresFromSample(Mg24SensorSample sample) {
    final rmsDb = sample.snoreRmsDb;
    final values = <double?>[
      sample.snoreScore,
      rmsDb == null
          ? null
          : (((rmsDb - snoreVolumeMinDbfs) /
                      (snoreVolumeMaxDbfs - snoreVolumeMinDbfs)) *
                  100.0)
              .clamp(0.0, 100.0)
              .toDouble(),
      sample.snoreLevelRatioPercent,
      sample.snoreLowRatioPercent,
      sample.snoreCrossingRatePercent,
      sample.snoreRawSwing,
      rmsDb,
      sample.snoreAudioBand0To150Percent,
      sample.snoreAudioBand150To300Percent,
      sample.snoreAudioBand300To600Percent,
      sample.snoreAudioBand600To1200Percent,
      sample.snoreAudioBand1200To3000Percent,
    ];
    if (values.length != _featureCount ||
        values.any((value) => value == null || !value.isFinite)) {
      return null;
    }
    return values.cast<double>().toList(growable: false);
  }

  bool _isUsableFrame(Mg24SensorSample sample) {
    final rawSwing = sample.snoreRawSwing;
    final rmsDb = sample.snoreRmsDb;
    if (rawSwing == null || rmsDb == null) return false;
    if (!rawSwing.isFinite || !rmsDb.isFinite) return false;
    return rawSwing >= 3.0 && rmsDb > -69.5;
  }

  double _mlProbability(List<double> rawFeatures) {
    final hidden = List<double>.filled(_b1.length, 0);
    for (var h = 0; h < hidden.length; h++) {
      var z = _b1[h];
      for (var i = 0; i < _featureCount; i++) {
        final scale = _scale[i].abs() > 1e-6 ? _scale[i] : 1.0;
        final x = (rawFeatures[i] - _mean[i]) / scale;
        z += _w1[i * hidden.length + h] * x;
      }
      hidden[h] = z > 0 ? z : 0;
    }
    var out = _b2;
    for (var h = 0; h < hidden.length; h++) {
      out += _w2[h] * hidden[h];
    }
    out = out.clamp(-60.0, 60.0).toDouble();
    return 1.0 / (1.0 + math.exp(-out));
  }
}

class _FeatureProbability {
  const _FeatureProbability(this.receivedAt, this.probability);

  final DateTime receivedAt;
  final double probability;
}
