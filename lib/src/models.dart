import 'package:bitalino/bitalino.dart';

enum DeviceMode {
  demo,
  bth,
  ble,
}

extension DeviceModeLabel on DeviceMode {
  String get label {
    switch (this) {
      case DeviceMode.demo:
        return 'Demo';
      case DeviceMode.bth:
        return 'BTH';
      case DeviceMode.ble:
        return 'BLE';
    }
  }

  CommunicationType? get communicationType {
    switch (this) {
      case DeviceMode.bth:
        return CommunicationType.BTH;
      case DeviceMode.ble:
        return CommunicationType.BLE;
      case DeviceMode.demo:
        return null;
    }
  }
}

class PlotPoint {
  const PlotPoint(this.x, this.y);

  final double x;
  final double y;
}

class TimeWindow {
  const TimeWindow(this.startS, this.endS);

  final double startS;
  final double endS;
}

class SnoreWindowAssessment {
  const SnoreWindowAssessment({
    required this.window,
    required this.source,
    required this.sourceConfidence,
    required this.overlapRatio,
    this.inhaleWindow,
  });

  final TimeWindow window;
  final String source;
  final double sourceConfidence;
  final double overlapRatio;
  final TimeWindow? inhaleWindow;
}

class SignalSample {
  const SignalSample({
    required this.timeS,
    required this.ecg,
    required this.resp,
    required this.a3,
    required this.a4,
    this.preview = false,
  });

  final double timeS;
  final double ecg;
  final double resp;
  final double a3;
  final double a4;
  final bool preview;
}

class OrientationState {
  const OrientationState({
    required this.foreheadAngleDeg,
    required this.chestAngleDeg,
    required this.relativeAngleDeg,
    this.relativeYawDeg,
    this.relativeYawQualityPercent,
    this.relativeYawUncertaintyDeg,
  });

  const OrientationState.empty()
      : foreheadAngleDeg = 0,
        chestAngleDeg = 0,
        relativeAngleDeg = 0,
        relativeYawDeg = null,
        relativeYawQualityPercent = null,
        relativeYawUncertaintyDeg = null;

  final double foreheadAngleDeg;
  final double chestAngleDeg;
  final double relativeAngleDeg;
  final double? relativeYawDeg;
  final double? relativeYawQualityPercent;
  final double? relativeYawUncertaintyDeg;
}

enum Mg24SensorRole {
  forehead,
  belly,
}

extension Mg24SensorRoleLabel on Mg24SensorRole {
  String get label {
    switch (this) {
      case Mg24SensorRole.forehead:
        return 'Stirn';
      case Mg24SensorRole.belly:
        return 'Bauch';
    }
  }
}

class Mg24SensorSummary {
  const Mg24SensorSummary({
    required this.connected,
    required this.connecting,
    required this.name,
    required this.remoteId,
    required this.lastUpdate,
    required this.angleDeg,
    required this.rollDeg,
    required this.pitchDeg,
    required this.yawDeg,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.poseCalibrationEpoch,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.ppgIr,
    required this.ppgRed,
    required this.ppgQuality,
    required this.perfusionIndex,
    required this.heartRateRawBpm,
    required this.spo2RawPercent,
    required this.ppgRawWaveform,
    required this.ppgWaveform,
    required this.ppgPeaks,
    required this.batteryPercent,
    required this.batteryVoltage,
    required this.earTemperatureC,
    required this.rssi,
    required this.blePacketLossPercent,
    required this.plotPacketLossPercent,
    required this.plotSampleLossPercent,
    required this.sensorsEnabled,
    required this.recording,
    required this.recordingArmed,
    required this.recordingStartFailed,
    required this.sessionId,
    required this.archiveRecords,
    required this.archiveCapacity,
  });

  const Mg24SensorSummary.empty()
      : connected = false,
        connecting = false,
        name = null,
        remoteId = null,
        lastUpdate = null,
        angleDeg = null,
        rollDeg = null,
        pitchDeg = null,
        yawDeg = null,
        qw = null,
        qx = null,
        qy = null,
        qz = null,
        poseCalibrationEpoch = 0,
        ax = null,
        ay = null,
        az = null,
        gx = null,
        gy = null,
        gz = null,
        ppgIr = null,
        ppgRed = null,
        ppgQuality = null,
        perfusionIndex = null,
        heartRateRawBpm = null,
        spo2RawPercent = null,
        ppgRawWaveform = const [],
        ppgWaveform = const [],
        ppgPeaks = const [],
        batteryPercent = null,
        batteryVoltage = null,
        earTemperatureC = null,
        rssi = null,
        blePacketLossPercent = null,
        plotPacketLossPercent = null,
        plotSampleLossPercent = null,
        sensorsEnabled = null,
        recording = null,
        recordingArmed = null,
        recordingStartFailed = null,
        sessionId = null,
        archiveRecords = null,
        archiveCapacity = null;

  final bool connected;
  final bool connecting;
  final String? name;
  final String? remoteId;
  final DateTime? lastUpdate;
  final double? angleDeg;
  final double? rollDeg;
  final double? pitchDeg;
  final double? yawDeg;
  final double? qw;
  final double? qx;
  final double? qy;
  final double? qz;
  final int poseCalibrationEpoch;
  final double? ax;
  final double? ay;
  final double? az;
  final double? gx;
  final double? gy;
  final double? gz;
  final double? ppgIr;
  final double? ppgRed;
  final double? ppgQuality;
  final double? perfusionIndex;
  final double? heartRateRawBpm;
  final double? spo2RawPercent;
  final List<double> ppgRawWaveform;
  final List<double> ppgWaveform;
  final List<bool> ppgPeaks;
  final double? batteryPercent;
  final double? batteryVoltage;
  final double? earTemperatureC;
  final int? rssi;
  final double? blePacketLossPercent;
  final double? plotPacketLossPercent;
  final double? plotSampleLossPercent;
  final bool? sensorsEnabled;
  final bool? recording;
  final bool? recordingArmed;
  final bool? recordingStartFailed;
  final int? sessionId;
  final int? archiveRecords;
  final int? archiveCapacity;

  bool get hasData => connected && lastUpdate != null;

  Mg24SensorSummary copyWith({
    bool? connected,
    bool? connecting,
    String? name,
    bool clearName = false,
    String? remoteId,
    bool clearRemoteId = false,
    DateTime? lastUpdate,
    bool clearLastUpdate = false,
    double? angleDeg,
    bool clearAngleDeg = false,
    double? rollDeg,
    bool clearRollDeg = false,
    double? pitchDeg,
    bool clearPitchDeg = false,
    double? yawDeg,
    bool clearYawDeg = false,
    double? qw,
    bool clearQw = false,
    double? qx,
    bool clearQx = false,
    double? qy,
    bool clearQy = false,
    double? qz,
    bool clearQz = false,
    int? poseCalibrationEpoch,
    double? ax,
    bool clearAx = false,
    double? ay,
    bool clearAy = false,
    double? az,
    bool clearAz = false,
    double? gx,
    bool clearGx = false,
    double? gy,
    bool clearGy = false,
    double? gz,
    bool clearGz = false,
    double? ppgIr,
    bool clearPpgIr = false,
    double? ppgRed,
    bool clearPpgRed = false,
    double? ppgQuality,
    bool clearPpgQuality = false,
    double? perfusionIndex,
    bool clearPerfusionIndex = false,
    double? heartRateRawBpm,
    bool clearHeartRateRawBpm = false,
    double? spo2RawPercent,
    bool clearSpo2RawPercent = false,
    List<double>? ppgRawWaveform,
    List<double>? ppgWaveform,
    List<bool>? ppgPeaks,
    double? batteryPercent,
    bool clearBatteryPercent = false,
    double? batteryVoltage,
    bool clearBatteryVoltage = false,
    double? earTemperatureC,
    bool clearEarTemperatureC = false,
    int? rssi,
    bool clearRssi = false,
    double? blePacketLossPercent,
    bool clearBlePacketLossPercent = false,
    double? plotPacketLossPercent,
    bool clearPlotPacketLossPercent = false,
    double? plotSampleLossPercent,
    bool clearPlotSampleLossPercent = false,
    bool? sensorsEnabled,
    bool clearSensorsEnabled = false,
    bool? recording,
    bool clearRecording = false,
    bool? recordingArmed,
    bool clearRecordingArmed = false,
    bool? recordingStartFailed,
    bool clearRecordingStartFailed = false,
    int? sessionId,
    bool clearSessionId = false,
    int? archiveRecords,
    bool clearArchiveRecords = false,
    int? archiveCapacity,
    bool clearArchiveCapacity = false,
  }) {
    return Mg24SensorSummary(
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      name: clearName ? null : name ?? this.name,
      remoteId: clearRemoteId ? null : remoteId ?? this.remoteId,
      lastUpdate: clearLastUpdate ? null : lastUpdate ?? this.lastUpdate,
      angleDeg: clearAngleDeg ? null : angleDeg ?? this.angleDeg,
      rollDeg: clearRollDeg ? null : rollDeg ?? this.rollDeg,
      pitchDeg: clearPitchDeg ? null : pitchDeg ?? this.pitchDeg,
      yawDeg: clearYawDeg ? null : yawDeg ?? this.yawDeg,
      qw: clearQw ? null : qw ?? this.qw,
      qx: clearQx ? null : qx ?? this.qx,
      qy: clearQy ? null : qy ?? this.qy,
      qz: clearQz ? null : qz ?? this.qz,
      poseCalibrationEpoch: poseCalibrationEpoch ?? this.poseCalibrationEpoch,
      ax: clearAx ? null : ax ?? this.ax,
      ay: clearAy ? null : ay ?? this.ay,
      az: clearAz ? null : az ?? this.az,
      gx: clearGx ? null : gx ?? this.gx,
      gy: clearGy ? null : gy ?? this.gy,
      gz: clearGz ? null : gz ?? this.gz,
      ppgIr: clearPpgIr ? null : ppgIr ?? this.ppgIr,
      ppgRed: clearPpgRed ? null : ppgRed ?? this.ppgRed,
      ppgQuality: clearPpgQuality ? null : ppgQuality ?? this.ppgQuality,
      perfusionIndex:
          clearPerfusionIndex ? null : perfusionIndex ?? this.perfusionIndex,
      heartRateRawBpm:
          clearHeartRateRawBpm ? null : heartRateRawBpm ?? this.heartRateRawBpm,
      spo2RawPercent:
          clearSpo2RawPercent ? null : spo2RawPercent ?? this.spo2RawPercent,
      ppgRawWaveform: ppgRawWaveform ?? this.ppgRawWaveform,
      ppgWaveform: ppgWaveform ?? this.ppgWaveform,
      ppgPeaks: ppgPeaks ?? this.ppgPeaks,
      batteryPercent:
          clearBatteryPercent ? null : batteryPercent ?? this.batteryPercent,
      batteryVoltage:
          clearBatteryVoltage ? null : batteryVoltage ?? this.batteryVoltage,
      earTemperatureC:
          clearEarTemperatureC ? null : earTemperatureC ?? this.earTemperatureC,
      rssi: clearRssi ? null : rssi ?? this.rssi,
      blePacketLossPercent: clearBlePacketLossPercent
          ? null
          : blePacketLossPercent ?? this.blePacketLossPercent,
      plotPacketLossPercent: clearPlotPacketLossPercent
          ? null
          : plotPacketLossPercent ?? this.plotPacketLossPercent,
      plotSampleLossPercent: clearPlotSampleLossPercent
          ? null
          : plotSampleLossPercent ?? this.plotSampleLossPercent,
      sensorsEnabled:
          clearSensorsEnabled ? null : sensorsEnabled ?? this.sensorsEnabled,
      recording: clearRecording ? null : recording ?? this.recording,
      recordingArmed:
          clearRecordingArmed ? null : recordingArmed ?? this.recordingArmed,
      recordingStartFailed: clearRecordingStartFailed
          ? null
          : recordingStartFailed ?? this.recordingStartFailed,
      sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
      archiveRecords:
          clearArchiveRecords ? null : archiveRecords ?? this.archiveRecords,
      archiveCapacity:
          clearArchiveCapacity ? null : archiveCapacity ?? this.archiveCapacity,
    );
  }
}

class Mg24State {
  const Mg24State({
    required this.scanning,
    required this.status,
    required this.forehead,
    required this.belly,
    required this.heartRateBpm,
    required this.spo2Percent,
    required this.breathingRatePerMin,
    required this.breathingSignal,
    required this.breathingAxis,
    required this.breathingQuality,
    required this.max30102Connected,
    required this.max30102Bus,
  });

  const Mg24State.empty()
      : scanning = false,
        status = 'Nicht verbunden',
        forehead = const Mg24SensorSummary.empty(),
        belly = const Mg24SensorSummary.empty(),
        heartRateBpm = null,
        spo2Percent = null,
        breathingRatePerMin = null,
        breathingSignal = null,
        breathingAxis = null,
        breathingQuality = null,
        max30102Connected = null,
        max30102Bus = null;

  final bool scanning;
  final String status;
  final Mg24SensorSummary forehead;
  final Mg24SensorSummary belly;
  final double? heartRateBpm;
  final double? spo2Percent;
  final double? breathingRatePerMin;
  final double? breathingSignal;
  final String? breathingAxis;
  final double? breathingQuality;
  final bool? max30102Connected;
  final int? max30102Bus;

  bool get connected => forehead.connected || belly.connected;

  bool get hasAnyData => forehead.hasData || belly.hasData;

  bool get hasPair => forehead.connected && belly.connected;

  bool get hasDataPair => forehead.hasData && belly.hasData;

  bool get ready => hasDataPair;

  Mg24State copyWith({
    bool? scanning,
    String? status,
    Mg24SensorSummary? forehead,
    Mg24SensorSummary? belly,
    double? heartRateBpm,
    bool clearHeartRateBpm = false,
    double? spo2Percent,
    bool clearSpo2Percent = false,
    double? breathingRatePerMin,
    bool clearBreathingRatePerMin = false,
    double? breathingSignal,
    bool clearBreathingSignal = false,
    String? breathingAxis,
    bool clearBreathingAxis = false,
    double? breathingQuality,
    bool clearBreathingQuality = false,
    bool? max30102Connected,
    bool clearMax30102Connected = false,
    int? max30102Bus,
    bool clearMax30102Bus = false,
  }) {
    return Mg24State(
      scanning: scanning ?? this.scanning,
      status: status ?? this.status,
      forehead: forehead ?? this.forehead,
      belly: belly ?? this.belly,
      heartRateBpm:
          clearHeartRateBpm ? null : heartRateBpm ?? this.heartRateBpm,
      spo2Percent: clearSpo2Percent ? null : spo2Percent ?? this.spo2Percent,
      breathingRatePerMin: clearBreathingRatePerMin
          ? null
          : breathingRatePerMin ?? this.breathingRatePerMin,
      breathingSignal:
          clearBreathingSignal ? null : breathingSignal ?? this.breathingSignal,
      breathingAxis:
          clearBreathingAxis ? null : breathingAxis ?? this.breathingAxis,
      breathingQuality: clearBreathingQuality
          ? null
          : breathingQuality ?? this.breathingQuality,
      max30102Connected: clearMax30102Connected
          ? null
          : max30102Connected ?? this.max30102Connected,
      max30102Bus: clearMax30102Bus ? null : max30102Bus ?? this.max30102Bus,
    );
  }
}

class SnoreState {
  const SnoreState({
    required this.isSnoring,
    required this.detectedNow,
    required this.score,
    required this.rmsDb,
    required this.snoreCount,
    required this.backend,
    this.inferenceId = 0,
    this.windowCenterAt,
    this.source = 'unknown',
    this.sourceConfidence = 0,
    this.patternQuality,
    this.snoreRatePerMin,
    this.snoreBreathWidthMs,
    this.snoreBurstActive = false,
    this.snoreActiveWidthMs,
  });

  const SnoreState.empty()
      : isSnoring = false,
        detectedNow = false,
        score = 0,
        rmsDb = -120,
        snoreCount = 0,
        backend = 'none',
        inferenceId = 0,
        windowCenterAt = null,
        source = 'unknown',
        sourceConfidence = 0,
        patternQuality = null,
        snoreRatePerMin = null,
        snoreBreathWidthMs = null,
        snoreBurstActive = false,
        snoreActiveWidthMs = null;

  final bool isSnoring;
  final bool detectedNow;
  final double score;
  final double rmsDb;
  final int snoreCount;
  final String backend;
  final int inferenceId;
  final DateTime? windowCenterAt;
  final String source;
  final double sourceConfidence;
  final double? patternQuality;
  final double? snoreRatePerMin;
  final double? snoreBreathWidthMs;
  final bool snoreBurstActive;
  final double? snoreActiveWidthMs;

  SnoreState copyWith({
    bool? isSnoring,
    bool? detectedNow,
    double? score,
    double? rmsDb,
    int? snoreCount,
    String? backend,
    int? inferenceId,
    DateTime? windowCenterAt,
    bool clearWindowCenterAt = false,
    String? source,
    double? sourceConfidence,
    double? patternQuality,
    bool clearPatternQuality = false,
    double? snoreRatePerMin,
    bool clearSnoreRatePerMin = false,
    double? snoreBreathWidthMs,
    bool clearSnoreBreathWidthMs = false,
    bool? snoreBurstActive,
    double? snoreActiveWidthMs,
    bool clearSnoreActiveWidthMs = false,
  }) {
    return SnoreState(
      isSnoring: isSnoring ?? this.isSnoring,
      detectedNow: detectedNow ?? this.detectedNow,
      score: score ?? this.score,
      rmsDb: rmsDb ?? this.rmsDb,
      snoreCount: snoreCount ?? this.snoreCount,
      backend: backend ?? this.backend,
      inferenceId: inferenceId ?? this.inferenceId,
      windowCenterAt:
          clearWindowCenterAt ? null : windowCenterAt ?? this.windowCenterAt,
      source: source ?? this.source,
      sourceConfidence: sourceConfidence ?? this.sourceConfidence,
      patternQuality:
          clearPatternQuality ? null : patternQuality ?? this.patternQuality,
      snoreRatePerMin:
          clearSnoreRatePerMin ? null : snoreRatePerMin ?? this.snoreRatePerMin,
      snoreBreathWidthMs: clearSnoreBreathWidthMs
          ? null
          : snoreBreathWidthMs ?? this.snoreBreathWidthMs,
      snoreBurstActive: snoreBurstActive ?? this.snoreBurstActive,
      snoreActiveWidthMs: clearSnoreActiveWidthMs
          ? null
          : snoreActiveWidthMs ?? this.snoreActiveWidthMs,
    );
  }
}

class SnoreTimelineSegment {
  const SnoreTimelineSegment({
    required this.startedAt,
    required this.endedAt,
    this.source = 'unknown',
    this.sourceConfidence = 0,
  });

  final DateTime startedAt;
  final DateTime? endedAt;
  final String source;
  final double sourceConfidence;

  bool get active => endedAt == null;

  Duration duration(DateTime referenceTime) {
    final end = endedAt ?? referenceTime;
    final value = end.difference(startedAt);
    return value.isNegative ? Duration.zero : value;
  }
}

class RadarMetric {
  const RadarMetric({
    required this.label,
    required this.value,
    this.unit = '',
  });

  final String label;
  final String value;
  final String unit;
}

class RadarState {
  const RadarState({
    required this.connected,
    required this.connecting,
    required this.status,
    required this.host,
    required this.deviceName,
    required this.lastUpdate,
    required this.personDetected,
    required this.targetCount,
    required this.distanceCm,
    required this.heartRateBpm,
    required this.breathingRatePerMin,
    required this.illuminanceLux,
    required this.metrics,
  });

  const RadarState.empty()
      : connected = false,
        connecting = false,
        status = 'Nicht verbunden',
        host = null,
        deviceName = null,
        lastUpdate = null,
        personDetected = null,
        targetCount = null,
        distanceCm = null,
        heartRateBpm = null,
        breathingRatePerMin = null,
        illuminanceLux = null,
        metrics = const [];

  final bool connected;
  final bool connecting;
  final String status;
  final String? host;
  final String? deviceName;
  final DateTime? lastUpdate;
  final bool? personDetected;
  final double? targetCount;
  final double? distanceCm;
  final double? heartRateBpm;
  final double? breathingRatePerMin;
  final double? illuminanceLux;
  final List<RadarMetric> metrics;

  RadarState copyWith({
    bool? connected,
    bool? connecting,
    String? status,
    String? host,
    bool clearHost = false,
    String? deviceName,
    bool clearDeviceName = false,
    DateTime? lastUpdate,
    bool clearLastUpdate = false,
    bool? personDetected,
    bool clearPersonDetected = false,
    double? targetCount,
    bool clearTargetCount = false,
    double? distanceCm,
    bool clearDistanceCm = false,
    double? heartRateBpm,
    bool clearHeartRateBpm = false,
    double? breathingRatePerMin,
    bool clearBreathingRatePerMin = false,
    double? illuminanceLux,
    bool clearIlluminanceLux = false,
    List<RadarMetric>? metrics,
  }) {
    return RadarState(
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      status: status ?? this.status,
      host: clearHost ? null : host ?? this.host,
      deviceName: clearDeviceName ? null : deviceName ?? this.deviceName,
      lastUpdate: clearLastUpdate ? null : lastUpdate ?? this.lastUpdate,
      personDetected:
          clearPersonDetected ? null : personDetected ?? this.personDetected,
      targetCount: clearTargetCount ? null : targetCount ?? this.targetCount,
      distanceCm: clearDistanceCm ? null : distanceCm ?? this.distanceCm,
      heartRateBpm:
          clearHeartRateBpm ? null : heartRateBpm ?? this.heartRateBpm,
      breathingRatePerMin: clearBreathingRatePerMin
          ? null
          : breathingRatePerMin ?? this.breathingRatePerMin,
      illuminanceLux:
          clearIlluminanceLux ? null : illuminanceLux ?? this.illuminanceLux,
      metrics: metrics ?? this.metrics,
    );
  }
}

class MeasurementSnapshot {
  const MeasurementSnapshot({
    required this.running,
    required this.status,
    required this.fileLabel,
    required this.csvPath,
    required this.csvDirectoryPath,
    required this.measurementStartedAt,
    required this.heartRate,
    required this.breathingRate,
    required this.oxygenSaturation,
    required this.radar,
    required this.mg24,
    required this.orientation,
    required this.snore,
    required this.snoreTimeline,
    required this.snoreBreathWindows,
    required this.inhaleBreathWindows,
    required this.recentSnoreBreathWindows,
    required this.recentSnoreAssessments,
    required this.breathingPlotLatencySeconds,
    required this.samples,
    required this.rPeaks,
    required this.breathPeaks,
    required this.rPeakCount,
    required this.breathCount,
  });

  factory MeasurementSnapshot.initial() {
    return const MeasurementSnapshot(
      running: false,
      status: 'Bereit',
      fileLabel: 'Noch keine Messung',
      csvPath: null,
      csvDirectoryPath: null,
      measurementStartedAt: null,
      heartRate: null,
      breathingRate: null,
      oxygenSaturation: null,
      radar: RadarState.empty(),
      mg24: Mg24State.empty(),
      orientation: OrientationState.empty(),
      snore: SnoreState.empty(),
      snoreTimeline: [],
      snoreBreathWindows: [],
      inhaleBreathWindows: [],
      recentSnoreBreathWindows: [],
      recentSnoreAssessments: [],
      breathingPlotLatencySeconds: null,
      samples: [],
      rPeaks: [],
      breathPeaks: [],
      rPeakCount: 0,
      breathCount: 0,
    );
  }

  final bool running;
  final String status;
  final String fileLabel;
  final String? csvPath;
  final String? csvDirectoryPath;
  final DateTime? measurementStartedAt;
  final double? heartRate;
  final double? breathingRate;
  final double? oxygenSaturation;
  final RadarState radar;
  final Mg24State mg24;
  final OrientationState orientation;
  final SnoreState snore;
  final List<SnoreTimelineSegment> snoreTimeline;
  final List<TimeWindow> snoreBreathWindows;
  final List<TimeWindow> inhaleBreathWindows;
  final List<TimeWindow> recentSnoreBreathWindows;
  final List<SnoreWindowAssessment> recentSnoreAssessments;
  final double? breathingPlotLatencySeconds;
  final List<SignalSample> samples;
  final List<PlotPoint> rPeaks;
  final List<PlotPoint> breathPeaks;
  final int rPeakCount;
  final int breathCount;

  MeasurementSnapshot copyWith({
    bool? running,
    String? status,
    String? fileLabel,
    String? csvPath,
    bool clearCsvPath = false,
    String? csvDirectoryPath,
    bool clearCsvDirectoryPath = false,
    DateTime? measurementStartedAt,
    bool clearMeasurementStartedAt = false,
    double? heartRate,
    bool clearHeartRate = false,
    double? breathingRate,
    bool clearBreathingRate = false,
    double? oxygenSaturation,
    bool clearOxygenSaturation = false,
    RadarState? radar,
    Mg24State? mg24,
    OrientationState? orientation,
    SnoreState? snore,
    List<SnoreTimelineSegment>? snoreTimeline,
    List<TimeWindow>? snoreBreathWindows,
    List<TimeWindow>? inhaleBreathWindows,
    List<TimeWindow>? recentSnoreBreathWindows,
    List<SnoreWindowAssessment>? recentSnoreAssessments,
    double? breathingPlotLatencySeconds,
    bool clearBreathingPlotLatencySeconds = false,
    List<SignalSample>? samples,
    List<PlotPoint>? rPeaks,
    List<PlotPoint>? breathPeaks,
    int? rPeakCount,
    int? breathCount,
  }) {
    return MeasurementSnapshot(
      running: running ?? this.running,
      status: status ?? this.status,
      fileLabel: fileLabel ?? this.fileLabel,
      csvPath: clearCsvPath ? null : csvPath ?? this.csvPath,
      csvDirectoryPath: clearCsvDirectoryPath
          ? null
          : csvDirectoryPath ?? this.csvDirectoryPath,
      measurementStartedAt: clearMeasurementStartedAt
          ? null
          : measurementStartedAt ?? this.measurementStartedAt,
      heartRate: clearHeartRate ? null : heartRate ?? this.heartRate,
      breathingRate:
          clearBreathingRate ? null : breathingRate ?? this.breathingRate,
      oxygenSaturation: clearOxygenSaturation
          ? null
          : oxygenSaturation ?? this.oxygenSaturation,
      radar: radar ?? this.radar,
      mg24: mg24 ?? this.mg24,
      orientation: orientation ?? this.orientation,
      snore: snore ?? this.snore,
      snoreTimeline: snoreTimeline ?? this.snoreTimeline,
      snoreBreathWindows: snoreBreathWindows ?? this.snoreBreathWindows,
      inhaleBreathWindows: inhaleBreathWindows ?? this.inhaleBreathWindows,
      recentSnoreBreathWindows:
          recentSnoreBreathWindows ?? this.recentSnoreBreathWindows,
      recentSnoreAssessments:
          recentSnoreAssessments ?? this.recentSnoreAssessments,
      breathingPlotLatencySeconds: clearBreathingPlotLatencySeconds
          ? null
          : breathingPlotLatencySeconds ?? this.breathingPlotLatencySeconds,
      samples: samples ?? this.samples,
      rPeaks: rPeaks ?? this.rPeaks,
      breathPeaks: breathPeaks ?? this.breathPeaks,
      rPeakCount: rPeakCount ?? this.rPeakCount,
      breathCount: breathCount ?? this.breathCount,
    );
  }
}
