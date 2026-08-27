import 'dart:collection';
import 'dart:math' as math;

import 'models.dart';

const samplingRate = 100;
const mg24SamplingRate = 25;
const blockSize = 20;
const audioSamplingRate = 16000;
const plotSeconds = 6;
const mg24BreathingPlotSeconds = 18;
const csvWriteIntervalSeconds = 10.0;
const yamnetInputSamples = 15600;
// Run overlapping YAMNet windows densely enough to localize the beginning of
// a snore burst. The model still receives its native 975 ms input window.
const yamnetInferenceSeconds = 0.10;
const yamnetSnoreThreshold = 0.10;
const yamnetMeasurementSnoreThreshold = 0.50;
const yamnetMeasurementMinimumConsecutiveFrames = 2;
const yamnetRawTeacherSnoreThreshold = 0.80;
const yamnetRawTeacherWindowMergeGapSeconds = 0.20;
const yamnetScoreSmoothing = 0.45;
const snoreOffsetSeconds = 10.0;
const snoreVolumeMinDbfs = -70.0;
const snoreVolumeMaxDbfs = 0.0;

const csvColumns = [
  'uhrzeit',
  'heart_rate_bpm',
  'breathing_rate_per_min',
  'oxygen_saturation_percent',
  'snore',
  'snore_seconds',
  'snore_volume_percent',
  'snore_source',
  'snore_source_confidence_percent',
  'forehead_angle_deg',
  'chest_angle_deg',
  'relative_angle_deg',
  'relative_yaw_deg',
  'relative_yaw_quality_percent',
  'mg24_connected',
  'mg24_forehead_connected',
  'mg24_belly_connected',
  'mg24_forehead_battery_percent',
  'mg24_belly_battery_percent',
  'mg24_forehead_battery_voltage_v',
  'mg24_belly_battery_voltage_v',
  'mg24_forehead_ear_temperature_c',
  'mg24_forehead_angle_deg',
  'mg24_belly_angle_deg',
  'mg24_forehead_roll_deg',
  'mg24_forehead_pitch_deg',
  'mg24_forehead_yaw_deg',
  'mg24_belly_roll_deg',
  'mg24_belly_pitch_deg',
  'mg24_belly_yaw_deg',
  'ppg_quality_percent',
  'breathing_quality_percent',
  'radar_connected',
  'radar_person_detected',
  'radar_target_count',
  'radar_distance_cm',
  'radar_heart_rate_bpm',
  'radar_breathing_rate_per_min',
  'radar_illuminance_lx',
];

double adcToEcgMv(num adcValue) {
  const vcc = 3.3;
  const adcBits = 10;
  const ecgGain = 1100;
  return (((adcValue / math.pow(2, adcBits)) - 0.5) * vcc / ecgGain) * 1000;
}

double log10(num value) => math.log(value) / math.ln10;

double percentile(Iterable<double> values, double p) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return 0;
  if (sorted.length == 1) return sorted.first;
  final rank = (p / 100) * (sorted.length - 1);
  final low = rank.floor();
  final high = rank.ceil();
  if (low == high) return sorted[low];
  final weight = rank - low;
  return sorted[low] * (1 - weight) + sorted[high] * weight;
}

double median(Iterable<double> values) => percentile(values, 50);

class PpgProcessingResult {
  const PpgProcessingResult({
    required this.rawWaveform,
    required this.waveform,
    required this.peaks,
    required this.heartRateBpm,
    required this.qualityPercent,
  });

  final List<double> rawWaveform;
  final List<double> waveform;
  final List<bool> peaks;
  final double? heartRateBpm;
  final double qualityPercent;
}

class PpgSignalProcessor {
  PpgSignalProcessor({
    this.sampleRateHz = 25,
    this.maximumSamples = 150,
  })  : _signalFilter = PhysiologicalSignalFilter(
          sampleRateHz: sampleRateHz,
          baselineSeconds: 1.15,
          lowPassCutoffHz: 2.15,
          medianWindowSize: 3,
        ),
        _lookaheadSamples = math.max(3, (sampleRateHz * 0.20).round()),
        _refractorySamples = math.max(5, (sampleRateHz * 0.29).round());

  final double sampleRateHz;
  final int maximumSamples;
  final PhysiologicalSignalFilter _signalFilter;
  final int _lookaheadSamples;
  final int _refractorySamples;

  final List<double> _rawWaveform = <double>[];
  final List<double> _waveform = <double>[];
  final List<bool> _peaks = <bool>[];
  final Queue<int> _acceptedPeakSamples = Queue<int>();

  double? _heartRateBpm;
  double _qualityPercent = 0;
  int _polarity = 0;
  int _totalSamples = 0;
  int? _lastPeakSample;

  PpgProcessingResult update(double rawValue) {
    if (!rawValue.isFinite || rawValue <= 0) return _result();

    final baselineBeforeUpdate = _signalFilter.baseline;
    if (baselineBeforeUpdate != null &&
        _waveform.length >= sampleRateHz * 0.8) {
      final levelStep = (rawValue - baselineBeforeUpdate).abs();
      final levelStepThreshold =
          math.max(12000.0, baselineBeforeUpdate.abs() * 0.11);
      if (levelStep > levelStepThreshold) {
        _resetSignalState();
      }
    }

    final filtered = _signalFilter.update(rawValue);

    _rawWaveform.add(rawValue);
    _waveform.add(filtered);
    _peaks.add(false);
    _totalSamples++;
    while (_waveform.length > maximumSamples) {
      _rawWaveform.removeAt(0);
      _waveform.removeAt(0);
      _peaks.removeAt(0);
    }

    _choosePolarityWhenReady();
    _detectConfirmedPeak();
    _expireStaleHeartRate();
    _qualityPercent = _estimateQuality();
    return _result();
  }

  void reset() {
    _resetSignalState();
  }

  void _resetSignalState() {
    _signalFilter.reset();
    _rawWaveform.clear();
    _waveform.clear();
    _peaks.clear();
    _acceptedPeakSamples.clear();
    _heartRateBpm = null;
    _qualityPercent = 0;
    _polarity = 0;
    _totalSamples = 0;
    _lastPeakSample = null;
  }

  void _choosePolarityWhenReady() {
    if (_polarity != 0 || _waveform.length < sampleRateHz * 1.4) return;
    final recentCount = math.min(_waveform.length, (sampleRateHz * 3).round());
    final recent = _waveform.sublist(_waveform.length - recentCount);
    final middle = median(recent);
    final positiveExcursion = percentile(recent, 96) - middle;
    final negativeExcursion = middle - percentile(recent, 4);
    _polarity = negativeExcursion > positiveExcursion * 1.08 ? -1 : 1;
  }

  void _detectConfirmedPeak() {
    if (_polarity == 0 ||
        _waveform.length < math.max(24, (sampleRateHz * 1.5).round())) {
      return;
    }

    final oriented = _orientedWaveform();
    final center = oriented.length - 1 - _lookaheadSamples;
    if (center < 3) return;

    const topRadius = 2;
    final topStart = math.max(1, center - topRadius);
    final topEnd = math.min(oriented.length - 1, center + topRadius + 1);
    var topValue = double.negativeInfinity;
    for (var i = topStart; i < topEnd; i++) {
      topValue = math.max(topValue, oriented[i]);
    }

    final historyStart = math.max(0, center - (sampleRateHz * 3).round());
    final history = oriented.sublist(historyStart, topEnd);
    final middle = median(history);
    final high = percentile(history, 92);
    final low = percentile(history, 8);
    final robustSpan = high - low;
    if (!robustSpan.isFinite || robustSpan <= 1e-9) return;

    final nearTopTolerance = math.max(1e-9, robustSpan * 0.045);
    final nearTop = <int>[];
    for (var i = topStart; i < topEnd; i++) {
      if (oriented[i] >= topValue - nearTopTolerance) nearTop.add(i);
    }
    if (nearTop.isEmpty) return;
    final peakIndex = nearTop[nearTop.length ~/ 2];
    final peakValue = oriented[peakIndex];

    final sideSamples = math.max(5, (sampleRateHz * 0.44).round());
    final leftStart = math.max(0, peakIndex - sideSamples);
    final rightEnd =
        math.min(oriented.length, peakIndex + _lookaheadSamples + 1);
    var leftMin = peakValue;
    var rightMin = peakValue;
    for (var i = leftStart; i <= peakIndex; i++) {
      leftMin = math.min(leftMin, oriented[i]);
    }
    for (var i = peakIndex; i < rightEnd; i++) {
      rightMin = math.min(rightMin, oriented[i]);
    }

    final differences = <double>[];
    for (var i = 1; i < history.length; i++) {
      differences.add((history[i] - history[i - 1]).abs());
    }
    final noise = differences.isEmpty ? 0.0 : median(differences);
    final prominence = math.min(peakValue - leftMin, peakValue - rightMin);
    final threshold = middle + math.max(robustSpan * 0.16, noise * 2.0);
    final minimumProminence = math.max(robustSpan * 0.13, noise * 1.8);
    if (peakValue < threshold || prominence < minimumProminence) return;

    final supportLevel = middle + (peakValue - middle) * 0.58;
    var supportSamples = 1;
    for (var i = peakIndex - 1;
        i >= math.max(0, peakIndex - 4) && oriented[i] >= supportLevel;
        i--) {
      supportSamples++;
    }
    for (var i = peakIndex + 1;
        i < math.min(oriented.length, peakIndex + 5) &&
            oriented[i] >= supportLevel;
        i++) {
      supportSamples++;
    }
    if (supportSamples < 3) return;

    final absoluteIndex = _totalSamples - oriented.length + peakIndex;
    final lastPeak = _lastPeakSample;
    final minimumPeakDistance = math.max(
      _refractorySamples,
      (_expectedPeakIntervalSamples() * 0.52).round(),
    );
    if (lastPeak != null && absoluteIndex - lastPeak < minimumPeakDistance) {
      return;
    }

    _peaks[peakIndex] = true;
    _lastPeakSample = absoluteIndex;
    _acceptedPeakSamples.addLast(absoluteIndex);
    while (_acceptedPeakSamples.length > 9) {
      _acceptedPeakSamples.removeFirst();
    }
    _updateHeartRate();
  }

  double _expectedPeakIntervalSamples() {
    if (_acceptedPeakSamples.length < 3) {
      return _refractorySamples.toDouble();
    }
    final peaks = _acceptedPeakSamples.toList(growable: false);
    return median(<double>[
      for (var i = 1; i < peaks.length; i++)
        (peaks[i] - peaks[i - 1]).toDouble(),
    ]);
  }

  void _updateHeartRate() {
    if (_acceptedPeakSamples.length < 3) return;
    final peakSamples = _acceptedPeakSamples.toList(growable: false);
    final intervals = <double>[];
    for (var i = 1; i < peakSamples.length; i++) {
      final interval = (peakSamples[i] - peakSamples[i - 1]).toDouble();
      final seconds = interval / sampleRateHz;
      if (seconds >= 0.29 && seconds <= 1.72) intervals.add(interval);
    }
    if (intervals.length < 2) return;

    final intervalMedian = median(intervals);
    final acceptedIntervals = intervals
        .where((value) =>
            value >= intervalMedian * 0.68 && value <= intervalMedian * 1.38)
        .toList(growable: false);
    if (acceptedIntervals.length < 2) return;
    final bpm = 60 * sampleRateHz / median(acceptedIntervals);
    if (!bpm.isFinite || bpm < 35 || bpm > 205) return;

    final previous = _heartRateBpm;
    if (previous == null || !previous.isFinite) {
      _heartRateBpm = bpm;
      return;
    }
    final delta = (bpm - previous).abs();
    final weight = delta > 18 ? 0.18 : 0.32;
    _heartRateBpm = previous * (1 - weight) + bpm * weight;
  }

  void _expireStaleHeartRate() {
    final lastPeak = _lastPeakSample;
    if (lastPeak == null || _totalSamples - lastPeak <= sampleRateHz * 3.0) {
      return;
    }
    _heartRateBpm = null;
    _lastPeakSample = null;
    _acceptedPeakSamples.clear();
  }

  double _estimateQuality() {
    if (_polarity == 0 || _waveform.length < sampleRateHz * 2) return 0;
    final oriented = _orientedWaveform();
    final count = math.min(oriented.length, (sampleRateHz * 4).round());
    final recent = oriented.sublist(oriented.length - count);
    final span = percentile(recent, 92) - percentile(recent, 8);
    if (!span.isFinite || span <= 1e-9) return 0;

    final differences = <double>[];
    for (var i = 1; i < recent.length; i++) {
      differences.add((recent[i] - recent[i - 1]).abs());
    }
    final noise = math.max(1e-9, median(differences));
    final shapeScore = ((span / noise - 2.0) / 9.0).clamp(0.0, 1.0);

    var rhythmScore = 0.0;
    if (_acceptedPeakSamples.length >= 3) {
      final peaks = _acceptedPeakSamples.toList(growable: false);
      final intervals = <double>[
        for (var i = 1; i < peaks.length; i++)
          (peaks[i] - peaks[i - 1]).toDouble(),
      ];
      final middle = median(intervals);
      if (middle > 0) {
        final deviations = intervals.map((value) => (value - middle).abs());
        rhythmScore = (1 - median(deviations) / middle / 0.22).clamp(0.0, 1.0);
      }
    }
    return (100 * (0.68 * shapeScore + 0.32 * rhythmScore))
        .clamp(0.0, 100.0)
        .toDouble();
  }

  List<double> _orientedWaveform() {
    final sign = _polarity < 0 ? -1.0 : 1.0;
    return _waveform.map((value) => value * sign).toList(growable: false);
  }

  PpgProcessingResult _result() {
    return PpgProcessingResult(
      rawWaveform: List<double>.unmodifiable(_rawWaveform),
      waveform: _orientedWaveform(),
      peaks: List<bool>.unmodifiable(_peaks),
      heartRateBpm: _heartRateBpm,
      qualityPercent: _qualityPercent,
    );
  }
}

class MovingAverage {
  MovingAverage(this.size);

  final int size;
  final Queue<double> _values = Queue<double>();
  double _total = 0;

  double update(num value) {
    final next = value.toDouble();
    _values.addLast(next);
    _total += next;
    while (_values.length > size) {
      _total -= _values.removeFirst();
    }
    return _total / _values.length;
  }
}

class ExponentialFilter {
  ExponentialFilter(
    int fs,
    double timeConstantSeconds, [
    double? initialValue,
  ])  : _alpha = 1 - math.exp(-1 / (fs * timeConstantSeconds)),
        _value = initialValue;

  final double _alpha;
  double? _value;

  double update(num value) {
    final next = value.toDouble();
    final current = _value;
    if (current == null) {
      _value = next;
    } else {
      _value = current + _alpha * (next - current);
    }
    return _value!;
  }
}

/// Shared live filter for slow physiological waveforms.
///
/// The median stage removes isolated samples, the adaptive baseline removes
/// sensor drift, and the Butterworth stage smooths without stacking several
/// slow exponential filters. The same pipeline is used for PPG and breathing;
/// only its physiological time and frequency parameters differ.
class PhysiologicalSignalFilter {
  PhysiologicalSignalFilter({
    required this.sampleRateHz,
    required this.baselineSeconds,
    required this.lowPassCutoffHz,
    this.medianWindowSize = 3,
  })  : assert(sampleRateHz > 0),
        assert(baselineSeconds > 0),
        assert(lowPassCutoffHz > 0),
        assert(medianWindowSize > 0 && medianWindowSize.isOdd),
        _baselineAlpha = 1 - math.exp(-1 / (sampleRateHz * baselineSeconds)),
        _lowPass = _ButterworthLowPass(
          sampleRateHz: sampleRateHz,
          cutoffHz: lowPassCutoffHz,
        );

  final double sampleRateHz;
  final double baselineSeconds;
  final double lowPassCutoffHz;
  final int medianWindowSize;
  final double _baselineAlpha;
  final _ButterworthLowPass _lowPass;
  final Queue<double> _medianWindow = Queue<double>();

  double? _baseline;

  double? get baseline => _baseline;

  double update(num input) {
    final raw = input.toDouble();
    if (!raw.isFinite) return 0;

    _medianWindow.addLast(raw);
    while (_medianWindow.length > medianWindowSize) {
      _medianWindow.removeFirst();
    }
    final cleaned = median(_medianWindow);
    final previousBaseline = _baseline;
    if (previousBaseline == null) {
      _baseline = cleaned;
      _lowPass.reset();
      return 0;
    }

    final nextBaseline =
        previousBaseline + _baselineAlpha * (cleaned - previousBaseline);
    _baseline = nextBaseline;
    return _lowPass.update(cleaned - nextBaseline);
  }

  void reset() {
    _medianWindow.clear();
    _baseline = null;
    _lowPass.reset();
  }
}

class _ButterworthLowPass {
  _ButterworthLowPass({
    required double sampleRateHz,
    required double cutoffHz,
  }) {
    final safeCutoff = cutoffHz.clamp(0.001, sampleRateHz * 0.45).toDouble();
    final omega = 2 * math.pi * safeCutoff / sampleRateHz;
    final cosine = math.cos(omega);
    final sine = math.sin(omega);
    final alpha = sine / (2 * math.sqrt1_2);
    final a0 = 1 + alpha;
    _b0 = ((1 - cosine) / 2) / a0;
    _b1 = (1 - cosine) / a0;
    _b2 = _b0;
    _a1 = (-2 * cosine) / a0;
    _a2 = (1 - alpha) / a0;
  }

  late final double _b0;
  late final double _b1;
  late final double _b2;
  late final double _a1;
  late final double _a2;
  double _x1 = 0;
  double _x2 = 0;
  double _y1 = 0;
  double _y2 = 0;

  double update(double input) {
    final output = _b0 * input + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = input;
    _y2 = _y1;
    _y1 = output;
    return output;
  }

  void reset() {
    _x1 = 0;
    _x2 = 0;
    _y1 = 0;
    _y2 = 0;
  }
}

class _SlidingMedianFilter {
  _SlidingMedianFilter(this.windowSize)
      : assert(windowSize > 0 && windowSize.isOdd);

  final int windowSize;
  final Queue<double> _values = Queue<double>();

  double update(num input) {
    _values.addLast(input.toDouble());
    while (_values.length > windowSize) {
      _values.removeFirst();
    }
    return median(_values);
  }
}

class HeartResult {
  const HeartResult({
    required this.heartRate,
    required this.isPeak,
    required this.filteredEcg,
    required this.qrsValue,
    required this.peakValue,
  });

  final double? heartRate;
  final bool isPeak;
  final double filteredEcg;
  final double qrsValue;
  final double? peakValue;
}

class HeartRateDetector {
  HeartRateDetector(this.fs)
      : _baseline = MovingAverage((0.6 * fs).round()),
        _smoothing = MovingAverage(math.max(1, (0.03 * fs).round()));

  static const _minimumReliableRrSeconds = 0.50;
  static const _maximumReliableRrSeconds = 2.00;
  static const _earlyLockMinimumRrSeconds = 0.58;
  static const _shortRrRatio = 0.70;
  static const _longRrRatio = 1.85;
  static const _shortPeakAmplitudeRatio = 0.80;
  static const _heartRateSmoothing = 0.30;

  final int fs;
  final MovingAverage _baseline;
  final MovingAverage _smoothing;
  final Queue<double> _filteredHistory = Queue<double>();
  final Queue<double> _qrsHistory = Queue<double>();
  final Queue<double> _rrIntervals = Queue<double>();

  int _sampleIndex = 0;
  double? currentHr;
  int? _peakSign;
  double _previousQrs = 0;
  double _qrsBeforePrevious = 0;
  double? _threshold;
  int? _lastPeakIndex;
  double? _lastPeakQrs;

  HeartResult update(num ecgMv) {
    final baseline = _baseline.update(ecgMv);
    final filteredEcg = _smoothing.update(ecgMv - baseline);
    _pushLimited(_filteredHistory, filteredEcg, 3 * fs);
    _chooseAutoPeakSign();

    final peakSign = _peakSign;
    if (peakSign == null) {
      _sampleIndex++;
      return HeartResult(
        heartRate: currentHr,
        isPeak: false,
        filteredEcg: filteredEcg,
        qrsValue: filteredEcg,
        peakValue: null,
      );
    }

    final qrsValue = filteredEcg * peakSign;
    _pushLimited(_qrsHistory, qrsValue, 2 * fs);
    if (_sampleIndex % 50 == 0 && _qrsHistory.length > fs) {
      final middle = median(_qrsHistory);
      final high = percentile(_qrsHistory, 98);
      _threshold = middle + 0.50 * (high - middle);
    }

    var isPeak = false;
    double? peakValue;
    final enoughWarmup = _sampleIndex > fs;
    final enoughDistance =
        _lastPeakIndex == null || _sampleIndex - _lastPeakIndex! > 0.40 * fs;

    if (enoughWarmup &&
        enoughDistance &&
        _threshold != null &&
        _previousQrs > _qrsBeforePrevious &&
        _previousQrs >= qrsValue &&
        _previousQrs > _threshold!) {
      final peakIndex = _sampleIndex - 1;
      final peakTime = peakIndex / fs;
      final lastPeakIndex = _lastPeakIndex;
      final peakQrs = _previousQrs;
      final shouldAcceptPeak = lastPeakIndex == null ||
          _isPlausibleRr(
            peakTime - lastPeakIndex / fs,
            peakQrs: peakQrs,
          );

      if (shouldAcceptPeak && lastPeakIndex != null) {
        final rrInterval = peakTime - lastPeakIndex / fs;
        _pushLimited(_rrIntervals, rrInterval, 5);
        if (_rrIntervals.length >= 3) {
          currentHr = _smoothHeartRate(60 / median(_rrIntervals));
        }
      }

      if (shouldAcceptPeak) {
        _lastPeakIndex = peakIndex;
        _lastPeakQrs = peakQrs;
        isPeak = true;
        peakValue = peakQrs * peakSign;
      }
    }

    final lastPeakIndex = _lastPeakIndex;
    if (lastPeakIndex != null && (_sampleIndex - lastPeakIndex) / fs > 3) {
      currentHr = null;
    }

    _qrsBeforePrevious = _previousQrs;
    _previousQrs = qrsValue;
    _sampleIndex++;

    return HeartResult(
      heartRate: currentHr,
      isPeak: isPeak,
      filteredEcg: filteredEcg,
      qrsValue: qrsValue,
      peakValue: peakValue,
    );
  }

  void _chooseAutoPeakSign() {
    if (_peakSign != null || _filteredHistory.length < 3 * fs) return;
    final positivePeak = percentile(_filteredHistory, 98);
    final negativePeak = percentile(_filteredHistory, 2).abs();
    _peakSign = negativePeak > positivePeak ? -1 : 1;
  }

  bool _isPlausibleRr(double rrInterval, {required double peakQrs}) {
    if (rrInterval < _minimumReliableRrSeconds ||
        rrInterval > _maximumReliableRrSeconds) {
      return false;
    }

    final previousMedian = _rrIntervals.isEmpty ? null : median(_rrIntervals);
    final lastPeakQrs = _lastPeakQrs;
    if (previousMedian == null) {
      if (rrInterval >= _earlyLockMinimumRrSeconds) return true;
      return lastPeakQrs != null &&
          peakQrs >= lastPeakQrs * _shortPeakAmplitudeRatio;
    }

    if (rrInterval < previousMedian * _shortRrRatio) {
      return lastPeakQrs != null &&
          peakQrs >= lastPeakQrs * _shortPeakAmplitudeRatio;
    }

    if (rrInterval > previousMedian * _longRrRatio &&
        _rrIntervals.length >= 3) {
      return false;
    }

    return true;
  }

  double _smoothHeartRate(double candidateHeartRate) {
    final previous = currentHr;
    if (previous == null) return candidateHeartRate;
    return previous * (1 - _heartRateSmoothing) +
        candidateHeartRate * _heartRateSmoothing;
  }
}

class BreathingResult {
  const BreathingResult({
    required this.breathingRate,
    required this.isBreath,
    required this.filteredResp,
    required this.breathValue,
    required this.breathPeakTime,
    required this.breathPeakValue,
    this.axisLabel,
    this.qualityPercent = 0,
  });

  final double? breathingRate;
  final bool isBreath;
  final double filteredResp;
  final double breathValue;
  final double? breathPeakTime;
  final double? breathPeakValue;
  final String? axisLabel;
  final double qualityPercent;
}

class _BreathWindowItem {
  const _BreathWindowItem(this.index, this.signal, this.filtered, this.timeS);

  final int index;
  final double signal;
  final double filtered;
  final double? timeS;
}

class BreathingRateDetector {
  BreathingRateDetector(
    this.fs, {
    double baselineSeconds = 8,
    double smoothingSeconds = 0.08,
    double lookaheadSeconds = 2.0,
    double peakNeighborSeconds = 0.5,
    double warmupSeconds = 5.0,
    double minBreathIntervalSeconds = 1.8,
    double maxBreathIntervalSeconds = 12.0,
    double thresholdFactor = 0.35,
    double minAutocorrelationSpan = 0.02,
  })  : _signalFilter = PhysiologicalSignalFilter(
          sampleRateHz: fs.toDouble(),
          baselineSeconds: baselineSeconds,
          lowPassCutoffHz: 1 / (2 * math.pi * smoothingSeconds),
          medianWindowSize: 3,
        ),
        _lookaheadSamples = (lookaheadSeconds * fs).round(),
        _peakNeighborSamples = math.max(1, (peakNeighborSeconds * fs).round()),
        _warmupSeconds = warmupSeconds,
        _minBreathIntervalSeconds = minBreathIntervalSeconds,
        _maxBreathIntervalSeconds = maxBreathIntervalSeconds,
        _thresholdFactor = thresholdFactor,
        _minAutocorrelationSpan = minAutocorrelationSpan;

  final int fs;
  final PhysiologicalSignalFilter _signalFilter;
  final int _lookaheadSamples;
  final int _peakNeighborSamples;
  final double _warmupSeconds;
  final double _minBreathIntervalSeconds;
  final double _maxBreathIntervalSeconds;
  final double _thresholdFactor;
  final double _minAutocorrelationSpan;
  final Queue<double> _filteredHistory = Queue<double>();
  final Queue<double> _displayHistory = Queue<double>();
  final Queue<double> _breathIntervals = Queue<double>();
  final Queue<_BreathWindowItem> _peakWindow = Queue<_BreathWindowItem>();

  int _sampleIndex = 0;
  double? currentRate;
  double? _previousRaw;
  double? _threshold;
  double? _displayThreshold;
  double? _signalMedian;
  double? _displayMedian;
  double _signalSpan = 0;
  double _displaySpan = 0;
  int? _lastBreathIndex;
  double? _lastBreathTimeS;
  double _periodicity = 0;

  double get detectionDelaySeconds => _lookaheadSamples / fs;

  double get periodicity => _periodicity;

  double get signalSpan {
    if (_filteredHistory.length < math.max(8, 3 * fs)) return 0;
    return percentile(_filteredHistory, 92) - percentile(_filteredHistory, 8);
  }

  BreathingResult update(num respRaw, {double? timeS}) {
    final raw = _cleanRawValue(respRaw);
    final detectionResp = _signalFilter.update(raw);
    final displayResp = detectionResp;
    _pushLimited(_filteredHistory, detectionResp, 20 * fs);
    _pushLimited(_displayHistory, displayResp, 20 * fs);

    final enoughWarmupForRate = _sampleIndex > _warmupSeconds * fs;
    if (enoughWarmupForRate &&
        _sampleIndex % fs == 0 &&
        _filteredHistory.length > 3 * fs) {
      final middle = median(_filteredHistory);
      final high = percentile(_filteredHistory, 90);
      final low = percentile(_filteredHistory, 10);
      _signalSpan = high - low;
      _signalMedian = middle;
      _threshold = middle + _thresholdFactor * (high - middle);
      final displayMiddle = median(_displayHistory);
      final displayHigh = percentile(_displayHistory, 90);
      final displayLow = percentile(_displayHistory, 10);
      _displaySpan = displayHigh - displayLow;
      _displayMedian = displayMiddle;
      _displayThreshold =
          displayMiddle + _thresholdFactor * (displayHigh - displayMiddle);
      _updateRateFromAutocorrelation();
    }

    _peakWindow.addLast(_BreathWindowItem(
      _sampleIndex,
      detectionResp,
      displayResp,
      timeS?.isFinite == true ? timeS : null,
    ));
    final maxWindowLength = 2 * _lookaheadSamples + 1;
    while (_peakWindow.length > maxWindowLength) {
      _peakWindow.removeFirst();
    }

    var isBreath = false;
    double? breathPeakTime;
    double? breathPeakValue;

    if (_peakWindow.length == maxWindowLength) {
      final window = _peakWindow.toList(growable: false);
      final candidate = window[_lookaheadSamples];
      final localStart = math.max(0, _lookaheadSamples - _peakNeighborSamples);
      final localEnd =
          math.min(window.length, _lookaheadSamples + _peakNeighborSamples + 1);
      final localDetectionWindow = window.sublist(localStart, localEnd);
      final localMax =
          localDetectionWindow.map((item) => item.signal).reduce(math.max);
      final localDisplayMax =
          localDetectionWindow.map((item) => item.filtered).reduce(math.max);
      final signalPeakTolerance = math.max(1e-9, 0.08 * _signalSpan);
      final displayPeakTolerance = math.max(1e-9, 0.08 * _displaySpan);
      final nearDetectionMax =
          candidate.signal >= localMax - signalPeakTolerance;
      final nearDisplayMax =
          candidate.filtered >= localDisplayMax - displayPeakTolerance;
      final prominentEnough =
          _hasBreathLikeProminence(window) || _hasBroadPeakSupport(window);
      final enoughWarmup = candidate.index > _warmupSeconds * fs;
      final candidateTime = candidate.timeS ?? candidate.index / fs;
      final enoughDistance =
          _enoughDistanceFromLastBreath(candidateTime, candidate.index);
      final detectionPeak = _threshold != null &&
          nearDetectionMax &&
          candidate.signal > _threshold! &&
          prominentEnough;
      final displayPeakCandidate = _displayThreshold != null &&
          nearDisplayMax &&
          candidate.filtered > _displayThreshold! &&
          prominentEnough;
      final rhythmPeak = _isRhythmicCandidate(candidateTime) &&
          _passesSoftPeakThreshold(candidate) &&
          prominentEnough &&
          (nearDetectionMax || nearDisplayMax);
      final visualRecoveryPeak = _isVisualRecoveryPeak(window);

      if (enoughWarmup &&
          enoughDistance &&
          (detectionPeak ||
              displayPeakCandidate ||
              rhythmPeak ||
              visualRecoveryPeak)) {
        final displayPeak = _displayPeakNearCandidate(window);
        breathPeakTime = displayPeak.timeS ?? displayPeak.index / fs;
        breathPeakValue = displayPeak.filtered;
        final lastBreathTime = _lastBreathTimeS ??
            (_lastBreathIndex == null ? null : _lastBreathIndex! / fs);
        if (lastBreathTime != null) {
          final interval = breathPeakTime - lastBreathTime;
          if (interval >= _minBreathIntervalSeconds &&
              interval <= _maxBreathIntervalSeconds) {
            _pushLimited(_breathIntervals, interval, 8);
            currentRate = _smoothBreathingRate(60 / median(_breathIntervals));
          }
        }
        _lastBreathIndex = displayPeak.index;
        _lastBreathTimeS = breathPeakTime;
        isBreath = true;
      }
    }

    final lastBreathIndex = _lastBreathIndex;
    final lastBreathTime = _lastBreathTimeS;
    final staleSeconds = lastBreathTime != null && timeS != null
        ? timeS - lastBreathTime
        : lastBreathIndex == null
            ? 0.0
            : (_sampleIndex - lastBreathIndex) / fs;
    if (lastBreathIndex != null && staleSeconds > _maxBreathIntervalSeconds) {
      currentRate = null;
    }

    _sampleIndex++;
    return BreathingResult(
      breathingRate: currentRate,
      isBreath: isBreath,
      filteredResp: displayResp,
      breathValue: detectionResp,
      breathPeakTime: breathPeakTime,
      breathPeakValue: breathPeakValue,
      qualityPercent: _qualityFromSpan(signalSpan),
    );
  }

  _BreathWindowItem _displayPeakNearCandidate(List<_BreathWindowItem> window) {
    final mapWindowSamples = math.max(1, (0.35 * fs).round());
    final localStart = math.max(0, _lookaheadSamples - mapWindowSamples);
    final localEnd =
        math.min(window.length, _lookaheadSamples + mapWindowSamples + 1);
    var best = window[_lookaheadSamples];
    for (var i = localStart; i < localEnd; i++) {
      final item = window[i];
      if (item.filtered > best.filtered) {
        best = item;
      }
    }
    return best;
  }

  bool _isRhythmicCandidate(double candidateTime) {
    final last = _lastBreathTimeS;
    if (last == null) return false;
    final expected = _expectedBreathIntervalSeconds();
    if (expected == null) return false;
    final interval = candidateTime - last;
    return interval >= math.max(_minBreathIntervalSeconds, expected * 0.62) &&
        interval <= math.min(_maxBreathIntervalSeconds, expected * 1.42);
  }

  bool _enoughDistanceFromLastBreath(double candidateTime, int candidateIndex) {
    final expected = _expectedBreathIntervalSeconds();
    final minimumInterval = expected == null
        ? _minBreathIntervalSeconds
        : math.max(_minBreathIntervalSeconds, expected * 0.46);
    final lastTime = _lastBreathTimeS;
    if (lastTime != null) {
      return candidateTime - lastTime > minimumInterval;
    }
    final lastIndex = _lastBreathIndex;
    if (lastIndex == null) return true;
    return candidateIndex - lastIndex > minimumInterval * fs;
  }

  double? _expectedBreathIntervalSeconds() {
    if (_breathIntervals.isNotEmpty) return median(_breathIntervals);
    final rate = currentRate;
    if (rate == null || !rate.isFinite || rate <= 0) return null;
    return 60.0 / rate;
  }

  bool _passesSoftPeakThreshold(_BreathWindowItem candidate) {
    final signalMedian = _signalMedian;
    final threshold = _threshold;
    final displayMedian = _displayMedian;
    final displayThreshold = _displayThreshold;
    final signalPass = signalMedian != null &&
        threshold != null &&
        candidate.signal >
            signalMedian + 0.35 * math.max(0.0, threshold - signalMedian);
    final displayPass = displayMedian != null &&
        displayThreshold != null &&
        candidate.filtered >
            displayMedian +
                0.35 * math.max(0.0, displayThreshold - displayMedian);
    return signalPass || displayPass;
  }

  bool _hasBreathLikeProminence(List<_BreathWindowItem> window) {
    final candidate = window[_lookaheadSamples];
    final sideSamples = math.min(
      _lookaheadSamples,
      math.max(2, (1.05 * fs).round()),
    );
    final leftStart = math.max(0, _lookaheadSamples - sideSamples);
    final rightEnd =
        math.min(window.length, _lookaheadSamples + sideSamples + 1);
    final left = window.sublist(leftStart, _lookaheadSamples + 1);
    final right = window.sublist(_lookaheadSamples, rightEnd);
    final leftMinSignal = left.map((item) => item.signal).reduce(math.min);
    final rightMinSignal = right.map((item) => item.signal).reduce(math.min);
    final leftMinDisplay = left.map((item) => item.filtered).reduce(math.min);
    final rightMinDisplay = right.map((item) => item.filtered).reduce(math.min);
    final local = window.sublist(leftStart, rightEnd);
    final localSignalSpan = _spanOf(local.map((item) => item.signal));
    final localDisplaySpan = _spanOf(local.map((item) => item.filtered));
    final signalProminence = math.min(
      candidate.signal - leftMinSignal,
      candidate.signal - rightMinSignal,
    );
    final displayProminence = math.min(
      candidate.filtered - leftMinDisplay,
      candidate.filtered - rightMinDisplay,
    );
    final minSignalProminence =
        math.max(0.010, math.min(0.075 * _signalSpan, 0.22 * localSignalSpan));
    final minDisplayProminence = math.max(
        0.010, math.min(0.075 * _displaySpan, 0.22 * localDisplaySpan));
    return signalProminence >= minSignalProminence ||
        displayProminence >= minDisplayProminence;
  }

  bool _hasBroadPeakSupport(List<_BreathWindowItem> window) {
    final candidate = window[_lookaheadSamples];
    final sideSamples = math.min(
      _lookaheadSamples,
      math.max(2, (0.85 * fs).round()),
    );
    final leftIndex = math.max(0, _lookaheadSamples - sideSamples);
    final rightIndex =
        math.min(window.length - 1, _lookaheadSamples + sideSamples);
    final left = window[leftIndex];
    final right = window[rightIndex];
    final local = window.sublist(leftIndex, rightIndex + 1);
    final localSignalSpan = _spanOf(local.map((item) => item.signal));
    final localDisplaySpan = _spanOf(local.map((item) => item.filtered));

    final signalDrop = math.min(
      candidate.signal - left.signal,
      candidate.signal - right.signal,
    );
    final displayDrop = math.min(
      candidate.filtered - left.filtered,
      candidate.filtered - right.filtered,
    );
    final minSignalDrop =
        math.max(0.006, math.min(0.040 * _signalSpan, 0.18 * localSignalSpan));
    final minDisplayDrop = math.max(
        0.006, math.min(0.040 * _displaySpan, 0.18 * localDisplaySpan));
    return signalDrop >= minSignalDrop || displayDrop >= minDisplayDrop;
  }

  bool _isVisualRecoveryPeak(List<_BreathWindowItem> window) {
    final hasRhythmContext = currentRate != null ||
        _breathIntervals.length >= 2 ||
        _periodicity >= 0.34;
    if (!hasRhythmContext) return false;

    final candidate = window[_lookaheadSamples];
    final localStart = math.max(0, _lookaheadSamples - _peakNeighborSamples);
    final localEnd =
        math.min(window.length, _lookaheadSamples + _peakNeighborSamples + 1);
    final local = window.sublist(localStart, localEnd);
    if (local.length < 5) return false;

    final localSignalValues = local.map((item) => item.signal).toList();
    final localDisplayValues = local.map((item) => item.filtered).toList();
    final localSignalMax = localSignalValues.reduce(math.max);
    final localDisplayMax = localDisplayValues.reduce(math.max);
    final localSignalMedian = median(localSignalValues);
    final localDisplayMedian = median(localDisplayValues);
    final localSignalSpan = localSignalMax - localSignalValues.reduce(math.min);
    final localDisplaySpan =
        localDisplayMax - localDisplayValues.reduce(math.min);

    final nearSignalMax = candidate.signal >=
        localSignalMax - math.max(1e-9, 0.10 * localSignalSpan);
    final nearDisplayMax = candidate.filtered >=
        localDisplayMax - math.max(1e-9, 0.10 * localDisplaySpan);
    final signalHighEnough = candidate.signal >=
        localSignalMedian + math.max(0.006, 0.20 * localSignalSpan);
    final displayHighEnough = candidate.filtered >=
        localDisplayMedian + math.max(0.006, 0.20 * localDisplaySpan);
    return (nearSignalMax && signalHighEnough) ||
        (nearDisplayMax && displayHighEnough);
  }

  double _spanOf(Iterable<double> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) return 0;
    return list.reduce(math.max) - list.reduce(math.min);
  }

  void _updateRateFromAutocorrelation() {
    final values = _filteredHistory.toList(growable: false);
    final count = math.min(values.length, 24 * fs);
    if (count < 8 * fs) {
      _periodicity = 0;
      return;
    }
    final recent = values.sublist(values.length - count);
    final span = percentile(recent, 92) - percentile(recent, 8);
    if (!span.isFinite || span < _minAutocorrelationSpan) {
      _periodicity = 0;
      return;
    }

    final mean = recent.reduce((a, b) => a + b) / recent.length;
    final centered =
        recent.map((value) => value - mean).toList(growable: false);
    final minLag = math.max(1, (fs * 60 / 30).round());
    final maxLag = math.min(centered.length - 2, (fs * 60 / 5).round());
    var bestLag = 0;
    var bestScore = 0.0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      final score = _autocorrelationScore(centered, lag);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }
    _periodicity = bestScore.clamp(0.0, 1.0).toDouble();
    if (bestLag == 0 || bestScore < 0.48) return;

    final halfLag = (bestLag / 2).round();
    if (halfLag >= minLag) {
      final halfScore = _autocorrelationScore(centered, halfLag);
      if (halfScore > 0.46 && halfScore >= bestScore * 0.82) {
        bestLag = halfLag;
        bestScore = halfScore;
        _periodicity = halfScore.clamp(0.0, 1.0).toDouble();
      }
    }

    currentRate = _smoothBreathingRate(60 * fs / bestLag, smoothing: 0.14);
  }

  double _autocorrelationScore(List<double> centered, int lag) {
    var numerator = 0.0;
    var energyA = 0.0;
    var energyB = 0.0;
    for (var i = lag; i < centered.length; i++) {
      final a = centered[i];
      final b = centered[i - lag];
      numerator += a * b;
      energyA += a * a;
      energyB += b * b;
    }
    final denominator = math.sqrt(energyA * energyB);
    if (denominator <= 1e-9) return 0;
    return numerator / denominator;
  }

  double _smoothBreathingRate(double candidateRate, {double smoothing = 0.22}) {
    if (!candidateRate.isFinite || candidateRate <= 0) {
      return currentRate ?? candidateRate;
    }
    final previous = currentRate;
    if (previous == null || !previous.isFinite || previous <= 0) {
      return candidateRate;
    }
    final delta = (candidateRate - previous).abs();
    final adaptiveSmoothing = delta > 6 ? smoothing * 0.55 : smoothing;
    return previous * (1 - adaptiveSmoothing) +
        candidateRate * adaptiveSmoothing;
  }

  double _cleanRawValue(num respRaw) {
    final rawValue = respRaw.toDouble();
    if (!rawValue.isFinite) return _previousRaw ?? 0;

    var raw = rawValue;
    final previous = _previousRaw;
    if (previous != null) {
      final delta = (raw - previous).clamp(-25.0, 25.0);
      raw = previous + delta;
    }
    _previousRaw = raw;
    return raw;
  }

  double _qualityFromSpan(double span) {
    if (!span.isFinite || span <= 0) return 0;
    final spanScore = ((span - 0.03) / 1.1 * 34).clamp(0.0, 34.0);
    final periodicScore = ((_periodicity - 0.35) / 0.50 * 46).clamp(0.0, 46.0);
    final rateScore = currentRate == null ? 0.0 : 20.0;
    final quality =
        (spanScore + periodicScore + rateScore).clamp(0.0, 100.0).toDouble();
    if (currentRate == null) return math.min(quality, 22.0);
    if (_periodicity < 0.35) return math.min(quality, 28.0);
    if (_periodicity < 0.50) return math.min(quality, 55.0);
    return quality;
  }
}

class ImuBreathingRateDetector {
  ImuBreathingRateDetector(this.fs)
      : _accelerationSignal = _DominantAccelerationBreathingSignal(fs),
        _axes = {
          '3D-Projektion': _ImuBreathingAxis(
            fs,
            minQualitySpan: 0.04,
            fullQualitySpan: 1.20,
            minAutocorrelationSpan: 0.012,
            smoothingSeconds: 0.26,
            scoreWeight: 1.0,
          ),
          'Betrag': _ImuBreathingAxis(
            fs,
            minQualitySpan: 0.018,
            fullQualitySpan: 0.70,
            minAutocorrelationSpan: 0.008,
            smoothingSeconds: 0.30,
            scoreWeight: 0.90,
          ),
          'X': _ImuBreathingAxis(
            fs,
            minQualitySpan: 0.025,
            fullQualitySpan: 0.85,
            minAutocorrelationSpan: 0.010,
            smoothingSeconds: 0.28,
            scoreWeight: 0.82,
          ),
          'Y': _ImuBreathingAxis(
            fs,
            minQualitySpan: 0.025,
            fullQualitySpan: 0.85,
            minAutocorrelationSpan: 0.010,
            smoothingSeconds: 0.28,
            scoreWeight: 0.82,
          ),
          'Z': _ImuBreathingAxis(
            fs,
            minQualitySpan: 0.025,
            fullQualitySpan: 0.85,
            minAutocorrelationSpan: 0.010,
            smoothingSeconds: 0.28,
            scoreWeight: 0.82,
          ),
        };

  static const _publicAxisLabel = '3D-Kombi';

  final int fs;
  final _DominantAccelerationBreathingSignal _accelerationSignal;
  final Map<String, _ImuBreathingAxis> _axes;
  BreathingResult? _lastResult;
  String? _activeAxisKey;
  String? _pendingAxisKey;
  String? _lastAxisKey;
  double? _lastDisplayedResp;
  double _displayOffset = 0;
  int _samplesSeen = 0;
  int _pendingAxisSamples = 0;

  double get detectionDelaySeconds {
    return _bestAxis.detector.detectionDelaySeconds;
  }

  String? get selectedAxisLabel => _publicAxisLabel;

  double get qualityPercent => _bestAxis.qualityPercent;

  ({String key, _ImuBreathingAxis axis}) get _bestAxisEntry {
    MapEntry<String, _ImuBreathingAxis>? best;
    for (final entry in _axes.entries) {
      if (best == null ||
          _axisSelectionScore(entry.value) > _axisSelectionScore(best.value)) {
        best = entry;
      }
    }
    final entry = best ?? _axes.entries.first;
    return (key: entry.key, axis: entry.value);
  }

  ({String key, _ImuBreathingAxis axis}) get _activeAxisEntry {
    final key = _activeAxisKey;
    final axis = key == null ? null : _axes[key];
    if (key != null && axis != null) return (key: key, axis: axis);
    return _bestAxisEntry;
  }

  _ImuBreathingAxis get _bestAxis => _activeAxisEntry.axis;

  BreathingResult? update({
    required double? sampleTimeS,
    required double? angleDeg,
    required double? rollDeg,
    required double? pitchDeg,
    required double? ax,
    required double? ay,
    required double? az,
    required double? gx,
    required double? gy,
    required double? gz,
    required double? qw,
    required double? qx,
    required double? qy,
    required double? qz,
  }) {
    final signals = _accelerationSignal.update(
      ax,
      ay,
      az,
      gx: gx,
      gy: gy,
      gz: gz,
    );
    if (signals == null) {
      return _staleResultWithoutPeak();
    }

    _axes['3D-Projektion']
        ?.update(signals.projection, sampleTimeS: sampleTimeS);
    _axes['Betrag']?.update(signals.magnitude, sampleTimeS: sampleTimeS);
    _axes['X']?.update(signals.x, sampleTimeS: sampleTimeS);
    _axes['Y']?.update(signals.y, sampleTimeS: sampleTimeS);
    _axes['Z']?.update(signals.z, sampleTimeS: sampleTimeS);

    final active = _selectActiveAxisEntry();
    final activeAxis = active.axis;
    final result = activeAxis.lastResult ?? _lastResult;
    if (result == null) return null;

    final output = _continuousOutputResult(
      result,
      active.key,
      qualityPercent: activeAxis.qualityPercent,
    );
    _lastResult = output;
    return output;
  }

  ({String key, _ImuBreathingAxis axis}) _selectActiveAxisEntry() {
    _samplesSeen++;
    final best = _bestAxisEntry;
    final activeKey = _activeAxisKey;
    if (activeKey == null || !_axes.containsKey(activeKey)) {
      _activeAxisKey = best.key;
      _pendingAxisKey = null;
      _pendingAxisSamples = 0;
      return best;
    }

    final activeAxis = _axes[activeKey]!;
    if (best.key == activeKey) {
      _pendingAxisKey = null;
      _pendingAxisSamples = 0;
      return (key: activeKey, axis: activeAxis);
    }

    final activeScore = _axisSelectionScore(activeAxis);
    final bestScore = _axisSelectionScore(best.axis);
    final startupSamples = (8 * fs).round();
    final inStartup = _samplesSeen < startupSamples;
    final activeLost = activeAxis.lastResult == null ||
        (activeScore < 0.08 && activeAxis.qualityPercent < 18);
    final clearlyBetter = bestScore > activeScore + 0.34 &&
        best.axis.qualityPercent > activeAxis.qualityPercent + 22;
    final startupBetter = inStartup && bestScore > activeScore + 0.12;
    final shouldConsiderSwitch = startupBetter ||
        (!inStartup && (activeLost || clearlyBetter) && bestScore > 0.18);

    if (!shouldConsiderSwitch) {
      _pendingAxisKey = null;
      _pendingAxisSamples = 0;
      return (key: activeKey, axis: activeAxis);
    }

    if (_pendingAxisKey == best.key) {
      _pendingAxisSamples++;
    } else {
      _pendingAxisKey = best.key;
      _pendingAxisSamples = 1;
    }

    final requiredSamples =
        inStartup ? math.max(1, fs) : math.max(1, (6 * fs).round());
    if (_pendingAxisSamples >= requiredSamples) {
      _activeAxisKey = best.key;
      _pendingAxisKey = null;
      _pendingAxisSamples = 0;
      return best;
    }

    return (key: activeKey, axis: activeAxis);
  }

  double _axisSelectionScore(_ImuBreathingAxis axis) {
    if (axis.lastResult == null) return 0;
    var score = axis.score + axis.qualityPercent / 100 * 0.16;
    if (axis.detector.currentRate != null) score += 0.06;
    return score;
  }

  BreathingResult _continuousOutputResult(
    BreathingResult result,
    String axisKey, {
    required double qualityPercent,
  }) {
    final lastAxisKey = _lastAxisKey;
    final lastDisplayedResp = _lastDisplayedResp;
    if (lastAxisKey != null &&
        lastAxisKey != axisKey &&
        lastDisplayedResp != null) {
      _displayOffset = lastDisplayedResp - result.filteredResp;
    }

    final currentOffset = _displayOffset;
    final filteredResp = result.filteredResp + currentOffset;
    final breathValue = result.breathValue + currentOffset;
    final breathPeakValue = result.breathPeakValue == null
        ? null
        : result.breathPeakValue! + currentOffset;
    final enriched = BreathingResult(
      breathingRate: result.breathingRate,
      isBreath: result.isBreath,
      filteredResp: filteredResp,
      breathValue: breathValue,
      breathPeakTime: result.breathPeakTime,
      breathPeakValue: breathPeakValue,
      axisLabel: _publicAxisLabel,
      qualityPercent: qualityPercent,
    );
    _lastAxisKey = axisKey;
    _lastDisplayedResp = filteredResp;
    _displayOffset *= 0.992;
    return enriched;
  }

  BreathingResult? _staleResultWithoutPeak() {
    final result = _lastResult;
    if (result == null) return null;
    return BreathingResult(
      breathingRate: result.breathingRate,
      isBreath: false,
      filteredResp: result.filteredResp,
      breathValue: result.breathValue,
      breathPeakTime: null,
      breathPeakValue: null,
      axisLabel: result.axisLabel,
      qualityPercent: result.qualityPercent,
    );
  }
}

class _AccelerationBreathingSignals {
  const _AccelerationBreathingSignals({
    required this.projection,
    required this.magnitude,
    required this.x,
    required this.y,
    required this.z,
  });

  final double projection;
  final double magnitude;
  final double x;
  final double y;
  final double z;
}

class _DominantAccelerationBreathingSignal {
  _DominantAccelerationBreathingSignal(this.fs)
      : _xFilter = _SlidingMedianFilter(3),
        _yFilter = _SlidingMedianFilter(3),
        _zFilter = _SlidingMedianFilter(3),
        _maxSamples = 10 * fs,
        _minSamples = math.max(8, fs),
        _recomputeSamples = math.max(1, (0.5 * fs).round());

  final int fs;
  final _SlidingMedianFilter _xFilter;
  final _SlidingMedianFilter _yFilter;
  final _SlidingMedianFilter _zFilter;
  final int _maxSamples;
  final int _minSamples;
  final int _recomputeSamples;
  final Queue<List<double>> _history = Queue<List<double>>();
  final Queue<double> _projectionHistory = Queue<double>();
  List<double>? _basis;
  List<double>? _mean;
  List<double>? _previousVector;
  int _samplesSinceUpdate = 0;
  int _artifactSamples = 0;
  int _quietAfterArtifactSamples = 0;
  bool _postMotionRecenterPending = false;

  _AccelerationBreathingSignals? update(
    double? ax,
    double? ay,
    double? az, {
    double? gx,
    double? gy,
    double? gz,
  }) {
    if (ax == null ||
        ay == null ||
        az == null ||
        !ax.isFinite ||
        !ay.isFinite ||
        !az.isFinite) {
      return null;
    }

    final rawVector = <double>[ax, ay, az];
    final vector = <double>[
      _xFilter.update(ax),
      _yFilter.update(ay),
      _zFilter.update(az),
    ];

    final residualMagnitude = _vectorDistance(rawVector, vector);
    final gyroMagnitude = _gyroMagnitude(gx, gy, gz);
    final previousVector = _previousVector;
    final vectorStep = previousVector == null
        ? 0.0
        : _vectorDistance(previousVector, vector) * 100.0;
    _previousVector = vector;
    final motionScore = _motionScore(
      residualMagnitude,
      gyroMagnitude,
      vectorStep,
    );
    _updatePostMotionRecenterState(
      vector,
      motionScore,
      gyroMagnitude,
      vectorStep,
    );

    if (_history.length < _minSamples || motionScore < 0.68) {
      _history.addLast(vector);
      while (_history.length > _maxSamples) {
        _history.removeFirst();
      }
    }

    _samplesSinceUpdate++;
    if (_history.length >= _minSamples &&
        (_basis == null || _samplesSinceUpdate >= _recomputeSamples)) {
      _computeBasis();
      _samplesSinceUpdate = 0;
    }

    final basis = _basis;
    final mean = _mean;
    if (basis == null || mean == null) {
      return const _AccelerationBreathingSignals(
        projection: 0,
        magnitude: 0,
        x: 0,
        y: 0,
        z: 0,
      );
    }

    var projection = 0.0;
    final centered = List<double>.filled(3, 0);
    for (var i = 0; i < 3; i++) {
      centered[i] = vector[i] - mean[i];
      projection += centered[i] * basis[i];
    }
    final robustProjection = _robustProjection(projection * 100);
    _recordProjection(robustProjection);
    final magnitude = (_vectorMagnitude(vector) - _vectorMagnitude(mean)) * 100;
    return _AccelerationBreathingSignals(
      projection: robustProjection,
      magnitude: magnitude,
      x: centered[0] * 100,
      y: centered[1] * 100,
      z: centered[2] * 100,
    );
  }

  double _motionScore(
    double residualMagnitude,
    double gyroMagnitudeDegS,
    double vectorStep,
  ) {
    final residualScore =
        ((residualMagnitude - 0.026) / 0.070).clamp(0.0, 1.0).toDouble();
    final gyroScore =
        ((gyroMagnitudeDegS - 14.0) / 48.0).clamp(0.0, 1.0).toDouble();
    final stepScore = ((vectorStep - 0.34) / 1.30).clamp(0.0, 1.0).toDouble();
    return math.max(residualScore, math.max(gyroScore, stepScore));
  }

  double _robustProjection(double projection) {
    final history = _projectionHistory.toList(growable: false);
    if (history.length < math.max(8, fs * 3)) return projection;

    final middle = median(history);
    final deviations =
        history.map((value) => (value - middle).abs()).toList(growable: false);
    final robustSigma = math.max(1.4826 * median(deviations), 0.015);
    final span = percentile(history, 90) - percentile(history, 10);
    final clampWidth = math.max(0.18, math.max(1.25 * span, 6.0 * robustSigma));
    var value = projection.clamp(
      middle - clampWidth,
      middle + clampWidth,
    );

    final previous =
        _projectionHistory.isEmpty ? null : _projectionHistory.last;
    if (previous != null) {
      final maxStep = math.max(0.045, math.min(0.42, span * 0.24));
      value = previous + (value - previous).clamp(-maxStep, maxStep);
    }
    return value.toDouble();
  }

  void _recordProjection(double projection) {
    _projectionHistory.addLast(projection);
    while (_projectionHistory.length > 20 * fs) {
      _projectionHistory.removeFirst();
    }
  }

  double _gyroMagnitude(double? gx, double? gy, double? gz) {
    final x = gx != null && gx.isFinite ? gx : 0.0;
    final y = gy != null && gy.isFinite ? gy : 0.0;
    final z = gz != null && gz.isFinite ? gz : 0.0;
    return math.sqrt(x * x + y * y + z * z);
  }

  void _updatePostMotionRecenterState(
    List<double> vector,
    double motionScore,
    double gyroMagnitudeDegS,
    double vectorStep,
  ) {
    final artifactThresholdSamples = math.max(4, (0.35 * fs).round());
    final quietThresholdSamples = math.max(4, (0.40 * fs).round());

    if (motionScore >= 0.72) {
      _artifactSamples++;
      _quietAfterArtifactSamples = 0;
      if (_artifactSamples >= artifactThresholdSamples) {
        _postMotionRecenterPending = true;
      }
      return;
    }

    if (_postMotionRecenterPending) {
      final mechanicallyQuiet = gyroMagnitudeDegS < 5.0 || vectorStep < 0.42;
      if (mechanicallyQuiet) {
        _quietAfterArtifactSamples++;
        if (_quietAfterArtifactSamples >= quietThresholdSamples) {
          _recenterAfterMotion(vector);
        }
      } else {
        _quietAfterArtifactSamples = 0;
      }
      return;
    }

    if (_artifactSamples > 0 && motionScore < 0.45) {
      _artifactSamples--;
    }
  }

  void _recenterAfterMotion(List<double> vector) {
    _history.clear();
    for (var i = 0; i < _minSamples; i++) {
      _history.addLast(List<double>.from(vector));
    }
    _mean = List<double>.from(vector);
    _projectionHistory.clear();
    _samplesSinceUpdate = _recomputeSamples;
    _artifactSamples = 0;
    _quietAfterArtifactSamples = 0;
    _postMotionRecenterPending = false;
  }

  double _vectorDistance(List<double> a, List<double> b) {
    final dx = a[0] - b[0];
    final dy = a[1] - b[1];
    final dz = a[2] - b[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double _vectorMagnitude(List<double> value) {
    return math.sqrt(
      value[0] * value[0] + value[1] * value[1] + value[2] * value[2],
    );
  }

  void _computeBasis() {
    final count = _history.length;
    if (count < _minSamples) return;

    var mean = List<double>.filled(3, 0);
    for (final vector in _history) {
      for (var i = 0; i < 3; i++) {
        mean[i] += vector[i];
      }
    }
    for (var i = 0; i < 3; i++) {
      mean[i] /= count;
    }
    final previousMean = _mean;
    if (previousMean != null) {
      mean = List<double>.generate(
        3,
        (index) => previousMean[index] * 0.96 + mean[index] * 0.04,
        growable: false,
      );
    }

    final covariance = List.generate(3, (_) => List<double>.filled(3, 0));
    for (final vector in _history) {
      for (var i = 0; i < 3; i++) {
        final a = vector[i] - mean[i];
        for (var j = 0; j < 3; j++) {
          covariance[i][j] += a * (vector[j] - mean[j]);
        }
      }
    }
    final totalVariance =
        (covariance[0][0] + covariance[1][1] + covariance[2][2]) / count;
    if (_basis != null && (!totalVariance.isFinite || totalVariance < 1.0e-7)) {
      return;
    }

    var basis = _basis ?? _largestVarianceAxis(covariance);
    for (var iteration = 0; iteration < 8; iteration++) {
      final next = List<double>.filled(3, 0);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          next[i] += covariance[i][j] * basis[j];
        }
      }
      final norm = math.sqrt(next.map((value) => value * value).reduce(
            (a, b) => a + b,
          ));
      if (!norm.isFinite || norm <= 1e-12) return;
      basis = next.map((value) => value / norm).toList(growable: false);
    }

    final previous = _basis;
    if (previous != null && _dot3(previous, basis) < 0) {
      basis = basis.map((value) => -value).toList(growable: false);
    }
    if (previous != null) {
      basis = _smoothedBasis(previous, basis);
    }
    _basis = basis;
    _mean = mean;
  }

  List<double> _smoothedBasis(List<double> previous, List<double> next) {
    const blend = 0.10;
    final mixed = List<double>.generate(
      3,
      (index) => previous[index] * (1.0 - blend) + next[index] * blend,
      growable: false,
    );
    final norm = math.sqrt(mixed.map((value) => value * value).reduce(
          (a, b) => a + b,
        ));
    if (!norm.isFinite || norm <= 1e-12) return previous;
    return mixed.map((value) => value / norm).toList(growable: false);
  }

  List<double> _largestVarianceAxis(List<List<double>> covariance) {
    var index = 0;
    var best = covariance[0][0];
    for (var i = 1; i < 3; i++) {
      if (covariance[i][i] > best) {
        best = covariance[i][i];
        index = i;
      }
    }
    final axis = List<double>.filled(3, 0);
    axis[index] = 1;
    return axis;
  }

  double _dot3(List<double> a, List<double> b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  }
}

class _ImuBreathingAxis {
  _ImuBreathingAxis(
    int fs, {
    required this.minQualitySpan,
    required this.fullQualitySpan,
    this.minAutocorrelationSpan = 0.006,
    this.smoothingSeconds = 0.32,
    this.scoreWeight = 1.0,
  }) : detector = BreathingRateDetector(
          fs,
          baselineSeconds: 10,
          smoothingSeconds: smoothingSeconds,
          lookaheadSeconds: 0.9,
          peakNeighborSeconds: 0.65,
          warmupSeconds: 3.5,
          minBreathIntervalSeconds: 1.55,
          maxBreathIntervalSeconds: 12,
          thresholdFactor: 0.18,
          minAutocorrelationSpan: minAutocorrelationSpan,
        );

  final BreathingRateDetector detector;
  final double minQualitySpan;
  final double fullQualitySpan;
  final double minAutocorrelationSpan;
  final double smoothingSeconds;
  final double scoreWeight;
  BreathingResult? lastResult;
  double score = 0;

  double get qualityPercent {
    final span = detector.signalSpan;
    final periodicity = detector.periodicity;
    final spanFraction = _spanFraction(span);
    final spanScore = spanFraction * 30.0;
    final periodicScore =
        ((periodicity - 0.32) / 0.55 * 50).clamp(0.0, 50.0).toDouble();
    final rateScore = detector.currentRate == null ? 0.0 : 20.0;
    final quality =
        (spanScore + periodicScore + rateScore).clamp(0.0, 100.0).toDouble();
    if (spanFraction < 0.10) return math.min(quality, 42.0);
    if (spanFraction < 0.16 && periodicity < 0.65) {
      return math.min(quality, 50.0);
    }
    if (detector.currentRate == null) return math.min(quality, 25.0);
    if (periodicity < 0.35) return math.min(quality, 35.0);
    if (periodicity < 0.50) return math.min(quality, 60.0);
    return quality;
  }

  void update(double value, {double? sampleTimeS}) {
    lastResult = detector.update(value, timeS: sampleTimeS);
    final span = detector.signalSpan;
    final spanFraction = _spanFraction(span);
    final periodicity = detector.periodicity.clamp(0.0, 1.0).toDouble();
    final rateBonus = detector.currentRate == null ? 0.0 : 0.12;
    var nextScore =
        scoreWeight * (spanFraction * 0.26 + periodicity * 0.62 + rateBonus);
    if (spanFraction < 0.08) nextScore *= 0.35;
    if (periodicity < 0.30) nextScore *= 0.55;
    score = nextScore;
  }

  double _spanFraction(double span) {
    if (!span.isFinite || span <= minQualitySpan) return 0;
    final range = math.max(1e-9, fullQualitySpan - minQualitySpan);
    return ((span - minQualitySpan) / range).clamp(0.0, 1.0).toDouble();
  }
}

class ImuSnoreVibrationEvidence {
  const ImuSnoreVibrationEvidence({
    required this.vibrationScore,
    required this.quietScore,
    required this.artifactScore,
    required this.sampleCount,
  });

  final double vibrationScore;
  final double quietScore;
  final double artifactScore;
  final int sampleCount;

  bool get hasData => sampleCount >= 4;
}

class ImuSnoreVibrationDetector {
  ImuSnoreVibrationDetector(this.fs);

  final int fs;
  final Queue<_ImuSnoreVibrationSample> _samples =
      Queue<_ImuSnoreVibrationSample>();
  final Map<String, _ImuSnoreRawSample> _previousByRole = {};

  void reset() {
    _samples.clear();
    _previousByRole.clear();
  }

  void update({
    required String roleKey,
    required double timeS,
    required double? ax,
    required double? ay,
    required double? az,
    required double? gx,
    required double? gy,
    required double? gz,
  }) {
    if (!timeS.isFinite) return;
    final acc = _finiteVector3(ax, ay, az);
    final gyro = _finiteVector3(gx, gy, gz);
    if (acc == null || gyro == null) return;

    final previous = _previousByRole[roleKey];
    _previousByRole[roleKey] = _ImuSnoreRawSample(timeS, acc, gyro);
    if (previous == null) return;

    final dt = math.max(1 / fs, timeS - previous.timeS);
    if (!dt.isFinite || dt <= 0 || dt > 0.8) return;

    final accStepPerSecond = _vectorDistance3(acc, previous.acc) / dt;
    final gyroStepPerSecond = _vectorDistance3(gyro, previous.gyro) / dt;
    final gyroMagnitude = _vectorMagnitude3(gyro);
    final energy = math.sqrt(
      math.pow(accStepPerSecond * 1.45, 2) +
          math.pow(gyroStepPerSecond / 450.0, 2),
    );
    final artifactScore = math.max(
      ((gyroMagnitude - 22.0) / 48.0).clamp(0.0, 1.0).toDouble(),
      ((accStepPerSecond - 0.28) / 0.85).clamp(0.0, 1.0).toDouble(),
    );

    _samples.addLast(
      _ImuSnoreVibrationSample(
        timeS: timeS,
        roleKey: roleKey,
        energy: energy,
        artifactScore: artifactScore,
      ),
    );
    final minTime = timeS - 90;
    while (_samples.isNotEmpty && _samples.first.timeS < minTime) {
      _samples.removeFirst();
    }
  }

  ImuSnoreVibrationEvidence evidenceAt(double timeS) {
    if (!timeS.isFinite) {
      return const ImuSnoreVibrationEvidence(
        vibrationScore: 0,
        quietScore: 0,
        artifactScore: 0,
        sampleCount: 0,
      );
    }

    final eventSamples = _samples
        .where((sample) => (sample.timeS - timeS).abs() <= 0.85)
        .toList(growable: false);
    if (eventSamples.length < 4) {
      return ImuSnoreVibrationEvidence(
        vibrationScore: 0,
        quietScore: 0,
        artifactScore: 0,
        sampleCount: eventSamples.length,
      );
    }

    final roles = eventSamples.map((sample) => sample.roleKey).toSet();
    var bestVibrationScore = 0.0;
    var quietScoreSum = 0.0;
    var quietRoleCount = 0;
    var artifactScore = 0.0;
    for (final role in roles) {
      final roleEvent =
          eventSamples.where((sample) => sample.roleKey == role).toList();
      if (roleEvent.length < 4) continue;
      final roleContext = _samples
          .where((sample) =>
              sample.roleKey == role &&
              sample.timeS >= timeS - 45 &&
              sample.timeS <= timeS + 2.0 &&
              (sample.timeS - timeS).abs() > 1.35)
          .map((sample) => sample.energy)
          .toList(growable: false);
      final evidence = _roleEvidence(roleEvent, roleContext);
      bestVibrationScore =
          math.max(bestVibrationScore, evidence.vibrationScore);
      quietScoreSum += evidence.quietScore;
      quietRoleCount++;
      artifactScore = math.max(
        artifactScore,
        roleEvent
            .map((sample) => sample.artifactScore)
            .fold<double>(0, math.max),
      );
    }

    if (artifactScore > 0.72) {
      bestVibrationScore *= 0.25;
    }
    final quietScore =
        quietRoleCount == 0 ? 0.0 : quietScoreSum / quietRoleCount;
    return ImuSnoreVibrationEvidence(
      vibrationScore: bestVibrationScore.clamp(0.0, 1.0).toDouble(),
      quietScore: quietScore.clamp(0.0, 1.0).toDouble(),
      artifactScore: artifactScore.clamp(0.0, 1.0).toDouble(),
      sampleCount: eventSamples.length,
    );
  }

  ImuSnoreVibrationEvidence _roleEvidence(
    List<_ImuSnoreVibrationSample> eventSamples,
    List<double> context,
  ) {
    final eventValues =
        eventSamples.map((sample) => sample.energy).toList(growable: false);
    final eventPeak = percentile(eventValues, 82);
    final eventMedian = median(eventValues);
    final baseline = context.length >= fs * 4 ? percentile(context, 55) : 0.05;
    final contextSpread = context.length >= fs * 4
        ? math.max(0.015, percentile(context, 86) - baseline)
        : 0.035;
    final localBurst = eventPeak - math.min(eventMedian, baseline);
    final excess = eventPeak - baseline - math.max(0.040, contextSpread * 1.25);
    final burstScore = ((localBurst - 0.045) / 0.18).clamp(0.0, 1.0).toDouble();
    final excessScore = (excess / math.max(0.085, contextSpread * 2.2))
        .clamp(0.0, 1.0)
        .toDouble();
    final vibrationScore = math.max(burstScore * 0.55, excessScore);
    final quietLimit = baseline + math.max(0.055, contextSpread * 1.45);
    final quietScore =
        ((quietLimit - eventPeak) / math.max(0.070, contextSpread * 1.4))
            .clamp(0.0, 1.0)
            .toDouble();
    return ImuSnoreVibrationEvidence(
      vibrationScore: vibrationScore,
      quietScore: quietScore,
      artifactScore: 0,
      sampleCount: eventSamples.length,
    );
  }

  List<double>? _finiteVector3(double? x, double? y, double? z) {
    if (x == null || y == null || z == null) return null;
    if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
    return [x, y, z];
  }

  double _vectorDistance3(List<double> a, List<double> b) {
    final dx = a[0] - b[0];
    final dy = a[1] - b[1];
    final dz = a[2] - b[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double _vectorMagnitude3(List<double> value) {
    return math.sqrt(
      value[0] * value[0] + value[1] * value[1] + value[2] * value[2],
    );
  }
}

class _ImuSnoreRawSample {
  const _ImuSnoreRawSample(this.timeS, this.acc, this.gyro);

  final double timeS;
  final List<double> acc;
  final List<double> gyro;
}

class _ImuSnoreVibrationSample {
  const _ImuSnoreVibrationSample({
    required this.timeS,
    required this.roleKey,
    required this.energy,
    required this.artifactScore,
  });

  final double timeS;
  final String roleKey;
  final double energy;
  final double artifactScore;
}

class OrientationEstimator {
  OrientationState update(List<num> accRawValues) {
    if (accRawValues.length < 2) return const OrientationState.empty();
    final forehead = -_accToAngle(accRawValues[0], 510, 100);
    final chest = -_accToAngle(accRawValues[1], 510, 100);
    return OrientationState(
      foreheadAngleDeg: forehead,
      chestAngleDeg: chest,
      relativeAngleDeg: forehead - chest,
    );
  }

  double _accToAngle(num value, double zero, double halfRange) {
    final normalized = ((value.toDouble() - zero) / halfRange).clamp(-1.0, 1.0);
    return math.acos(normalized) * 180 / math.pi;
  }
}

class CsvWindowAggregator {
  CsvWindowAggregator(this.intervalSeconds, {this.startedAt})
      : _windowEndS = intervalSeconds;

  final double intervalSeconds;
  final DateTime? startedAt;
  double _windowEndS;
  int _sampleCount = 0;
  final List<double> _heartRates = [];
  final List<double> _breathingRates = [];
  final List<double> _oxygenSaturations = [];
  final List<double> _snoreVolumes = [];
  final List<double> _snoreSourceConfidences = [];
  final Set<String> _snoreWindowKeys = {};
  final List<double> _foreheadAngles = [];
  final List<double> _chestAngles = [];
  final List<double> _relativeAngles = [];
  final List<double> _relativeYaws = [];
  final List<double> _relativeYawQualities = [];
  final List<double> _mg24ForeheadBatteries = [];
  final List<double> _mg24BellyBatteries = [];
  final List<double> _mg24ForeheadBatteryVoltages = [];
  final List<double> _mg24BellyBatteryVoltages = [];
  final List<double> _mg24ForeheadEarTemperatures = [];
  final List<double> _mg24ForeheadAngles = [];
  final List<double> _mg24BellyAngles = [];
  final List<double> _mg24ForeheadRolls = [];
  final List<double> _mg24ForeheadPitches = [];
  final List<double> _mg24ForeheadYaws = [];
  final List<double> _mg24BellyRolls = [];
  final List<double> _mg24BellyPitches = [];
  final List<double> _mg24BellyYaws = [];
  final List<double> _mg24PpgQualities = [];
  final List<double> _mg24BreathingQualities = [];
  final List<double> _radarTargets = [];
  final List<double> _radarDistances = [];
  final List<double> _radarHeartRates = [];
  final List<double> _radarBreathingRates = [];
  final List<double> _radarIlluminance = [];
  bool _snoreSeen = false;
  bool _wearerSnoreSeen = false;
  bool _externalSnoreSeen = false;
  bool _unknownSnoreSeen = false;
  bool _mg24ConnectedSeen = false;
  bool _mg24ForeheadConnectedSeen = false;
  bool _mg24BellyConnectedSeen = false;
  bool _radarConnectedSeen = false;
  bool _radarPersonSeen = false;
  double _snoreSeconds = 0;

  List<List<String>> update(
    double timeS,
    double? heartRate,
    double? breathingRate,
    double? oxygenSaturation,
    SnoreState snoreState,
    OrientationState orientationState,
    RadarState radarState,
    Mg24State mg24State,
  ) {
    final rows = <List<String>>[];
    while (timeS >= _windowEndS) {
      final row = _currentRow();
      if (row != null) rows.add(row);
      _windowEndS += intervalSeconds;
      _resetWindow();
    }
    _addSample(
      heartRate,
      breathingRate,
      oxygenSaturation,
      snoreState,
      orientationState,
      radarState,
      mg24State,
    );
    return rows;
  }

  void _resetWindow() {
    _sampleCount = 0;
    _heartRates.clear();
    _breathingRates.clear();
    _oxygenSaturations.clear();
    _snoreVolumes.clear();
    _snoreSourceConfidences.clear();
    _foreheadAngles.clear();
    _chestAngles.clear();
    _relativeAngles.clear();
    _relativeYaws.clear();
    _relativeYawQualities.clear();
    _mg24ForeheadBatteries.clear();
    _mg24BellyBatteries.clear();
    _mg24ForeheadBatteryVoltages.clear();
    _mg24BellyBatteryVoltages.clear();
    _mg24ForeheadEarTemperatures.clear();
    _mg24ForeheadAngles.clear();
    _mg24BellyAngles.clear();
    _mg24ForeheadRolls.clear();
    _mg24ForeheadPitches.clear();
    _mg24ForeheadYaws.clear();
    _mg24BellyRolls.clear();
    _mg24BellyPitches.clear();
    _mg24BellyYaws.clear();
    _mg24PpgQualities.clear();
    _mg24BreathingQualities.clear();
    _radarTargets.clear();
    _radarDistances.clear();
    _radarHeartRates.clear();
    _radarBreathingRates.clear();
    _radarIlluminance.clear();
    _snoreSeen = false;
    _wearerSnoreSeen = false;
    _externalSnoreSeen = false;
    _unknownSnoreSeen = false;
    _mg24ConnectedSeen = false;
    _mg24ForeheadConnectedSeen = false;
    _mg24BellyConnectedSeen = false;
    _radarConnectedSeen = false;
    _radarPersonSeen = false;
    _snoreSeconds = 0;
  }

  void _addSample(
    double? heartRate,
    double? breathingRate,
    double? oxygenSaturation,
    SnoreState snoreState,
    OrientationState orientationState,
    RadarState radarState,
    Mg24State mg24State,
  ) {
    _sampleCount++;
    _appendIfValid(_heartRates, heartRate);
    _appendIfValid(_breathingRates, breathingRate);
    _appendIfValid(_oxygenSaturations, oxygenSaturation);
    final snoreSeconds = _snoreWindowSeconds(snoreState);
    if (snoreSeconds != null && snoreSeconds > 0) {
      _snoreSeen = true;
      _snoreSeconds = math.min(intervalSeconds, _snoreSeconds + snoreSeconds);
      _appendIfValid(_snoreVolumes, snoreVolumePercent(snoreState));
    }
    if (_snoreSeen && snoreState.sourceConfidence > 0) {
      _appendIfValid(
        _snoreSourceConfidences,
        snoreState.sourceConfidence * 100,
      );
    }
    _appendIfValid(_foreheadAngles, orientationState.foreheadAngleDeg);
    _appendIfValid(_chestAngles, orientationState.chestAngleDeg);
    _appendIfValid(_relativeAngles, orientationState.relativeAngleDeg);
    _appendIfValid(_relativeYaws, orientationState.relativeYawDeg);
    _appendIfValid(
      _relativeYawQualities,
      orientationState.relativeYawQualityPercent,
    );
    _appendIfValid(
      _mg24ForeheadBatteries,
      mg24State.forehead.batteryPercent,
    );
    _appendIfValid(_mg24BellyBatteries, mg24State.belly.batteryPercent);
    _appendIfValid(
      _mg24ForeheadBatteryVoltages,
      mg24State.forehead.batteryVoltage,
    );
    _appendIfValid(_mg24BellyBatteryVoltages, mg24State.belly.batteryVoltage);
    _appendIfValid(
      _mg24ForeheadEarTemperatures,
      mg24State.forehead.earTemperatureC,
    );
    _appendIfValid(_mg24ForeheadAngles, mg24State.forehead.angleDeg);
    _appendIfValid(_mg24BellyAngles, mg24State.belly.angleDeg);
    _appendIfValid(_mg24ForeheadRolls, mg24State.forehead.rollDeg);
    _appendIfValid(_mg24ForeheadPitches, mg24State.forehead.pitchDeg);
    _appendIfValid(_mg24ForeheadYaws, mg24State.forehead.yawDeg);
    _appendIfValid(_mg24BellyRolls, mg24State.belly.rollDeg);
    _appendIfValid(_mg24BellyPitches, mg24State.belly.pitchDeg);
    _appendIfValid(_mg24BellyYaws, mg24State.belly.yawDeg);
    _appendIfValid(_mg24PpgQualities, mg24State.forehead.ppgQuality);
    _appendIfValid(_mg24BreathingQualities, mg24State.breathingQuality);
    _appendIfValid(_radarTargets, radarState.targetCount);
    _appendIfValid(_radarDistances, radarState.distanceCm);
    _appendIfValid(_radarHeartRates, radarState.heartRateBpm);
    _appendIfValid(_radarBreathingRates, radarState.breathingRatePerMin);
    _appendIfValid(_radarIlluminance, radarState.illuminanceLux);
    if (_snoreSeen) {
      if (snoreState.source == 'wearer') {
        _wearerSnoreSeen = true;
      } else if (snoreState.source == 'external') {
        _externalSnoreSeen = true;
      } else {
        _unknownSnoreSeen = true;
      }
    }
    if (mg24State.connected) _mg24ConnectedSeen = true;
    if (mg24State.forehead.connected) _mg24ForeheadConnectedSeen = true;
    if (mg24State.belly.connected) _mg24BellyConnectedSeen = true;
    if (radarState.connected) _radarConnectedSeen = true;
    if (radarState.personDetected == true) _radarPersonSeen = true;
  }

  List<String>? _currentRow() {
    if (_sampleCount == 0) return null;
    return [
      _formatWindowClockTime(),
      _formatMean(_heartRates),
      _formatMean(_breathingRates),
      _formatMean(_oxygenSaturations),
      _snoreSeen ? '1' : '0',
      _snoreSeconds <= 0 ? '' : _snoreSeconds.toStringAsFixed(2),
      _formatMax(_snoreVolumes),
      _snoreSourceForWindow(),
      _formatMean(_snoreSourceConfidences),
      _formatMean(_foreheadAngles),
      _formatMean(_chestAngles),
      _formatMean(_relativeAngles),
      _formatMean(_relativeYaws),
      _formatMean(_relativeYawQualities),
      _mg24ConnectedSeen ? '1' : '0',
      _mg24ForeheadConnectedSeen ? '1' : '0',
      _mg24BellyConnectedSeen ? '1' : '0',
      _formatMean(_mg24ForeheadBatteries),
      _formatMean(_mg24BellyBatteries),
      _formatMean(_mg24ForeheadBatteryVoltages, fractionDigits: 2),
      _formatMean(_mg24BellyBatteryVoltages, fractionDigits: 2),
      _formatMean(_mg24ForeheadEarTemperatures, fractionDigits: 2),
      _formatMean(_mg24ForeheadAngles),
      _formatMean(_mg24BellyAngles),
      _formatMean(_mg24ForeheadRolls),
      _formatMean(_mg24ForeheadPitches),
      _formatMean(_mg24ForeheadYaws),
      _formatMean(_mg24BellyRolls),
      _formatMean(_mg24BellyPitches),
      _formatMean(_mg24BellyYaws),
      _formatMean(_mg24PpgQualities),
      _formatMean(_mg24BreathingQualities),
      _radarConnectedSeen ? '1' : '0',
      _radarPersonSeen ? '1' : '0',
      _formatMean(_radarTargets),
      _formatMean(_radarDistances),
      _formatMean(_radarHeartRates),
      _formatMean(_radarBreathingRates),
      _formatMean(_radarIlluminance),
    ];
  }

  String _snoreSourceForWindow() {
    if (!_snoreSeen) return '';
    if (_wearerSnoreSeen && _externalSnoreSeen) return 'unknown';
    if (_wearerSnoreSeen) return 'wearer';
    if (_externalSnoreSeen) return 'external';
    if (_unknownSnoreSeen) return 'unknown';
    return 'unknown';
  }

  void _appendIfValid(List<double> values, double? value) {
    if (value != null && value.isFinite) values.add(value);
  }

  double? _snoreWindowSeconds(SnoreState state) {
    if (state.backend == 'none') return null;
    final center = state.windowCenterAt;
    final widthMs = state.snoreBurstActive
        ? null
        : state.snoreBreathWidthMs ?? state.snoreActiveWidthMs;
    if (center == null ||
        widthMs == null ||
        !widthMs.isFinite ||
        widthMs <= 0) {
      return null;
    }
    final key = '${center.microsecondsSinceEpoch}:${widthMs.round()}';
    if (!_snoreWindowKeys.add(key)) return null;
    return (widthMs / 1000.0).clamp(0.0, intervalSeconds).toDouble();
  }

  String _formatMean(List<double> values, {int fractionDigits = 1}) {
    if (values.isEmpty) return '';
    final mean = values.reduce((a, b) => a + b) / values.length;
    return mean.toStringAsFixed(fractionDigits);
  }

  String _formatMax(List<double> values, {int fractionDigits = 1}) {
    if (values.isEmpty) return '';
    return values.reduce(math.max).toStringAsFixed(fractionDigits);
  }

  String _formatWindowClockTime() {
    final start = startedAt;
    if (start == null) return _windowEndS.toStringAsFixed(1);
    final timestamp = start.add(
      Duration(milliseconds: (_windowEndS * 1000).round()),
    );
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:'
        '${two(timestamp.second)}';
  }
}

double? snoreVolumePercent(SnoreState state) {
  if (state.backend == 'none') return null;
  final scaled = ((state.rmsDb - snoreVolumeMinDbfs) /
          (snoreVolumeMaxDbfs - snoreVolumeMinDbfs))
      .clamp(0.0, 1.0);
  return scaled * 100;
}

void _pushLimited<T>(Queue<T> queue, T value, int maxLength) {
  queue.addLast(value);
  while (queue.length > maxLength) {
    queue.removeFirst();
  }
}
