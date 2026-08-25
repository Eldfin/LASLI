import 'dart:math' as math;

class SnoreTeacherSyncEstimate {
  const SnoreTeacherSyncEstimate({
    required this.ready,
    required this.method,
    required this.errorMs,
    required this.correlation,
    required this.correctionUs,
  });

  const SnoreTeacherSyncEstimate.waiting()
      : ready = false,
        method = 'wartet auf Audiodaten',
        errorMs = null,
        correlation = null,
        correctionUs = 0;

  final bool ready;
  final String method;
  final double? errorMs;
  final double? correlation;
  final int correctionUs;
}

class SnoreTeacherSynchronizer {
  static const int _energyFrameUs = 10000;
  static const int _maximumEnergyFrames = 3000;
  static const int _maximumAnchorSamples = 400;

  final List<double> _transportAnchorsUs = <double>[];
  final List<_BoardEnergy> _boardEnergy = <_BoardEnergy>[];
  final List<_TimedEnergy> _phoneEnergy = <_TimedEnergy>[];

  int? _framePeriodUs;
  double? _transportAnchorUs;
  SnoreTeacherSyncEstimate _estimate = const SnoreTeacherSyncEstimate.waiting();
  int _boardPacketCount = 0;

  SnoreTeacherSyncEstimate get estimate => _estimate;

  void reset() {
    _transportAnchorsUs.clear();
    _boardEnergy.clear();
    _phoneEnergy.clear();
    _framePeriodUs = null;
    _transportAnchorUs = null;
    _boardPacketCount = 0;
    _estimate = const SnoreTeacherSyncEstimate.waiting();
  }

  void addPhoneEnergy({
    required int centerMonotonicUs,
    required double rmsDb,
  }) {
    if (!rmsDb.isFinite) return;
    _phoneEnergy.add(_TimedEnergy(centerMonotonicUs, rmsDb));
    _trim(_phoneEnergy);
  }

  void addBoardPacket({
    required int firstFrameSequence,
    required int framePeriodUs,
    required int receivedMonotonicUs,
    required List<List<int>> slices,
  }) {
    if (slices.isEmpty || framePeriodUs <= 0) return;
    _boardPacketCount++;
    _framePeriodUs = framePeriodUs;
    final lastSequence = firstFrameSequence + slices.length - 1;
    _transportAnchorsUs.add(
      receivedMonotonicUs - lastSequence * framePeriodUs.toDouble(),
    );
    if (_transportAnchorsUs.length > _maximumAnchorSamples) {
      _transportAnchorsUs.removeAt(0);
    }
    _transportAnchorUs = _percentile(_transportAnchorsUs, 5);

    for (var slice = 0; slice < slices.length; slice++) {
      final values = slices[slice];
      if (values.isEmpty) continue;
      var energy = 0.0;
      final usefulBands = math.min(24, values.length);
      for (var band = 0; band < usefulBands; band++) {
        energy += values[band];
      }
      energy /= usefulBands;
      final sequence = firstFrameSequence + slice;
      _boardEnergy.add(_BoardEnergy(sequence, energy));
    }
    _trim(_boardEnergy);

    if (_boardEnergy.length >= 250 &&
        _phoneEnergy.length >= 250 &&
        _boardPacketCount % 40 == 0) {
      recompute();
    } else {
      _updateTransportOnlyEstimate();
    }
  }

  void recompute() {
    final anchor = _transportAnchorUs;
    final periodUs = _framePeriodUs;
    if (anchor == null || periodUs == null || _transportAnchorsUs.length < 3) {
      _estimate = const SnoreTeacherSyncEstimate.waiting();
      return;
    }

    final phoneByBucket = <int, List<double>>{};
    for (final frame in _phoneEnergy) {
      phoneByBucket
          .putIfAbsent(frame.timeUs ~/ _energyFrameUs, () => <double>[])
          .add(frame.energy);
    }
    final phoneMeanByBucket = <int, double>{
      for (final entry in phoneByBucket.entries)
        entry.key: entry.value.reduce((a, b) => a + b) / entry.value.length,
    };

    var bestCorrelation = -2.0;
    var bestCorrectionUs = 0;
    final candidates = <_CorrelationCandidate>[];
    for (var correctionUs = -1500000;
        correctionUs <= 1500000;
        correctionUs += _energyFrameUs) {
      final boardValues = <double>[];
      final phoneValues = <double>[];
      for (final board in _boardEnergy) {
        final boardTimeUs =
            (anchor + board.sequence * periodUs).round() + correctionUs;
        final bucket = boardTimeUs ~/ _energyFrameUs;
        final phone = phoneMeanByBucket[bucket];
        if (phone == null) continue;
        boardValues.add(board.energy);
        phoneValues.add(phone);
      }
      if (boardValues.length < 200) continue;
      final correlation = _pearson(boardValues, phoneValues);
      if (correlation == null) continue;
      candidates.add(_CorrelationCandidate(correctionUs, correlation));
      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestCorrectionUs = correctionUs;
      }
    }

    if (bestCorrelation >= 0.32) {
      final nearBest = candidates
          .where((candidate) => candidate.correlation >= bestCorrelation - 0.03)
          .map((candidate) => candidate.correctionUs)
          .toList(growable: false);
      final spreadUs = nearBest.isEmpty
          ? _energyFrameUs
          : nearBest.reduce(math.max) - nearBest.reduce(math.min);
      final errorMs = math.max(10.0, math.min(250.0, spreadUs / 2000.0 + 10.0));
      _estimate = SnoreTeacherSyncEstimate(
        ready: true,
        method: 'Audioabgleich',
        errorMs: errorMs,
        correlation: bestCorrelation,
        correctionUs: bestCorrectionUs,
      );
      return;
    }

    _updateTransportOnlyEstimate();
  }

  int? frameMonotonicUs(int frameSequence) {
    final anchor = _transportAnchorUs;
    final periodUs = _framePeriodUs;
    if (anchor == null || periodUs == null) return null;
    return (anchor + frameSequence * periodUs + _estimate.correctionUs).round();
  }

  void _updateTransportOnlyEstimate() {
    if (_transportAnchorUs == null || _transportAnchorsUs.length < 3) {
      _estimate = const SnoreTeacherSyncEstimate.waiting();
      return;
    }
    final low = _percentile(_transportAnchorsUs, 5);
    final high = _percentile(_transportAnchorsUs, 90);
    _estimate = SnoreTeacherSyncEstimate(
      ready: true,
      method: 'BLE-Zeitbasis',
      errorMs: math.max(40.0, math.min(500.0, (high - low) / 1000.0 + 40.0)),
      correlation: null,
      correctionUs: 0,
    );
  }

  static void _trim<T>(List<T> values) {
    if (values.length > _maximumEnergyFrames) {
      values.removeRange(0, values.length - _maximumEnergyFrames);
    }
  }

  static double _percentile(List<double> values, double percentile) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.of(values)..sort();
    final position =
        (percentile.clamp(0.0, 100.0) / 100.0) * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    return sorted[lower] * (upper - position) +
        sorted[upper] * (position - lower);
  }

  static double? _pearson(List<double> a, List<double> b) {
    if (a.length != b.length || a.length < 2) return null;
    var meanA = 0.0;
    var meanB = 0.0;
    for (var i = 0; i < a.length; i++) {
      meanA += a[i];
      meanB += b[i];
    }
    meanA /= a.length;
    meanB /= b.length;
    var covariance = 0.0;
    var varianceA = 0.0;
    var varianceB = 0.0;
    for (var i = 0; i < a.length; i++) {
      final da = a[i] - meanA;
      final db = b[i] - meanB;
      covariance += da * db;
      varianceA += da * da;
      varianceB += db * db;
    }
    if (varianceA < 1e-6 || varianceB < 1e-6) return null;
    return covariance / math.sqrt(varianceA * varianceB);
  }
}

class _TimedEnergy {
  const _TimedEnergy(this.timeUs, this.energy);

  final int timeUs;
  final double energy;
}

class _BoardEnergy {
  const _BoardEnergy(this.sequence, this.energy);

  final int sequence;
  final double energy;
}

class _CorrelationCandidate {
  const _CorrelationCandidate(this.correctionUs, this.correlation);

  final int correctionUs;
  final double correlation;
}
