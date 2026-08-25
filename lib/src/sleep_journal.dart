import 'dart:convert';
import 'dart:math' as math;

enum SleepQuestionPhase {
  evening,
  morning,
}

enum SleepQuestionType {
  scale,
  yesNo,
}

extension SleepQuestionPhaseLabel on SleepQuestionPhase {
  String get label {
    switch (this) {
      case SleepQuestionPhase.evening:
        return 'Abends';
      case SleepQuestionPhase.morning:
        return 'Morgens';
    }
  }

  String get key {
    switch (this) {
      case SleepQuestionPhase.evening:
        return 'evening';
      case SleepQuestionPhase.morning:
        return 'morning';
    }
  }

  static SleepQuestionPhase fromKey(String key) {
    return key == 'morning'
        ? SleepQuestionPhase.morning
        : SleepQuestionPhase.evening;
  }
}

extension SleepQuestionTypeLabel on SleepQuestionType {
  String get label {
    switch (this) {
      case SleepQuestionType.scale:
        return '1-5';
      case SleepQuestionType.yesNo:
        return 'Ja / Nein';
    }
  }

  String get key {
    switch (this) {
      case SleepQuestionType.scale:
        return 'scale';
      case SleepQuestionType.yesNo:
        return 'yes_no';
    }
  }

  static SleepQuestionType fromKey(String key) {
    return key == 'yes_no' ? SleepQuestionType.yesNo : SleepQuestionType.scale;
  }
}

class SleepQuestion {
  const SleepQuestion({
    required this.id,
    required this.title,
    required this.prompt,
    required this.phase,
    required this.type,
    required this.isCustom,
    this.lowLabel,
    this.highLabel,
  });

  factory SleepQuestion.fromJson(Map<String, dynamic> json) {
    return SleepQuestion(
      id: json['id'] as String,
      title: json['title'] as String,
      prompt: json['prompt'] as String,
      phase: SleepQuestionPhaseLabel.fromKey(json['phase'] as String? ?? ''),
      type: SleepQuestionTypeLabel.fromKey(json['type'] as String? ?? ''),
      isCustom: json['is_custom'] as bool? ?? true,
      lowLabel: json['low_label'] as String?,
      highLabel: json['high_label'] as String?,
    );
  }

  final String id;
  final String title;
  final String prompt;
  final SleepQuestionPhase phase;
  final SleepQuestionType type;
  final bool isCustom;
  final String? lowLabel;
  final String? highLabel;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'prompt': prompt,
      'phase': phase.key,
      'type': type.key,
      'is_custom': isCustom,
      'low_label': lowLabel,
      'high_label': highLabel,
    };
  }
}

class SleepMeasurementStats {
  int _snoreCount = 0;
  int _snoreObservationCount = 0;
  int _heartCount = 0;
  int _breathingCount = 0;
  int _earTemperatureCount = 0;
  int _relativeAngleCount = 0;
  int _angleSnorePairCount = 0;
  int _angleSnoreSampleCount = 0;
  int _poseSnorePairCount = 0;
  int _poseSnoreSampleCount = 0;
  double _heartSum = 0;
  double _breathingSum = 0;
  double _earTemperatureSum = 0;
  double _relativeAngleSum = 0;
  double _observedSeconds = 0;
  double _snoreObservedSeconds = 0;
  double _angleSnoreObservedSeconds = 0;
  double _angleSnoreSeconds = 0;
  double _angleSnoreSumX = 0;
  double _angleSnoreSumY = 0;
  double _angleSnoreSumXX = 0;
  double _angleSnoreSumYY = 0;
  double _angleSnoreSumXY = 0;
  double _poseSnoreObservedSeconds = 0;
  double _poseSnoreSeconds = 0;
  DateTime? _lastSampleAt;
  final List<_AngleSnoreBinAccumulator> _angleSnoreBins = List.generate(
    _relativeAngleSnoreBinCount,
    (_) => _AngleSnoreBinAccumulator(),
  );
  final List<_PoseSnoreClusterAccumulator> _poseSnoreClusters = [];
  final List<List<_AngleSnoreBinAccumulator>> _poseAngleSnoreFeatureBins =
      List.generate(
    _poseAngleFeatureCount,
    (_) => List.generate(
      _poseSnoreBinCount,
      (_) => _AngleSnoreBinAccumulator(),
    ),
  );

  void reset() {
    _snoreCount = 0;
    _snoreObservationCount = 0;
    _heartCount = 0;
    _breathingCount = 0;
    _earTemperatureCount = 0;
    _relativeAngleCount = 0;
    _angleSnorePairCount = 0;
    _angleSnoreSampleCount = 0;
    _poseSnorePairCount = 0;
    _poseSnoreSampleCount = 0;
    _heartSum = 0;
    _breathingSum = 0;
    _earTemperatureSum = 0;
    _relativeAngleSum = 0;
    _observedSeconds = 0;
    _snoreObservedSeconds = 0;
    _angleSnoreObservedSeconds = 0;
    _angleSnoreSeconds = 0;
    _angleSnoreSumX = 0;
    _angleSnoreSumY = 0;
    _angleSnoreSumXX = 0;
    _angleSnoreSumYY = 0;
    _angleSnoreSumXY = 0;
    _poseSnoreObservedSeconds = 0;
    _poseSnoreSeconds = 0;
    _lastSampleAt = null;
    for (final bin in _angleSnoreBins) {
      bin.reset();
    }
    _poseSnoreClusters.clear();
    for (final feature in _poseAngleSnoreFeatureBins) {
      for (final bin in feature) {
        bin.reset();
      }
    }
  }

  void add({
    required double? heartRate,
    required double? breathingRate,
    required double relativeAngleDeg,
    required bool isSnoring,
    double? earTemperatureC,
    DateTime? sampledAt,
    double? durationSeconds,
    double? foreheadRollDeg,
    double? foreheadPitchDeg,
    double? foreheadYawDeg,
    double? bellyRollDeg,
    double? bellyPitchDeg,
    double? bellyYawDeg,
    bool hasForeheadPose = false,
    bool hasBellyPose = false,
    bool hasSnoreData = true,
    double? snoreFraction,
  }) {
    final sampleSeconds = _sampleWeightSeconds(sampledAt, durationSeconds);
    final observedSnoreFraction = hasSnoreData
        ? (snoreFraction ?? (isSnoring ? 1.0 : 0.0)).clamp(0.0, 1.0).toDouble()
        : null;
    if (hasSnoreData) {
      _snoreObservationCount++;
      if (observedSnoreFraction! > 0) _snoreCount++;
    }
    if (hasSnoreData && sampleSeconds > 0) {
      _observedSeconds += sampleSeconds;
      _snoreObservedSeconds += sampleSeconds * observedSnoreFraction!;
    }
    if (heartRate != null && heartRate.isFinite) {
      _heartCount++;
      _heartSum += heartRate;
    }
    if (breathingRate != null && breathingRate.isFinite) {
      _breathingCount++;
      _breathingSum += breathingRate;
    }
    if (earTemperatureC != null &&
        earTemperatureC.isFinite &&
        earTemperatureC >= 30 &&
        earTemperatureC <= 42) {
      _earTemperatureCount++;
      _earTemperatureSum += earTemperatureC;
    }
    if (relativeAngleDeg.isFinite) {
      _relativeAngleCount++;
      _relativeAngleSum += relativeAngleDeg;
    }
    if (hasSnoreData && relativeAngleDeg.isFinite) {
      _addAngleSnorePair(
        relativeAngleDeg,
        observedSnoreFraction!,
        sampleSeconds,
      );
    }
    if (hasSnoreData &&
        hasForeheadPose &&
        hasBellyPose &&
        foreheadRollDeg != null &&
        foreheadPitchDeg != null &&
        foreheadYawDeg != null &&
        bellyRollDeg != null &&
        bellyPitchDeg != null &&
        bellyYawDeg != null &&
        foreheadRollDeg.isFinite &&
        foreheadPitchDeg.isFinite &&
        foreheadYawDeg.isFinite &&
        bellyRollDeg.isFinite &&
        bellyPitchDeg.isFinite &&
        bellyYawDeg.isFinite) {
      _addPoseSnorePair(
        foreheadRollDeg,
        foreheadPitchDeg,
        foreheadYawDeg,
        bellyRollDeg,
        bellyPitchDeg,
        bellyYawDeg,
        observedSnoreFraction!,
        sampleSeconds,
        heartRate,
        breathingRate,
      );
    }
  }

  double _sampleWeightSeconds(DateTime? sampledAt, double? durationSeconds) {
    if (durationSeconds != null &&
        durationSeconds.isFinite &&
        durationSeconds > 0) {
      return durationSeconds.clamp(0.0, 300.0).toDouble();
    }
    if (sampledAt != null) {
      final previous = _lastSampleAt;
      _lastSampleAt = sampledAt;
      if (previous == null) return 0;
      final delta = sampledAt.difference(previous).inMilliseconds / 1000.0;
      if (!delta.isFinite || delta <= 0) return 0;
      return delta.clamp(0.0, 5.0).toDouble();
    }
    return 1.0;
  }

  SleepMeasurementSummary summary({
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    return SleepMeasurementSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: endedAt.difference(startedAt).inMilliseconds / 1000.0,
      meanHeartRateBpm: _heartCount == 0 ? null : _heartSum / _heartCount,
      meanBreathingRatePerMin:
          _breathingCount == 0 ? null : _breathingSum / _breathingCount,
      meanEarTemperatureC: _earTemperatureCount == 0
          ? null
          : _earTemperatureSum / _earTemperatureCount,
      meanRelativeAngleDeg: _relativeAngleCount == 0
          ? null
          : _relativeAngleSum / _relativeAngleCount,
      snoreTimeFraction: _observedSeconds > 0
          ? _snoreObservedSeconds / _observedSeconds
          : _snoreObservationCount == 0
              ? null
              : _snoreCount / _snoreObservationCount,
      relativeAngleSnore: _buildAngleSnoreAnalysis(),
      poseSnore: _buildPoseSnoreAnalysis(),
    );
  }

  void _addAngleSnorePair(
    double relativeAngleDeg,
    double snoreFraction,
    double durationSeconds,
  ) {
    final snoreValue = snoreFraction.clamp(0.0, 1.0).toDouble();
    _angleSnorePairCount++;
    if (snoreValue > 0) _angleSnoreSampleCount++;
    if (durationSeconds > 0) {
      _angleSnoreObservedSeconds += durationSeconds;
      _angleSnoreSeconds += durationSeconds * snoreValue;
    }
    _angleSnoreSumX += relativeAngleDeg;
    _angleSnoreSumY += snoreValue;
    _angleSnoreSumXX += relativeAngleDeg * relativeAngleDeg;
    _angleSnoreSumYY += snoreValue * snoreValue;
    _angleSnoreSumXY += relativeAngleDeg * snoreValue;

    final index = ((relativeAngleDeg - relativeAngleSnoreMinDeg) /
            relativeAngleSnoreBinSizeDeg)
        .floor()
        .clamp(0, _relativeAngleSnoreBinCount - 1)
        .toInt();
    _angleSnoreBins[index].add(snoreValue, durationSeconds);
  }

  void _addPoseSnorePair(
    double foreheadRollDeg,
    double foreheadPitchDeg,
    double foreheadYawDeg,
    double bellyRollDeg,
    double bellyPitchDeg,
    double bellyYawDeg,
    double snoreFraction,
    double durationSeconds,
    double? heartRate,
    double? breathingRate,
  ) {
    final angles = [
      _wrapAngleDeg(foreheadRollDeg),
      _wrapAngleDeg(foreheadPitchDeg),
      _wrapAngleDeg(foreheadYawDeg),
      _wrapAngleDeg(bellyRollDeg),
      _wrapAngleDeg(bellyPitchDeg),
      _wrapAngleDeg(bellyYawDeg),
    ];
    _poseSnorePairCount++;
    if (snoreFraction > 0) _poseSnoreSampleCount++;
    if (durationSeconds > 0) {
      _poseSnoreObservedSeconds += durationSeconds;
      _poseSnoreSeconds += durationSeconds * snoreFraction;
    }
    _nearestPoseCluster(angles).add(
      angles,
      snoreFraction,
      durationSeconds,
      heartRate,
      breathingRate,
    );

    final featureValues = _poseAngleFeatureValues(angles);
    for (var featureIndex = 0;
        featureIndex < _poseAngleSnoreFeatureBins.length;
        featureIndex++) {
      final binIndex = _poseBinIndex(featureValues[featureIndex]);
      _poseAngleSnoreFeatureBins[featureIndex][binIndex].add(
        snoreFraction,
        durationSeconds,
      );
    }
  }

  _PoseSnoreClusterAccumulator _nearestPoseCluster(List<double> angles) {
    if (_poseSnoreClusters.isEmpty) {
      final cluster = _PoseSnoreClusterAccumulator();
      _poseSnoreClusters.add(cluster);
      return cluster;
    }
    var best = _poseSnoreClusters.first;
    var bestDistance = best.distanceTo(angles);
    for (final cluster in _poseSnoreClusters.skip(1)) {
      final distance = cluster.distanceTo(angles);
      if (distance < bestDistance) {
        best = cluster;
        bestDistance = distance;
      }
    }
    if (bestDistance <= _poseSnoreClusterRadiusDeg ||
        _poseSnoreClusters.length >= _poseSnoreMaxClusters) {
      return best;
    }
    final cluster = _PoseSnoreClusterAccumulator();
    _poseSnoreClusters.add(cluster);
    return cluster;
  }

  RelativeAngleSnoreAnalysis _buildAngleSnoreAnalysis() {
    final bins = <RelativeAngleSnoreBin>[];
    for (var i = 0; i < _angleSnoreBins.length; i++) {
      final accumulator = _angleSnoreBins[i];
      if (accumulator.sampleCount == 0) continue;
      final lower = relativeAngleSnoreMinDeg + i * relativeAngleSnoreBinSizeDeg;
      bins.add(
        RelativeAngleSnoreBin(
          lowerDeg: lower,
          upperDeg: i == _relativeAngleSnoreBinCount - 1
              ? relativeAngleSnoreMaxDeg
              : lower + relativeAngleSnoreBinSizeDeg,
          sampleCount: accumulator.sampleCount,
          snoreCount: accumulator.snoreCount,
          durationSeconds: accumulator.durationSeconds,
          snoreDurationSeconds: accumulator.snoreDurationSeconds,
        ),
      );
    }

    return RelativeAngleSnoreAnalysis(
      sampleCount: _angleSnorePairCount,
      snoreSampleCount: _angleSnoreSampleCount,
      durationSeconds: _angleSnoreObservedSeconds,
      snoreDurationSeconds: _angleSnoreSeconds,
      correlation: _angleSnoreCorrelation(),
      bins: bins,
    );
  }

  PoseSnoreAnalysis _buildPoseSnoreAnalysis() {
    final bins = _poseSnoreClusters
        .where((cluster) => cluster.sampleCount > 0)
        .map((cluster) => cluster.toBin())
        .toList(growable: false)
      ..sort((a, b) {
        final probabilityCompare =
            b.snoreProbability.compareTo(a.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    final angleFeatures = <PoseAngleSnoreFeature>[];
    for (var featureIndex = 0;
        featureIndex < _poseAngleSnoreFeatureBins.length;
        featureIndex++) {
      final featureBins = <PoseAngleSnoreBin>[];
      final accumulators = _poseAngleSnoreFeatureBins[featureIndex];
      for (var binIndex = 0; binIndex < accumulators.length; binIndex++) {
        final accumulator = accumulators[binIndex];
        if (accumulator.sampleCount == 0) continue;
        final lower = poseSnoreMinDeg + binIndex * poseSnoreBinSizeDeg;
        featureBins.add(
          PoseAngleSnoreBin(
            lowerDeg: lower,
            upperDeg: binIndex == _poseSnoreBinCount - 1
                ? poseSnoreMaxDeg
                : lower + poseSnoreBinSizeDeg,
            sampleCount: accumulator.sampleCount,
            snoreSampleCount: accumulator.snoreCount,
            durationSeconds: accumulator.durationSeconds,
            snoreDurationSeconds: accumulator.snoreDurationSeconds,
          ),
        );
      }
      angleFeatures.add(
        PoseAngleSnoreFeature(
          key: _poseAngleFeatureKeys[featureIndex],
          label: _poseAngleFeatureLabels[featureIndex],
          sampleCount: featureBins.fold<int>(
            0,
            (sum, bin) => sum + bin.sampleCount,
          ),
          durationSeconds: featureBins.fold<double>(
            0,
            (sum, bin) => sum + bin.durationSeconds,
          ),
          snoreDurationSeconds: featureBins.fold<double>(
            0,
            (sum, bin) => sum + bin.snoreDurationSeconds,
          ),
          bins: featureBins,
        ),
      );
    }

    return PoseSnoreAnalysis(
      sampleCount: _poseSnorePairCount,
      snoreSampleCount: _poseSnoreSampleCount,
      durationSeconds: _poseSnoreObservedSeconds,
      snoreDurationSeconds: _poseSnoreSeconds,
      bins: bins,
      angleFeatures: angleFeatures,
    );
  }

  double? _angleSnoreCorrelation() {
    final n = _angleSnorePairCount;
    if (n < 2) return null;
    final numerator = n * _angleSnoreSumXY - _angleSnoreSumX * _angleSnoreSumY;
    final xSquares = n * _angleSnoreSumXX - _angleSnoreSumX * _angleSnoreSumX;
    final ySquares = n * _angleSnoreSumYY - _angleSnoreSumY * _angleSnoreSumY;
    final denominator = math.sqrt(xSquares * ySquares);
    if (denominator == 0) return null;
    return (numerator / denominator).clamp(-1.0, 1.0);
  }
}

class SleepMeasurementSummary {
  const SleepMeasurementSummary({
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
    required this.meanHeartRateBpm,
    required this.meanBreathingRatePerMin,
    this.meanEarTemperatureC,
    required this.meanRelativeAngleDeg,
    required this.snoreTimeFraction,
    required this.relativeAngleSnore,
    required this.poseSnore,
  });

  factory SleepMeasurementSummary.fromJson(Map<String, dynamic> json) {
    return SleepMeasurementSummary(
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: DateTime.parse(json['ended_at'] as String),
      durationSeconds: _toDouble(json['duration_seconds']) ?? 0,
      meanHeartRateBpm: _toDouble(json['mean_heart_rate_bpm']),
      meanBreathingRatePerMin: _toDouble(json['mean_breathing_rate_per_min']),
      meanEarTemperatureC: _toDouble(json['mean_ear_temperature_c']),
      meanRelativeAngleDeg: _toDouble(json['mean_relative_angle_deg']),
      snoreTimeFraction: _toDouble(json['snore_time_fraction']),
      relativeAngleSnore: RelativeAngleSnoreAnalysis.fromJson(
        json['relative_angle_snore_analysis'],
      ),
      poseSnore: PoseSnoreAnalysis.fromJson(json['pose_snore_analysis']),
    );
  }

  final DateTime startedAt;
  final DateTime endedAt;
  final double durationSeconds;
  final double? meanHeartRateBpm;
  final double? meanBreathingRatePerMin;
  final double? meanEarTemperatureC;
  final double? meanRelativeAngleDeg;
  final double? snoreTimeFraction;
  final RelativeAngleSnoreAnalysis relativeAngleSnore;
  final PoseSnoreAnalysis poseSnore;

  Map<String, dynamic> toJson() {
    return {
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'duration_seconds': durationSeconds,
      'mean_heart_rate_bpm': meanHeartRateBpm,
      'mean_breathing_rate_per_min': meanBreathingRatePerMin,
      'mean_ear_temperature_c': meanEarTemperatureC,
      'mean_relative_angle_deg': meanRelativeAngleDeg,
      'snore_time_fraction': snoreTimeFraction,
      'relative_angle_snore_analysis': relativeAngleSnore.toJson(),
      'pose_snore_analysis': poseSnore.toJson(),
    };
  }
}

const relativeAngleSnoreMinDeg = -180.0;
const relativeAngleSnoreMaxDeg = 180.0;
const relativeAngleSnoreBinSizeDeg = 15.0;
const _relativeAngleSnoreBinCount = 24;

class RelativeAngleSnoreAnalysis {
  const RelativeAngleSnoreAnalysis({
    required this.sampleCount,
    required this.snoreSampleCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
    required this.correlation,
    required this.bins,
  });

  const RelativeAngleSnoreAnalysis.empty()
      : sampleCount = 0,
        snoreSampleCount = 0,
        durationSeconds = 0,
        snoreDurationSeconds = 0,
        correlation = null,
        bins = const [];

  factory RelativeAngleSnoreAnalysis.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const RelativeAngleSnoreAnalysis.empty();
    }
    final bins = (json['bins'] as List<dynamic>? ?? const [])
        .map((entry) => RelativeAngleSnoreBin.fromJson(entry))
        .where((bin) => bin.sampleCount > 0)
        .toList(growable: false);
    final durationSeconds = _toDouble(json['duration_seconds']) ??
        bins.fold<double>(0, (sum, bin) => sum + bin.durationSeconds);
    final snoreDurationSeconds = _toDouble(json['snore_duration_seconds']) ??
        bins.fold<double>(0, (sum, bin) => sum + bin.snoreDurationSeconds);
    return RelativeAngleSnoreAnalysis(
      sampleCount: _toInt(json['sample_count']) ?? 0,
      snoreSampleCount: _toInt(json['snore_sample_count']) ?? 0,
      durationSeconds: durationSeconds,
      snoreDurationSeconds: snoreDurationSeconds,
      correlation: _toDouble(json['correlation']),
      bins: bins,
    );
  }

  final int sampleCount;
  final int snoreSampleCount;
  final double durationSeconds;
  final double snoreDurationSeconds;
  final double? correlation;
  final List<RelativeAngleSnoreBin> bins;

  bool get hasData => sampleCount > 0 && bins.isNotEmpty;

  int get minimumReliableBinSamples {
    if (sampleCount <= 0) return 20;
    return math.max(20, math.min(1000, (sampleCount * 0.01).round())).toInt();
  }

  double get minimumReliableBinSeconds {
    if (durationSeconds <= 0) return minimumReliableBinSamples.toDouble();
    return math.max(30.0, math.min(300.0, durationSeconds * 0.01)).toDouble();
  }

  List<RelativeAngleSnoreBin> get reliableBins {
    final minimumSamples = minimumReliableBinSamples;
    final minimumSeconds = minimumReliableBinSeconds;
    return bins.where((bin) {
      if (bin.durationSeconds > 0) return bin.durationSeconds >= minimumSeconds;
      return bin.sampleCount >= minimumSamples;
    }).toList(growable: false);
  }

  RelativeAngleSnoreBin? get mostSnoredBin {
    final candidates = reliableBins;
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]..sort((a, b) {
        final probabilityCompare =
            b.snoreProbability.compareTo(a.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.sampleCount.compareTo(a.sampleCount);
      });
    return sorted.first;
  }

  RelativeAngleSnoreBin? get leastSnoredBin {
    final candidates = reliableBins;
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]..sort((a, b) {
        final probabilityCompare =
            a.snoreProbability.compareTo(b.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.sampleCount.compareTo(a.sampleCount);
      });
    return sorted.first;
  }

  double? get probabilitySpread {
    final most = mostSnoredBin;
    final least = leastSnoredBin;
    if (most == null || least == null) return null;
    return most.snoreProbability - least.snoreProbability;
  }

  Map<String, dynamic> toJson() {
    return {
      'sample_count': sampleCount,
      'snore_sample_count': snoreSampleCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
      'correlation': correlation,
      'bins': bins.map((bin) => bin.toJson()).toList(growable: false),
    };
  }
}

class RelativeAngleSnoreBin {
  const RelativeAngleSnoreBin({
    required this.lowerDeg,
    required this.upperDeg,
    required this.sampleCount,
    required this.snoreCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
  });

  factory RelativeAngleSnoreBin.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const RelativeAngleSnoreBin(
        lowerDeg: 0,
        upperDeg: 0,
        sampleCount: 0,
        snoreCount: 0,
        durationSeconds: 0,
        snoreDurationSeconds: 0,
      );
    }
    final sampleCount = _toInt(json['sample_count']) ?? 0;
    final snoreCount = _toInt(json['snore_count']) ?? 0;
    return RelativeAngleSnoreBin(
      lowerDeg: _toDouble(json['lower_deg']) ?? 0,
      upperDeg: _toDouble(json['upper_deg']) ?? 0,
      sampleCount: sampleCount,
      snoreCount: snoreCount,
      durationSeconds:
          _toDouble(json['duration_seconds']) ?? sampleCount.toDouble(),
      snoreDurationSeconds:
          _toDouble(json['snore_duration_seconds']) ?? snoreCount.toDouble(),
    );
  }

  final double lowerDeg;
  final double upperDeg;
  final int sampleCount;
  final int snoreCount;
  final double durationSeconds;
  final double snoreDurationSeconds;

  double get snoreProbability => durationSeconds > 0
      ? snoreDurationSeconds / durationSeconds
      : sampleCount == 0
          ? 0
          : snoreCount / sampleCount;

  String get rangeLabel =>
      '${_formatAngleLabel(lowerDeg)} bis ${_formatAngleLabel(upperDeg)} deg';

  Map<String, dynamic> toJson() {
    return {
      'lower_deg': lowerDeg,
      'upper_deg': upperDeg,
      'sample_count': sampleCount,
      'snore_count': snoreCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
    };
  }
}

class _AngleSnoreBinAccumulator {
  int sampleCount = 0;
  int snoreCount = 0;
  double durationSeconds = 0;
  double snoreDurationSeconds = 0;

  void add(double snoreFraction, double seconds) {
    final fraction = snoreFraction.clamp(0.0, 1.0).toDouble();
    sampleCount++;
    if (fraction > 0) snoreCount++;
    if (seconds <= 0) return;
    durationSeconds += seconds;
    snoreDurationSeconds += seconds * fraction;
  }

  void reset() {
    sampleCount = 0;
    snoreCount = 0;
    durationSeconds = 0;
    snoreDurationSeconds = 0;
  }
}

const poseSnoreMinDeg = -180.0;
const poseSnoreMaxDeg = 180.0;
const poseSnoreBinSizeDeg = 30.0;
const _poseSnoreBinCount = 12;
const _poseSnoreClusterRadiusDeg = 35.0;
const _poseSnoreMaxClusters = 48;
const _poseAngleFeatureCount = 6;
const _poseAngleFeatureKeys = [
  'forehead_rotation',
  'forehead_tilt',
  'belly_rotation',
  'belly_tilt',
  'relative_rotation',
  'relative_tilt',
];
const _poseAngleFeatureLabels = [
  'Kopf Drehung',
  'Kopf Neigung',
  'Brust Drehung',
  'Brust Neigung',
  'Relative Drehung',
  'Relative Neigung',
];

class PoseSnoreAnalysis {
  const PoseSnoreAnalysis({
    required this.sampleCount,
    required this.snoreSampleCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
    required this.bins,
    required this.angleFeatures,
  });

  const PoseSnoreAnalysis.empty()
      : sampleCount = 0,
        snoreSampleCount = 0,
        durationSeconds = 0,
        snoreDurationSeconds = 0,
        bins = const [],
        angleFeatures = const [];

  factory PoseSnoreAnalysis.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const PoseSnoreAnalysis.empty();
    final bins = (json['bins'] as List<dynamic>? ?? const [])
        .map((entry) => PoseSnoreBin.fromJson(entry))
        .where((bin) => bin.sampleCount > 0)
        .toList(growable: false);
    final durationSeconds = _toDouble(json['duration_seconds']) ??
        bins.fold<double>(0, (sum, bin) => sum + bin.durationSeconds);
    final snoreDurationSeconds = _toDouble(json['snore_duration_seconds']) ??
        bins.fold<double>(0, (sum, bin) => sum + bin.snoreDurationSeconds);
    return PoseSnoreAnalysis(
      sampleCount: _toInt(json['sample_count']) ?? 0,
      snoreSampleCount: _toInt(json['snore_sample_count']) ?? 0,
      durationSeconds: durationSeconds,
      snoreDurationSeconds: snoreDurationSeconds,
      bins: bins,
      angleFeatures: (json['angle_features'] as List<dynamic>? ?? const [])
          .map((entry) => PoseAngleSnoreFeature.fromJson(entry))
          .where((feature) => feature.bins.isNotEmpty)
          .toList(growable: false),
    );
  }

  final int sampleCount;
  final int snoreSampleCount;
  final double durationSeconds;
  final double snoreDurationSeconds;
  final List<PoseSnoreBin> bins;
  final List<PoseAngleSnoreFeature> angleFeatures;

  bool get hasData => sampleCount > 0 && bins.isNotEmpty;

  double get baselineSnoreProbability => durationSeconds > 0
      ? snoreDurationSeconds / durationSeconds
      : sampleCount == 0
          ? 0
          : snoreSampleCount / sampleCount;

  double get minimumReliableBinSeconds {
    if (durationSeconds <= 0) return 30;
    return math.max(30.0, math.min(300.0, durationSeconds * 0.01)).toDouble();
  }

  List<PoseSnoreBin> get reliableBins {
    final minimum = minimumReliableBinSeconds;
    return bins
        .where((bin) => bin.durationSeconds >= minimum)
        .toList(growable: false);
  }

  List<PoseSnoreBin> topRiskBins({int limit = 3}) {
    final candidates = reliableBins.isNotEmpty
        ? reliableBins
        : bins.where((bin) => bin.durationSeconds > 0).toList(growable: false);
    final sorted = [...candidates]..sort((a, b) {
        final probabilityCompare =
            b.snoreProbability.compareTo(a.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    return sorted.take(limit).toList(growable: false);
  }

  List<PoseSnoreBin> lowestRiskBins({int limit = 3}) {
    final candidates = reliableBins.isNotEmpty
        ? reliableBins
        : bins.where((bin) => bin.durationSeconds > 0).toList(growable: false);
    final sorted = [...candidates]..sort((a, b) {
        final probabilityCompare =
            a.snoreProbability.compareTo(b.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    return sorted.take(limit).toList(growable: false);
  }

  List<PoseSnoreBin> lowestHeartRateBins({int limit = 1}) {
    final candidates = (reliableBins.isNotEmpty
            ? reliableBins
            : bins.where((bin) => bin.durationSeconds > 0))
        .where((bin) => bin.meanHeartRateBpm?.isFinite == true)
        .toList(growable: false);
    final sorted = [...candidates]..sort((a, b) {
        final valueCompare = a.meanHeartRateBpm!.compareTo(b.meanHeartRateBpm!);
        if (valueCompare != 0) return valueCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    return sorted.take(limit).toList(growable: false);
  }

  List<PoseSnoreBin> lowestBreathingRateBins({int limit = 1}) {
    final candidates = (reliableBins.isNotEmpty
            ? reliableBins
            : bins.where((bin) => bin.durationSeconds > 0))
        .where((bin) => bin.meanBreathingRatePerMin?.isFinite == true)
        .toList(growable: false);
    final sorted = [...candidates]..sort((a, b) {
        final valueCompare =
            a.meanBreathingRatePerMin!.compareTo(b.meanBreathingRatePerMin!);
        if (valueCompare != 0) return valueCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    return sorted.take(limit).toList(growable: false);
  }

  PoseSnoreEstimate? estimateAtVisiblePose({
    required double foreheadRollDeg,
    required double foreheadPitchDeg,
    required double bellyRollDeg,
    required double bellyPitchDeg,
  }) {
    final pose = [
      foreheadRollDeg,
      foreheadPitchDeg,
      bellyRollDeg,
      bellyPitchDeg,
    ];
    if (pose.any((value) => !value.isFinite)) return null;
    final candidates = reliableBins;
    if (candidates.isEmpty) return null;

    final matches = <({PoseSnoreBin bin, double distance})>[];
    for (final bin in candidates) {
      final distance = _visiblePoseDistanceDeg(pose, bin);
      final radius = math.max(
        _poseSnoreClusterRadiusDeg,
        bin.clusterRadiusDeg,
      );
      if (distance <= radius * 1.4) {
        matches.add((bin: bin, distance: distance));
      }
    }
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.distance.compareTo(b.distance));

    var weightedSnoreSeconds = 0.0;
    var weightedObservedSeconds = 0.0;
    var observedSeconds = 0.0;
    for (final match in matches.take(4)) {
      final radius = math.max(
        _poseSnoreClusterRadiusDeg,
        match.bin.clusterRadiusDeg,
      );
      final normalizedDistance = match.distance / math.max(1.0, radius);
      final spatialWeight =
          math.exp(-0.5 * normalizedDistance * normalizedDistance);
      weightedSnoreSeconds += match.bin.snoreDurationSeconds * spatialWeight;
      weightedObservedSeconds += match.bin.durationSeconds * spatialWeight;
      observedSeconds += match.bin.durationSeconds;
    }
    if (weightedObservedSeconds <= 0) return null;
    return PoseSnoreEstimate(
      probability:
          (weightedSnoreSeconds / weightedObservedSeconds).clamp(0.0, 1.0),
      observedSeconds: observedSeconds,
      nearestDistanceDeg: matches.first.distance,
      matchingBinCount: math.min(4, matches.length),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sample_count': sampleCount,
      'snore_sample_count': snoreSampleCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
      'bins': bins.map((bin) => bin.toJson()).toList(growable: false),
      'angle_features': angleFeatures.map((feature) => feature.toJson()).toList(
            growable: false,
          ),
    };
  }
}

class PoseSnoreEstimate {
  const PoseSnoreEstimate({
    required this.probability,
    required this.observedSeconds,
    required this.nearestDistanceDeg,
    required this.matchingBinCount,
  });

  final double probability;
  final double observedSeconds;
  final double nearestDistanceDeg;
  final int matchingBinCount;
}

double _visiblePoseDistanceDeg(
  List<double> pose,
  PoseSnoreBin bin,
) {
  final center = [
    bin.foreheadRollDeg,
    bin.foreheadPitchDeg,
    bin.bellyRollDeg,
    bin.bellyPitchDeg,
  ];
  var sumSquares = 0.0;
  for (var i = 0; i < pose.length; i++) {
    final delta = _angleDeltaDeg(pose[i], center[i]);
    sumSquares += delta * delta;
  }
  return math.sqrt(sumSquares);
}

class PoseSnoreBin {
  const PoseSnoreBin({
    required this.foreheadRollDeg,
    required this.foreheadPitchDeg,
    required this.foreheadYawDeg,
    required this.bellyRollDeg,
    required this.bellyPitchDeg,
    required this.bellyYawDeg,
    required this.clusterRadiusDeg,
    required this.foreheadLowerDeg,
    required this.foreheadUpperDeg,
    required this.bellyLowerDeg,
    required this.bellyUpperDeg,
    required this.sampleCount,
    required this.snoreSampleCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
    this.meanHeartRateBpm,
    this.meanBreathingRatePerMin,
  });

  factory PoseSnoreBin.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const PoseSnoreBin(
        foreheadRollDeg: 0,
        foreheadPitchDeg: 0,
        foreheadYawDeg: 0,
        bellyRollDeg: 0,
        bellyPitchDeg: 0,
        bellyYawDeg: 0,
        clusterRadiusDeg: _poseSnoreClusterRadiusDeg,
        foreheadLowerDeg: 0,
        foreheadUpperDeg: 0,
        bellyLowerDeg: 0,
        bellyUpperDeg: 0,
        sampleCount: 0,
        snoreSampleCount: 0,
        durationSeconds: 0,
        snoreDurationSeconds: 0,
      );
    }
    final sampleCount = _toInt(json['sample_count']) ?? 0;
    final snoreSampleCount =
        _toInt(json['snore_sample_count']) ?? _toInt(json['snore_count']) ?? 0;
    final legacyForeheadLower = _toDouble(json['forehead_lower_deg']) ?? 0;
    final legacyForeheadUpper = _toDouble(json['forehead_upper_deg']) ?? 0;
    final legacyBellyLower = _toDouble(json['belly_lower_deg']) ?? 0;
    final legacyBellyUpper = _toDouble(json['belly_upper_deg']) ?? 0;
    final foreheadRollDeg = _wrapAngleDeg(
      _toDouble(json['forehead_roll_deg']) ??
          (legacyForeheadLower + legacyForeheadUpper) / 2,
    );
    final bellyRollDeg = _wrapAngleDeg(
      _toDouble(json['belly_roll_deg']) ??
          (legacyBellyLower + legacyBellyUpper) / 2,
    );
    return PoseSnoreBin(
      foreheadRollDeg: foreheadRollDeg,
      foreheadPitchDeg:
          _wrapAngleDeg(_toDouble(json['forehead_pitch_deg']) ?? 0),
      foreheadYawDeg: _wrapAngleDeg(_toDouble(json['forehead_yaw_deg']) ?? 0),
      bellyRollDeg: bellyRollDeg,
      bellyPitchDeg: _wrapAngleDeg(_toDouble(json['belly_pitch_deg']) ?? 0),
      bellyYawDeg: _wrapAngleDeg(_toDouble(json['belly_yaw_deg']) ?? 0),
      clusterRadiusDeg:
          _toDouble(json['cluster_radius_deg']) ?? _poseSnoreClusterRadiusDeg,
      foreheadLowerDeg: legacyForeheadLower,
      foreheadUpperDeg: legacyForeheadUpper,
      bellyLowerDeg: legacyBellyLower,
      bellyUpperDeg: legacyBellyUpper,
      sampleCount: sampleCount,
      snoreSampleCount: snoreSampleCount,
      durationSeconds:
          _toDouble(json['duration_seconds']) ?? sampleCount.toDouble(),
      snoreDurationSeconds: _toDouble(json['snore_duration_seconds']) ??
          snoreSampleCount.toDouble(),
      meanHeartRateBpm: _toDouble(json['mean_heart_rate_bpm']),
      meanBreathingRatePerMin: _toDouble(json['mean_breathing_rate_per_min']),
    );
  }

  final double foreheadRollDeg;
  final double foreheadPitchDeg;
  final double foreheadYawDeg;
  final double bellyRollDeg;
  final double bellyPitchDeg;
  final double bellyYawDeg;
  final double clusterRadiusDeg;
  final double foreheadLowerDeg;
  final double foreheadUpperDeg;
  final double bellyLowerDeg;
  final double bellyUpperDeg;
  final int sampleCount;
  final int snoreSampleCount;
  final double durationSeconds;
  final double snoreDurationSeconds;
  final double? meanHeartRateBpm;
  final double? meanBreathingRatePerMin;

  double get foreheadCenterDeg => foreheadRollDeg;

  double get bellyCenterDeg => bellyRollDeg;

  double get relativeRollCenterDeg =>
      _angleDeltaDeg(foreheadRollDeg, bellyRollDeg);

  double get relativePitchCenterDeg =>
      _angleDeltaDeg(foreheadPitchDeg, bellyPitchDeg);

  double get relativeYawCenterDeg =>
      _angleDeltaDeg(foreheadYawDeg, bellyYawDeg);

  double get snoreProbability => durationSeconds > 0
      ? snoreDurationSeconds / durationSeconds
      : sampleCount == 0
          ? 0
          : snoreSampleCount / sampleCount;

  String get rangeLabel =>
      'Kopf Drehung/Neigung ${_formatAngleLabel(foreheadRollDeg)}/'
      '${_formatAngleLabel(foreheadPitchDeg)} deg, '
      'Brust Drehung/Neigung ${_formatAngleLabel(bellyRollDeg)}/'
      '${_formatAngleLabel(bellyPitchDeg)} deg';

  Map<String, dynamic> toJson() {
    return {
      'forehead_roll_deg': foreheadRollDeg,
      'forehead_pitch_deg': foreheadPitchDeg,
      'forehead_yaw_deg': foreheadYawDeg,
      'belly_roll_deg': bellyRollDeg,
      'belly_pitch_deg': bellyPitchDeg,
      'belly_yaw_deg': bellyYawDeg,
      'cluster_radius_deg': clusterRadiusDeg,
      'forehead_lower_deg': foreheadLowerDeg,
      'forehead_upper_deg': foreheadUpperDeg,
      'belly_lower_deg': bellyLowerDeg,
      'belly_upper_deg': bellyUpperDeg,
      'sample_count': sampleCount,
      'snore_sample_count': snoreSampleCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
      'mean_heart_rate_bpm': meanHeartRateBpm,
      'mean_breathing_rate_per_min': meanBreathingRatePerMin,
    };
  }
}

class PoseAngleSnoreFeature {
  const PoseAngleSnoreFeature({
    required this.key,
    required this.label,
    required this.sampleCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
    required this.bins,
  });

  factory PoseAngleSnoreFeature.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const PoseAngleSnoreFeature(
        key: '',
        label: '',
        sampleCount: 0,
        durationSeconds: 0,
        snoreDurationSeconds: 0,
        bins: [],
      );
    }
    final bins = (json['bins'] as List<dynamic>? ?? const [])
        .map((entry) => PoseAngleSnoreBin.fromJson(entry))
        .where((bin) => bin.sampleCount > 0)
        .toList(growable: false);
    return PoseAngleSnoreFeature(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      sampleCount: _toInt(json['sample_count']) ?? 0,
      durationSeconds: _toDouble(json['duration_seconds']) ??
          bins.fold<double>(0, (sum, bin) => sum + bin.durationSeconds),
      snoreDurationSeconds: _toDouble(json['snore_duration_seconds']) ??
          bins.fold<double>(0, (sum, bin) => sum + bin.snoreDurationSeconds),
      bins: bins,
    );
  }

  final String key;
  final String label;
  final int sampleCount;
  final double durationSeconds;
  final double snoreDurationSeconds;
  final List<PoseAngleSnoreBin> bins;

  bool get hasData => bins.isNotEmpty;

  double get minimumReliableBinSeconds {
    if (durationSeconds <= 0) return 30;
    return math.max(30.0, math.min(300.0, durationSeconds * 0.01)).toDouble();
  }

  List<PoseAngleSnoreBin> get reliableBins {
    final minimum = minimumReliableBinSeconds;
    return bins
        .where((bin) => bin.durationSeconds >= minimum)
        .toList(growable: false);
  }

  List<PoseAngleSnoreBin> topBins({int limit = 3}) {
    final candidates = reliableBins.isNotEmpty
        ? reliableBins
        : bins.where((bin) => bin.durationSeconds > 0).toList(growable: false);
    candidates.sort((a, b) {
      final probabilityCompare =
          b.snoreProbability.compareTo(a.snoreProbability);
      if (probabilityCompare != 0) return probabilityCompare;
      return b.durationSeconds.compareTo(a.durationSeconds);
    });
    return candidates.take(limit).toList(growable: false);
  }

  PoseAngleSnoreBin? get mostSnoredBin {
    final top = topBins(limit: 1);
    return top.isEmpty ? null : top.first;
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'label': label,
      'sample_count': sampleCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
      'bins': bins.map((bin) => bin.toJson()).toList(growable: false),
    };
  }
}

class PoseAngleSnoreBin {
  const PoseAngleSnoreBin({
    required this.lowerDeg,
    required this.upperDeg,
    required this.sampleCount,
    required this.snoreSampleCount,
    required this.durationSeconds,
    required this.snoreDurationSeconds,
  });

  factory PoseAngleSnoreBin.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const PoseAngleSnoreBin(
        lowerDeg: 0,
        upperDeg: 0,
        sampleCount: 0,
        snoreSampleCount: 0,
        durationSeconds: 0,
        snoreDurationSeconds: 0,
      );
    }
    final sampleCount = _toInt(json['sample_count']) ?? 0;
    final snoreSampleCount = _toInt(json['snore_sample_count']) ?? 0;
    return PoseAngleSnoreBin(
      lowerDeg: _toDouble(json['lower_deg']) ?? 0,
      upperDeg: _toDouble(json['upper_deg']) ?? 0,
      sampleCount: sampleCount,
      snoreSampleCount: snoreSampleCount,
      durationSeconds:
          _toDouble(json['duration_seconds']) ?? sampleCount.toDouble(),
      snoreDurationSeconds: _toDouble(json['snore_duration_seconds']) ??
          snoreSampleCount.toDouble(),
    );
  }

  final double lowerDeg;
  final double upperDeg;
  final int sampleCount;
  final int snoreSampleCount;
  final double durationSeconds;
  final double snoreDurationSeconds;

  double get snoreProbability => durationSeconds > 0
      ? snoreDurationSeconds / durationSeconds
      : sampleCount == 0
          ? 0
          : snoreSampleCount / sampleCount;

  String get rangeLabel => _rangeLabel(lowerDeg, upperDeg);

  Map<String, dynamic> toJson() {
    return {
      'lower_deg': lowerDeg,
      'upper_deg': upperDeg,
      'sample_count': sampleCount,
      'snore_sample_count': snoreSampleCount,
      'duration_seconds': durationSeconds,
      'snore_duration_seconds': snoreDurationSeconds,
    };
  }
}

class _PoseSnoreClusterAccumulator {
  final List<_CircularAngleMean> _means = List.generate(
    6,
    (_) => _CircularAngleMean(),
  );
  int sampleCount = 0;
  int snoreCount = 0;
  double durationSeconds = 0;
  double snoreDurationSeconds = 0;
  double heartRateWeightedSum = 0;
  double heartRateWeight = 0;
  double breathingRateWeightedSum = 0;
  double breathingRateWeight = 0;

  List<double> get centerAngles =>
      _means.map((mean) => mean.angleDeg).toList(growable: false);

  void add(
    List<double> angles,
    double snoreFraction,
    double seconds,
    double? heartRate,
    double? breathingRate,
  ) {
    final weight = seconds > 0 ? seconds : 1.0;
    sampleCount++;
    if (snoreFraction > 0) snoreCount++;
    for (var i = 0; i < _means.length; i++) {
      _means[i].add(angles[i], weight);
    }
    if (heartRate != null && heartRate.isFinite) {
      heartRateWeightedSum += heartRate * weight;
      heartRateWeight += weight;
    }
    if (breathingRate != null && breathingRate.isFinite) {
      breathingRateWeightedSum += breathingRate * weight;
      breathingRateWeight += weight;
    }
    if (seconds <= 0) return;
    durationSeconds += seconds;
    snoreDurationSeconds += seconds * snoreFraction.clamp(0.0, 1.0);
  }

  double distanceTo(List<double> angles) {
    if (sampleCount == 0) return double.infinity;
    final center = centerAngles;
    var sumSquares = 0.0;
    for (var i = 0; i < center.length; i++) {
      final delta = _angleDeltaDeg(angles[i], center[i]);
      sumSquares += delta * delta;
    }
    return math.sqrt(sumSquares);
  }

  PoseSnoreBin toBin() {
    final center = centerAngles;
    final halfWidth = poseSnoreBinSizeDeg / 2;
    return PoseSnoreBin(
      foreheadRollDeg: center[0],
      foreheadPitchDeg: center[1],
      foreheadYawDeg: center[2],
      bellyRollDeg: center[3],
      bellyPitchDeg: center[4],
      bellyYawDeg: center[5],
      clusterRadiusDeg: _poseSnoreClusterRadiusDeg,
      foreheadLowerDeg: _wrapAngleDeg(center[0] - halfWidth),
      foreheadUpperDeg: _wrapAngleDeg(center[0] + halfWidth),
      bellyLowerDeg: _wrapAngleDeg(center[3] - halfWidth),
      bellyUpperDeg: _wrapAngleDeg(center[3] + halfWidth),
      sampleCount: sampleCount,
      snoreSampleCount: snoreCount,
      durationSeconds: durationSeconds,
      snoreDurationSeconds: snoreDurationSeconds,
      meanHeartRateBpm:
          heartRateWeight <= 0 ? null : heartRateWeightedSum / heartRateWeight,
      meanBreathingRatePerMin: breathingRateWeight <= 0
          ? null
          : breathingRateWeightedSum / breathingRateWeight,
    );
  }
}

class _CircularAngleMean {
  double _sinSum = 0;
  double _cosSum = 0;
  double _fallbackDeg = 0;

  void add(double angleDeg, double weight) {
    final radians = angleDeg * math.pi / 180;
    _sinSum += math.sin(radians) * weight;
    _cosSum += math.cos(radians) * weight;
    _fallbackDeg = angleDeg;
  }

  double get angleDeg {
    if (_sinSum == 0 && _cosSum == 0) return _fallbackDeg;
    return _wrapAngleDeg(math.atan2(_sinSum, _cosSum) * 180 / math.pi);
  }
}

class SleepSessionRecord {
  const SleepSessionRecord({
    required this.id,
    required this.createdAt,
    required this.metrics,
    required this.answers,
    required this.score,
    required this.tips,
    this.dataCsvPath,
  });

  factory SleepSessionRecord.fromJson(Map<String, dynamic> json) {
    final metrics = SleepMeasurementSummary.fromJson(
      json['metrics'] as Map<String, dynamic>,
    );
    final answers = (json['answers'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, (value as num).toInt()),
    );
    return SleepSessionRecord(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      metrics: metrics,
      answers: answers,
      score: computeSleepScore(answers, metrics),
      tips: (json['tips'] as List<dynamic>? ?? const [])
          .map((entry) => entry.toString())
          .toList(growable: false),
      dataCsvPath: json['data_csv_path'] as String?,
    );
  }

  final String id;
  final DateTime createdAt;
  final SleepMeasurementSummary metrics;
  final Map<String, int> answers;
  final double score;
  final List<String> tips;
  final String? dataCsvPath;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'metrics': metrics.toJson(),
      'answers': answers,
      'score': score,
      'tips': tips,
      'data_csv_path': dataCsvPath,
    };
  }
}

class SleepSessionSeriesPoint {
  const SleepSessionSeriesPoint({
    required this.time,
    required this.minute,
    this.heartRateBpm,
    this.breathingRatePerMin,
    this.snoreSeconds,
    this.snoreWindowCount,
    this.yamnetSnoreSeconds,
    this.yamnetSnoreWindowCount,
    this.snoreVolumePercent,
    this.snoreSource,
    this.earTemperatureC,
    this.ppgQualityPercent,
    this.breathingQualityPercent,
    this.foreheadRollDeg,
    this.foreheadPitchDeg,
    this.foreheadYawDeg,
    this.bellyRollDeg,
    this.bellyPitchDeg,
    this.bellyYawDeg,
  });

  final DateTime time;
  final int minute;
  final double? heartRateBpm;
  final double? breathingRatePerMin;
  final double? snoreSeconds;
  final double? snoreWindowCount;
  final double? yamnetSnoreSeconds;
  final double? yamnetSnoreWindowCount;
  final double? snoreVolumePercent;
  final String? snoreSource;
  final double? earTemperatureC;
  final double? ppgQualityPercent;
  final double? breathingQualityPercent;
  final double? foreheadRollDeg;
  final double? foreheadPitchDeg;
  final double? foreheadYawDeg;
  final double? bellyRollDeg;
  final double? bellyPitchDeg;
  final double? bellyYawDeg;

  bool get hasPose =>
      foreheadRollDeg != null &&
      foreheadPitchDeg != null &&
      foreheadYawDeg != null &&
      bellyRollDeg != null &&
      bellyPitchDeg != null &&
      bellyYawDeg != null;

  bool get hasForeheadPose =>
      foreheadRollDeg != null &&
      foreheadPitchDeg != null &&
      foreheadYawDeg != null;

  bool get hasBellyPose =>
      bellyRollDeg != null && bellyPitchDeg != null && bellyYawDeg != null;

  bool get hasAnyPose => hasForeheadPose || hasBellyPose;

  SleepSessionSeriesPoint copyWith({
    double? heartRateBpm,
    double? breathingRatePerMin,
    double? snoreSeconds,
    double? snoreWindowCount,
    double? yamnetSnoreSeconds,
    double? yamnetSnoreWindowCount,
    double? snoreVolumePercent,
    String? snoreSource,
    bool clearHeartRateBpm = false,
    bool clearBreathingRatePerMin = false,
    bool clearSnoreSeconds = false,
    bool clearSnoreWindowCount = false,
    bool clearYamnetSnoreSeconds = false,
    bool clearYamnetSnoreWindowCount = false,
    bool clearSnoreVolumePercent = false,
    bool clearSnoreSource = false,
  }) {
    return SleepSessionSeriesPoint(
      time: time,
      minute: minute,
      heartRateBpm:
          clearHeartRateBpm ? null : heartRateBpm ?? this.heartRateBpm,
      breathingRatePerMin: clearBreathingRatePerMin
          ? null
          : breathingRatePerMin ?? this.breathingRatePerMin,
      snoreSeconds:
          clearSnoreSeconds ? null : snoreSeconds ?? this.snoreSeconds,
      snoreWindowCount: clearSnoreWindowCount
          ? null
          : snoreWindowCount ?? this.snoreWindowCount,
      yamnetSnoreSeconds: clearYamnetSnoreSeconds
          ? null
          : yamnetSnoreSeconds ?? this.yamnetSnoreSeconds,
      yamnetSnoreWindowCount: clearYamnetSnoreWindowCount
          ? null
          : yamnetSnoreWindowCount ?? this.yamnetSnoreWindowCount,
      snoreVolumePercent: clearSnoreVolumePercent
          ? null
          : snoreVolumePercent ?? this.snoreVolumePercent,
      snoreSource: clearSnoreSource ? null : snoreSource ?? this.snoreSource,
      earTemperatureC: earTemperatureC,
      ppgQualityPercent: ppgQualityPercent,
      breathingQualityPercent: breathingQualityPercent,
      foreheadRollDeg: foreheadRollDeg,
      foreheadPitchDeg: foreheadPitchDeg,
      foreheadYawDeg: foreheadYawDeg,
      bellyRollDeg: bellyRollDeg,
      bellyPitchDeg: bellyPitchDeg,
      bellyYawDeg: bellyYawDeg,
    );
  }
}

double? snorePhaseSecondsForMinute(Iterable<double?> rawValues) {
  var hasObservation = false;
  for (final value in rawValues) {
    if (value == null || !value.isFinite) continue;
    hasObservation = true;
    if (value > 0) return 60.0;
  }
  return hasObservation ? 0.0 : null;
}

double? maximumSnoreVolumePercent(Iterable<double?> rawValues) {
  double? maximum;
  for (final value in rawValues) {
    if (value == null || !value.isFinite) continue;
    final clamped = value.clamp(0.0, 100.0).toDouble();
    maximum = maximum == null ? clamped : math.max(maximum, clamped);
  }
  return maximum;
}

class SleepCorrelation {
  const SleepCorrelation({
    required this.label,
    required this.correlation,
    required this.sampleCount,
  });

  final String label;
  final double correlation;
  final int sampleCount;

  String get directionText {
    if (correlation >= 0.35) return 'hoeher = besser';
    if (correlation <= -0.35) return 'hoeher = schlechter';
    return 'schwach';
  }
}

class SleepQuestionPhysiologyCorrelation {
  const SleepQuestionPhysiologyCorrelation({
    required this.questionId,
    required this.label,
    required this.prompt,
    required this.lowLabel,
    required this.highLabel,
    required this.heartRateCorrelation,
    required this.heartRateSampleCount,
    required this.breathingRateCorrelation,
    required this.breathingRateSampleCount,
  });

  final String questionId;
  final String label;
  final String prompt;
  final String? lowLabel;
  final String? highLabel;
  final double? heartRateCorrelation;
  final int heartRateSampleCount;
  final double? breathingRateCorrelation;
  final int breathingRateSampleCount;

  double get strongestAbsoluteCorrelation => math.max(
        heartRateCorrelation?.abs() ?? 0,
        breathingRateCorrelation?.abs() ?? 0,
      );
}

class SleepJournalSummary {
  const SleepJournalSummary({
    required this.sessionCount,
    required this.averageScore,
    required this.averageHeartRateBpm,
    required this.averageBreathingRatePerMin,
    required this.averageSnorePercent,
  });

  const SleepJournalSummary.empty()
      : sessionCount = 0,
        averageScore = null,
        averageHeartRateBpm = null,
        averageBreathingRatePerMin = null,
        averageSnorePercent = null;

  final int sessionCount;
  final double? averageScore;
  final double? averageHeartRateBpm;
  final double? averageBreathingRatePerMin;
  final double? averageSnorePercent;
}

const defaultSleepQuestions = [
  SleepQuestion(
    id: 'evening_stress',
    title: 'Stress',
    prompt: 'Wie gestresst warst du heute?',
    phase: SleepQuestionPhase.evening,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'gar nicht gestresst',
    highLabel: 'extrem gestresst',
  ),
  SleepQuestion(
    id: 'evening_last_meal',
    title: 'Letzte Mahlzeit',
    prompt: 'Wie lange vor dem Schlafengehen war deine letzte Mahlzeit?',
    phase: SleepQuestionPhase.evening,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'weniger als 30 Min',
    highLabel: 'mehr als 3 Stunden',
  ),
  SleepQuestion(
    id: 'evening_screen_time',
    title: 'Bildschirmzeit',
    prompt:
        'Wie intensiv war deine Bildschirmnutzung in den letzten 2 Stunden vor dem Schlafengehen?',
    phase: SleepQuestionPhase.evening,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'gar nicht',
    highLabel: 'sehr intensiv',
  ),
  SleepQuestion(
    id: 'evening_sleep_regular',
    title: 'Schlafrhythmus',
    prompt:
        'Wie regelmaessig waren deine Schlafenszeiten in den letzten 7 Tagen?',
    phase: SleepQuestionPhase.evening,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'sehr unregelmaessig',
    highLabel: 'sehr regelmaessig',
  ),
  SleepQuestion(
    id: 'evening_activity',
    title: 'Koerperliche Aktivitaet',
    prompt:
        'Wie haeufig warst du in den letzten 7 Tagen koerperlich aktiv oder hast Sport gemacht?',
    phase: SleepQuestionPhase.evening,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'gar nicht',
    highLabel: 'taeglich',
  ),
  SleepQuestion(
    id: 'morning_sleep_onset_difficulty',
    title: 'Einschlafschwierigkeiten',
    prompt: 'Wie starke Einschlafschwierigkeiten hattest du?',
    phase: SleepQuestionPhase.morning,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'keine',
    highLabel: 'sehr starke',
  ),
  SleepQuestion(
    id: 'morning_recovery',
    title: 'Erholung',
    prompt: 'Wie erholt fuehlst du dich nach dem Aufwachen?',
    phase: SleepQuestionPhase.morning,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'gar nicht erholt',
    highLabel: 'vollstaendig erholt',
  ),
  SleepQuestion(
    id: 'morning_awakenings',
    title: 'Naechtliches Aufwachen',
    prompt: 'Wie oft bist du nachts aufgewacht?',
    phase: SleepQuestionPhase.morning,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'gar nicht',
    highLabel: 'sehr haeufig',
  ),
  SleepQuestion(
    id: 'morning_temperature',
    title: 'Temperatur',
    prompt: 'Wie angenehm war die Temperatur im Schlafzimmer?',
    phase: SleepQuestionPhase.morning,
    type: SleepQuestionType.scale,
    isCustom: false,
    lowLabel: 'sehr unangenehm',
    highLabel: 'perfekt angenehm',
  ),
];

const defaultQuestionCsvColumns = {
  'evening_stress': 'evening_stress',
  'evening_last_meal': 'evening_last_meal',
  'evening_screen_time': 'evening_screen_time',
  'evening_sleep_regular': 'evening_sleep_regular',
  'evening_activity': 'evening_activity',
  'morning_sleep_onset_difficulty': 'morning_sleep_onset_difficulty',
  'morning_recovery': 'morning_recovery',
  'morning_awakenings': 'morning_awakenings',
  'morning_temperature': 'morning_temperature',
};

const sleepSessionCsvColumns = [
  'session_id',
  'started_at',
  'ended_at',
  'duration_min',
  'evening_stress',
  'evening_last_meal',
  'evening_screen_time',
  'evening_sleep_regular',
  'evening_activity',
  'morning_sleep_onset_difficulty',
  'morning_recovery',
  'morning_awakenings',
  'morning_temperature',
  'mean_heart_rate_bpm',
  'mean_breathing_rate_per_min',
  'mean_relative_angle_deg',
  'snore_time_fraction',
  'snore_time_percent',
  'sleep_quality_score',
  'custom_answers_json',
  'tips_json',
];

SleepJournalSummary summarizeSleepHistory(List<SleepSessionRecord> records) {
  if (records.isEmpty) return const SleepJournalSummary.empty();
  return SleepJournalSummary(
    sessionCount: records.length,
    averageScore: _mean(records.map((record) => record.score)),
    averageHeartRateBpm: _mean(
      records.map((record) => record.metrics.meanHeartRateBpm),
    ),
    averageBreathingRatePerMin: _mean(
      records.map((record) => record.metrics.meanBreathingRatePerMin),
    ),
    averageSnorePercent: _mean(
      records.map((record) => record.metrics.snoreTimeFraction == null
          ? null
          : record.metrics.snoreTimeFraction! * 100),
    ),
  );
}

double computeSleepScore(
  Map<String, int> _,
  SleepMeasurementSummary metrics,
) {
  return computeSleepMetricScores(
    meanHeartRateBpm: metrics.meanHeartRateBpm,
    meanBreathingRatePerMin: metrics.meanBreathingRatePerMin,
    snoreTimeFraction: metrics.snoreTimeFraction,
    meanEarTemperatureC: metrics.meanEarTemperatureC,
  ).overallScore;
}

class SleepMetricScores {
  const SleepMetricScores({
    required this.heartRateScore,
    required this.breathingRateScore,
    required this.snoreScore,
    required this.temperatureScore,
    required this.overallScore,
  });

  final double? heartRateScore;
  final double? breathingRateScore;
  final double? snoreScore;
  final double? temperatureScore;
  final double overallScore;
}

SleepMetricScores computeSleepMetricScores({
  required double? meanHeartRateBpm,
  required double? meanBreathingRatePerMin,
  required double? snoreTimeFraction,
  required double? meanEarTemperatureC,
}) {
  final heartScore =
      _lowerIsBetterScore(meanHeartRateBpm, best: 45, worst: 100);
  final breathingScore = _lowerIsBetterScore(
    meanBreathingRatePerMin,
    best: 8,
    worst: 30,
  );
  final snoreScore = _lowerIsBetterScore(
    snoreTimeFraction,
    best: 0,
    worst: 0.5,
  );
  final temperatureScore = _earTemperatureScore(meanEarTemperatureC);
  final weighted = <(double?, double)>[
    (heartScore, 0.35),
    (breathingScore, 0.35),
    (snoreScore, 0.30),
    (temperatureScore, 0.10),
  ];
  var sum = 0.0;
  var weight = 0.0;
  for (final entry in weighted) {
    final score = entry.$1;
    if (score == null) continue;
    sum += score * entry.$2;
    weight += entry.$2;
  }
  final overall = weight <= 0 ? 50.0 : sum / weight;
  return SleepMetricScores(
    heartRateScore: heartScore,
    breathingRateScore: breathingScore,
    snoreScore: snoreScore,
    temperatureScore: temperatureScore,
    overallScore: overall.clamp(1.0, 100.0).toDouble(),
  );
}

double? _lowerIsBetterScore(
  double? value, {
  required double best,
  required double worst,
}) {
  if (value == null || !value.isFinite || worst <= best) return null;
  final fraction = (1 - (value - best) / (worst - best)).clamp(0.0, 1.0);
  return (fraction * 100).clamp(1.0, 100.0).toDouble();
}

double? _earTemperatureScore(double? value) {
  if (value == null || !value.isFinite || value < 30 || value > 42) {
    return null;
  }
  const idealLow = 35.5;
  const idealHigh = 37.5;
  const plausibleLow = 34.0;
  const plausibleHigh = 38.5;
  double fraction;
  if (value >= idealLow && value <= idealHigh) {
    fraction = 1;
  } else if (value < idealLow) {
    fraction = (value - plausibleLow) / (idealLow - plausibleLow);
  } else {
    fraction = (plausibleHigh - value) / (plausibleHigh - idealHigh);
  }
  return (fraction.clamp(0.0, 1.0) * 100).clamp(1.0, 100.0).toDouble();
}

List<SleepQuestionPhysiologyCorrelation>
    computeSleepQuestionPhysiologyCorrelations(
  List<SleepSessionRecord> records,
  List<SleepQuestion> questions,
) {
  if (records.length < 4) return const [];
  final result = <SleepQuestionPhysiologyCorrelation>[];
  for (final question in questions) {
    final heartPairs = <_Pair>[];
    final breathingPairs = <_Pair>[];
    for (final record in records) {
      final answer = record.answers[question.id]?.toDouble();
      if (answer == null || !answer.isFinite) continue;
      final heartRate = record.metrics.meanHeartRateBpm;
      if (heartRate != null && heartRate.isFinite) {
        heartPairs.add(_Pair(answer, heartRate));
      }
      final breathingRate = record.metrics.meanBreathingRatePerMin;
      if (breathingRate != null && breathingRate.isFinite) {
        breathingPairs.add(_Pair(answer, breathingRate));
      }
    }
    final heartCorrelation =
        heartPairs.length < 4 ? null : _pearson(heartPairs);
    final breathingCorrelation =
        breathingPairs.length < 4 ? null : _pearson(breathingPairs);
    if (heartCorrelation == null && breathingCorrelation == null) continue;
    result.add(
      SleepQuestionPhysiologyCorrelation(
        questionId: question.id,
        label: question.title,
        prompt: question.prompt,
        lowLabel: question.lowLabel,
        highLabel: question.highLabel,
        heartRateCorrelation: heartCorrelation,
        heartRateSampleCount: heartPairs.length,
        breathingRateCorrelation: breathingCorrelation,
        breathingRateSampleCount: breathingPairs.length,
      ),
    );
  }
  result.sort(
    (a, b) => b.strongestAbsoluteCorrelation.compareTo(
      a.strongestAbsoluteCorrelation,
    ),
  );
  return result;
}

List<String> buildSleepTips(
  SleepSessionRecord? latest,
  List<SleepCorrelation> correlations,
) {
  if (latest == null) {
    return const [
      'Nach einigen Naechten erkennt LASLI persoenliche Muster und zeigt hier konkretere Tipps.',
    ];
  }

  final answers = latest.answers;
  final tips = <String>[];
  void add(String text) {
    if (!tips.contains(text)) tips.add(text);
  }

  if ((answers['evening_stress'] ?? 0) >= 4) {
    add('Plane vor dem Schlafen eine kurze, ruhige Routine ein, weil Stress hoch bewertet wurde.');
  }
  if ((answers['evening_screen_time'] ?? 0) >= 4) {
    add('Reduziere helle Bildschirmnutzung in den letzten zwei Stunden vor dem Schlafen.');
  }
  if ((answers['evening_last_meal'] ?? 5) <= 2) {
    add('Teste, ob eine fruehere letzte Mahlzeit deine Schlafqualitaet stabilisiert.');
  }
  if ((answers['evening_sleep_regular'] ?? 5) <= 2) {
    add('Halte Schlafenszeiten moeglichst konstant, besonders an aufeinanderfolgenden Tagen.');
  }
  if ((answers['morning_awakenings'] ?? 1) >= 4) {
    add('Viele Wachphasen: pruefe Licht, Geraeusche, Temperatur und abendliche Fluessigkeitsmenge.');
  }
  if ((answers['morning_recovery'] ?? 5) <= 2) {
    add('Bei geringer Erholung lohnt sich ein Blick auf Schlafdauer, Aufwachhaeufigkeit und Abendroutine.');
  }
  final snoreFraction = latest.metrics.snoreTimeFraction ?? 0;
  if (snoreFraction >= 0.20) {
    add('Der Schnarchanteil war erhoeht. Seitenlage und freie Nasenatmung koennen einen Test wert sein.');
  }
  final poseSnore = latest.metrics.poseSnore;
  final riskiestPoses = poseSnore.topRiskBins(limit: 1);
  final riskiestPose = riskiestPoses.isEmpty ? null : riskiestPoses.first;
  final baselineSnore = poseSnore.baselineSnoreProbability;
  if (riskiestPose != null &&
      riskiestPose.snoreProbability >= baselineSnore + 0.12) {
    add(
      'Schnarchen war bei ${riskiestPose.rangeLabel} pro Aufenthaltszeit am haeufigsten '
      '(${(riskiestPose.snoreProbability * 100).toStringAsFixed(1)} %).',
    );
  }

  for (final correlation in correlations.take(2)) {
    if (correlation.correlation >= 0.45) {
      add('${correlation.label}: Bei hoeheren Werten war dein Score bisher eher besser.');
    } else if (correlation.correlation <= -0.45) {
      add('${correlation.label}: Bei hoeheren Werten war dein Score bisher eher schlechter.');
    }
  }

  if (tips.isEmpty) {
    add('Die letzte Nacht war unauffaellig. Halte die Bedingungen moeglichst konstant und sammle weitere Daten.');
  }
  return tips.take(5).toList(growable: false);
}

List<SleepCorrelation> computeSleepCorrelations(
  List<SleepSessionRecord> records,
  List<SleepQuestion> questions,
) {
  if (records.length < 4) return const [];

  final features = <_Feature>[];
  for (final question in questions) {
    features.add(_Feature(
      label: question.title,
      valueFor: (record) => record.answers[question.id]?.toDouble(),
    ));
  }

  final correlations = <SleepCorrelation>[];
  for (final feature in features) {
    final pairs = <_Pair>[];
    for (final record in records) {
      final value = feature.valueFor(record);
      if (value != null && value.isFinite && record.score.isFinite) {
        pairs.add(_Pair(value, record.score));
      }
    }
    if (pairs.length < 4) continue;
    final r = _pearson(pairs);
    if (r == null || r.abs() < 0.20) continue;
    correlations.add(
      SleepCorrelation(
        label: feature.label,
        correlation: r,
        sampleCount: pairs.length,
      ),
    );
  }
  correlations
      .sort((a, b) => b.correlation.abs().compareTo(a.correlation.abs()));
  return correlations.take(8).toList(growable: false);
}

List<String> sleepSessionToCsvRow(
  SleepSessionRecord record,
  List<SleepQuestion> questions,
) {
  final customAnswers = <String, dynamic>{};
  for (final question in questions.where((question) => question.isCustom)) {
    final value = record.answers[question.id];
    if (value != null) {
      customAnswers[question.title] =
          question.type == SleepQuestionType.yesNo ? value == 1 : value;
    }
  }

  String answer(String id) => record.answers[id]?.toString() ?? '';
  String number(double? value, int digits) {
    return value == null || !value.isFinite
        ? ''
        : value.toStringAsFixed(digits);
  }

  return [
    record.id,
    record.metrics.startedAt.toIso8601String(),
    record.metrics.endedAt.toIso8601String(),
    number(record.metrics.durationSeconds / 60, 1),
    answer('evening_stress'),
    answer('evening_last_meal'),
    answer('evening_screen_time'),
    answer('evening_sleep_regular'),
    answer('evening_activity'),
    answer('morning_sleep_onset_difficulty'),
    answer('morning_recovery'),
    answer('morning_awakenings'),
    answer('morning_temperature'),
    number(record.metrics.meanHeartRateBpm, 1),
    number(record.metrics.meanBreathingRatePerMin, 1),
    number(record.metrics.meanRelativeAngleDeg, 1),
    number(record.metrics.snoreTimeFraction, 3),
    number(
      record.metrics.snoreTimeFraction == null
          ? null
          : record.metrics.snoreTimeFraction! * 100,
      1,
    ),
    number(record.score, 0),
    jsonEncode(customAnswers),
    jsonEncode(record.tips),
  ].map(csvEscape).toList(growable: false);
}

String csvEscape(String value) {
  if (!value.contains(',') &&
      !value.contains('"') &&
      !value.contains('\n') &&
      !value.contains('\r')) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

double? _mean(Iterable<double?> values) {
  var count = 0;
  var sum = 0.0;
  for (final value in values) {
    if (value != null && value.isFinite) {
      count++;
      sum += value;
    }
  }
  return count == 0 ? null : sum / count;
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _toInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _formatAngleLabel(double value) {
  final rounded = value.roundToDouble();
  if ((value - rounded).abs() < 0.001) {
    return rounded.toInt().toString();
  }
  return value.toStringAsFixed(1);
}

String _rangeLabel(double lower, double upper) {
  return '${_formatAngleLabel(lower)} bis ${_formatAngleLabel(upper)} deg';
}

int _poseBinIndex(double angleDeg) {
  final wrapped = _wrapAngleDeg(angleDeg);
  return ((wrapped - poseSnoreMinDeg) / poseSnoreBinSizeDeg)
      .floor()
      .clamp(0, _poseSnoreBinCount - 1)
      .toInt();
}

List<double> _poseAngleFeatureValues(List<double> angles) {
  return [
    angles[0],
    angles[1],
    angles[3],
    angles[4],
    _angleDeltaDeg(angles[0], angles[3]),
    _angleDeltaDeg(angles[1], angles[4]),
  ];
}

double _wrapAngleDeg(double value) {
  var wrapped = (value + 180) % 360;
  if (wrapped < 0) wrapped += 360;
  return wrapped - 180;
}

double _angleDeltaDeg(double a, double b) {
  return _wrapAngleDeg(a - b);
}

double? _pearson(List<_Pair> pairs) {
  final meanX =
      pairs.map((pair) => pair.x).reduce((a, b) => a + b) / pairs.length;
  final meanY =
      pairs.map((pair) => pair.y).reduce((a, b) => a + b) / pairs.length;
  var numerator = 0.0;
  var xSquares = 0.0;
  var ySquares = 0.0;
  for (final pair in pairs) {
    final dx = pair.x - meanX;
    final dy = pair.y - meanY;
    numerator += dx * dy;
    xSquares += dx * dx;
    ySquares += dy * dy;
  }
  final denominator = math.sqrt(xSquares * ySquares);
  if (denominator == 0) return null;
  return numerator / denominator;
}

class _Feature {
  const _Feature({required this.label, required this.valueFor});

  final String label;
  final double? Function(SleepSessionRecord record) valueFor;
}

class _Pair {
  const _Pair(this.x, this.y);

  final double x;
  final double y;
}
