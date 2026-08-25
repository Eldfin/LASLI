import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

const mg24ProtocolVersion = 1;
const mg24ProtocolMagic = 0x4c;
const mg24SummaryPacketType = 1;
const mg24WaveformPacketType = 2;
const mg24ArchivePacketType = 3;
const mg24ArchiveStatusPacketType = 4;
const mg24EventArchivePacketType = 5;
const mg24EventArchiveStatusPacketType = 6;
const mg24MelFeaturePacketType = 7;

enum Mg24LiveMode { valuesOnly, valuesAndPlots }

extension Mg24LiveModeCommand on Mg24LiveMode {
  String get command => switch (this) {
        Mg24LiveMode.valuesOnly => 'MODE:VALUES',
        Mg24LiveMode.valuesAndPlots => 'MODE:PLOTS',
      };
}

class Mg24EdgeSummary {
  const Mg24EdgeSummary({
    required this.role,
    required this.sequence,
    required this.uptimeMs,
    required this.sensorsEnabled,
    required this.recording,
    required this.recordingArmed,
    required this.recordingStartFailed,
    required this.heartRateBpm,
    required this.spo2Percent,
    required this.respirationRatePerMin,
    required this.temperatureC,
    required this.rollDeg,
    required this.pitchDeg,
    required this.yawDeg,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.ppgQuality,
    required this.respirationQuality,
    required this.snoreScore,
    required this.snoreVolumePercent,
    required this.snoring,
    required this.snoreAvailable,
    required this.batteryPercent,
    required this.liveMode,
    required this.sessionId,
    required this.archiveRecords,
    required this.archiveCapacity,
    required this.max30102Connected,
    required this.snoreLevelRatioPercent,
    required this.snoreLowRatioPercent,
    required this.snoreCrossingRatePercent,
    required this.snoreRawSwing,
    required this.snorePatternQualityPercent,
    required this.snoreRatePerMin,
    required this.snoreBreathWidthMs,
    required this.snoreBurstAgeMs,
    required this.snoreBurstCounter,
    required this.snoreBurstActive,
    required this.snoreActiveWidthMs,
    required this.snoreEnvelopeLift,
    required this.snoreCrestFactor,
    required this.snoreModulationPercent,
    required this.snoreBlockScorePercent,
    required this.snoreContinuationScorePercent,
    required this.snoreAudioContactArtifact,
    required this.snoreMotionArtifact,
  });

  static const packetLength = 70;
  static const liveWindowPacketLength = 64;
  static const snoreTimingPacketLength = 62;
  static const snorePatternPacketLength = 60;
  static const debugPacketLength = 54;
  static const legacyPacketLength = 50;

  final Mg24SensorRole role;
  final int sequence;
  final int uptimeMs;
  final bool sensorsEnabled;
  final bool recording;
  final bool recordingArmed;
  final bool recordingStartFailed;
  final double? heartRateBpm;
  final double? spo2Percent;
  final double? respirationRatePerMin;
  final double? temperatureC;
  final double? rollDeg;
  final double? pitchDeg;
  final double? yawDeg;
  final double? qw;
  final double? qx;
  final double? qy;
  final double? qz;
  final double ppgQuality;
  final double respirationQuality;
  final double snoreScore;
  final double snoreVolumePercent;
  final bool snoring;
  final bool snoreAvailable;
  final double batteryPercent;
  final Mg24LiveMode liveMode;
  final int sessionId;
  final int archiveRecords;
  final int archiveCapacity;
  final bool max30102Connected;
  final double? snoreLevelRatioPercent;
  final double? snoreLowRatioPercent;
  final double? snoreCrossingRatePercent;
  final double? snoreRawSwing;
  final double? snorePatternQualityPercent;
  final double? snoreRatePerMin;
  final double? snoreBreathWidthMs;
  final int? snoreBurstAgeMs;
  final int? snoreBurstCounter;
  final bool? snoreBurstActive;
  final double? snoreActiveWidthMs;
  final double? snoreEnvelopeLift;
  final double? snoreCrestFactor;
  final double? snoreModulationPercent;
  final double? snoreBlockScorePercent;
  final double? snoreContinuationScorePercent;
  final bool? snoreAudioContactArtifact;
  final bool? snoreMotionArtifact;

  static Mg24EdgeSummary? parse(List<int> bytes) {
    if (bytes.length != packetLength &&
        bytes.length != liveWindowPacketLength &&
        bytes.length != snoreTimingPacketLength &&
        bytes.length != snorePatternPacketLength &&
        bytes.length != debugPacketLength &&
        bytes.length != legacyPacketLength) {
      return null;
    }
    if (!_validPacket(bytes, bytes.length, mg24SummaryPacketType)) return null;
    final data = _byteData(bytes);
    final flags = data.getUint16(12, Endian.little);
    final hasSnoreDebug = bytes.length >= debugPacketLength;
    final hasSnorePattern = bytes.length >= snorePatternPacketLength;
    final hasSnoreTiming = bytes.length >= snoreTimingPacketLength;
    final hasSnoreLiveWindow = bytes.length >= liveWindowPacketLength;
    final hasExtendedAudio = bytes.length >= packetLength;
    double? validX10(int flag, int offset) =>
        flags & flag == 0 ? null : data.getUint16(offset, Endian.little) / 10.0;
    double? validCenti(int flag, int offset) =>
        flags & flag == 0 ? null : data.getInt16(offset, Endian.little) / 100.0;
    double? quaternion(int offset) => flags & 0x40 == 0
        ? null
        : data.getInt16(offset, Endian.little) / 32767.0;

    return Mg24EdgeSummary(
      role: _roleFromCode(data.getUint8(3)),
      sequence: data.getUint32(4, Endian.little),
      uptimeMs: data.getUint32(8, Endian.little),
      sensorsEnabled: flags & 0x01 != 0,
      recording: flags & 0x02 != 0,
      recordingArmed: flags & 0x0400 != 0,
      recordingStartFailed: flags & 0x0800 != 0,
      heartRateBpm: validX10(0x04, 14),
      spo2Percent: validX10(0x08, 16),
      respirationRatePerMin: validX10(0x10, 18),
      temperatureC: validCenti(0x20, 20),
      rollDeg: validCenti(0x40, 22),
      pitchDeg: validCenti(0x40, 24),
      yawDeg: validCenti(0x40, 26),
      qw: quaternion(28),
      qx: quaternion(30),
      qy: quaternion(32),
      qz: quaternion(34),
      ppgQuality: data.getUint8(36).toDouble(),
      respirationQuality: data.getUint8(37).toDouble(),
      snoreScore: data.getUint8(38).toDouble(),
      batteryPercent: data.getUint8(39).toDouble(),
      liveMode: data.getUint8(40) == 1
          ? Mg24LiveMode.valuesAndPlots
          : Mg24LiveMode.valuesOnly,
      snoreVolumePercent: data.getUint8(41).toDouble(),
      sessionId: data.getUint16(42, Endian.little),
      archiveRecords: data.getUint16(44, Endian.little),
      archiveCapacity: data.getUint16(46, Endian.little),
      snoreLevelRatioPercent:
          hasSnoreDebug ? data.getUint8(48).toDouble() : null,
      snoreLowRatioPercent: hasSnoreDebug ? data.getUint8(49).toDouble() : null,
      snoreCrossingRatePercent:
          hasSnoreDebug ? data.getUint8(50).toDouble() : null,
      snoreRawSwing: hasSnoreDebug ? data.getUint8(51).toDouble() : null,
      snorePatternQualityPercent:
          hasSnorePattern ? data.getUint8(52).toDouble() : null,
      snoreRatePerMin:
          hasSnorePattern ? data.getUint16(53, Endian.little) / 10.0 : null,
      snoreBreathWidthMs:
          hasSnorePattern ? data.getUint16(55, Endian.little).toDouble() : null,
      snoreBurstAgeMs:
          hasSnoreTiming ? data.getUint16(57, Endian.little) : null,
      snoreBurstCounter: hasSnoreTiming
          ? data.getUint8(59)
          : hasSnorePattern
              ? data.getUint8(57)
              : null,
      snoreBurstActive:
          hasSnoreLiveWindow ? (data.getUint8(60) & 0x01) != 0 : null,
      snoreActiveWidthMs:
          hasSnoreLiveWindow ? data.getUint8(61).toDouble() * 80.0 : null,
      snoreEnvelopeLift: hasExtendedAudio ? data.getUint8(62) / 100.0 : null,
      snoreCrestFactor: hasExtendedAudio ? data.getUint8(63) / 10.0 : null,
      snoreModulationPercent:
          hasExtendedAudio ? data.getUint8(64).toDouble() : null,
      snoreBlockScorePercent:
          hasExtendedAudio ? data.getUint8(65).toDouble() : null,
      snoreContinuationScorePercent:
          hasExtendedAudio ? data.getUint8(66).toDouble() : null,
      snoreAudioContactArtifact:
          hasExtendedAudio ? data.getUint8(67) & 0x01 != 0 : null,
      snoreMotionArtifact:
          hasExtendedAudio ? data.getUint8(67) & 0x02 != 0 : null,
      snoreAvailable: flags & 0x80 != 0,
      snoring: flags & 0x100 != 0,
      max30102Connected: flags & 0x200 != 0,
    );
  }
}

class Mg24WaveformPacket {
  const Mg24WaveformPacket({
    required this.role,
    required this.stream,
    required this.packetSequence,
    required this.firstSampleSequence,
    required this.samplePeriodUs,
    required this.trailingSampleCount,
    required this.firstSampleSensorTimeS,
    required this.samples,
    required this.peaks,
    required this.receivedAt,
  });

  static const packetLength = 40;
  static const ppgStream = 1;
  static const respirationStream = 2;
  static const audioFeatureStream = 3;
  static const respirationPeakStream = 4;
  static const respirationPreviewStream = 5;

  final Mg24SensorRole role;
  final int stream;
  final int packetSequence;
  final int firstSampleSequence;
  final int samplePeriodUs;
  final int trailingSampleCount;
  final double? firstSampleSensorTimeS;
  final List<double> samples;
  final List<bool> peaks;
  final DateTime receivedAt;

  static Mg24WaveformPacket? parse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (!_validPacket(bytes, packetLength, mg24WaveformPacketType)) return null;
    final data = _byteData(bytes);
    final count = data.getUint8(5).clamp(0, 5).toInt();
    final peakMask = data.getUint8(6);
    final metadataTimeS =
        count < 5 ? data.getFloat32(18 + 4 * 4, Endian.little) : double.nan;
    return Mg24WaveformPacket(
      role: _roleFromCode(data.getUint8(3)),
      stream: data.getUint8(4),
      packetSequence: data.getUint32(8, Endian.little),
      firstSampleSequence: data.getUint32(12, Endian.little),
      samplePeriodUs: data.getUint16(16, Endian.little),
      trailingSampleCount: data.getUint8(7),
      firstSampleSensorTimeS:
          metadataTimeS.isFinite && metadataTimeS > 0 ? metadataTimeS : null,
      samples: List<double>.generate(
        count,
        (index) => data.getFloat32(18 + index * 4, Endian.little),
        growable: false,
      ),
      peaks: List<bool>.generate(
        count,
        (index) => peakMask & (1 << index) != 0,
        growable: false,
      ),
      receivedAt: receivedAt ?? DateTime.now(),
    );
  }
}

class Mg24MelFeaturePacket {
  const Mg24MelFeaturePacket({
    required this.role,
    required this.packetSequence,
    required this.firstFrameSequence,
    required this.framePeriodUs,
    required this.modelScorePercent,
    required this.modelAvailable,
    required this.modelActive,
    required this.boardDomainTrusted,
    required this.modelFrameSequence,
    required this.slices,
    required this.receivedAt,
  });

  static const packetLength = 182;
  static const bandsPerSlice = 32;
  static const maximumSlices = 5;

  final Mg24SensorRole role;
  final int packetSequence;
  final int firstFrameSequence;
  final int framePeriodUs;
  final int modelScorePercent;
  final bool modelAvailable;
  final bool modelActive;
  final bool boardDomainTrusted;
  final int modelFrameSequence;
  final List<List<int>> slices;
  final DateTime receivedAt;

  static Mg24MelFeaturePacket? parse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (!_validPacket(bytes, packetLength, mg24MelFeaturePacketType)) {
      return null;
    }
    final data = _byteData(bytes);
    final count = data.getUint8(14);
    final bands = data.getUint8(15);
    if (count < 1 || count > maximumSlices || bands != bandsPerSlice) {
      return null;
    }
    final modelFlags = data.getUint8(17);
    return Mg24MelFeaturePacket(
      role: _roleFromCode(data.getUint8(3)),
      packetSequence: data.getUint32(4, Endian.little),
      firstFrameSequence: data.getUint32(8, Endian.little),
      framePeriodUs: data.getUint16(12, Endian.little),
      modelScorePercent: data.getUint8(16),
      modelAvailable: modelFlags & 0x01 != 0,
      modelActive: modelFlags & 0x02 != 0,
      boardDomainTrusted: modelFlags & 0x04 != 0,
      modelFrameSequence: (data.getUint32(8, Endian.little) +
              data.getInt16(18, Endian.little)) &
          0xffffffff,
      slices: List<List<int>>.generate(
        count,
        (slice) => List<int>.generate(
          bandsPerSlice,
          (band) => data.getInt8(20 + slice * bandsPerSlice + band),
          growable: false,
        ),
        growable: false,
      ),
      receivedAt: receivedAt ?? DateTime.now(),
    );
  }
}

class Mg24MinuteRecord {
  const Mg24MinuteRecord({
    required this.sessionId,
    required this.minuteIndex,
    required this.partial,
    required this.heartRateBpm,
    required this.spo2Percent,
    required this.respirationRatePerMin,
    required this.snoreSeconds,
    required this.snoreVolumePercent,
    required this.temperatureC,
    required this.rollDeg,
    required this.pitchDeg,
    required this.yawDeg,
    required this.ppgQuality,
    required this.respirationQuality,
    required this.batteryPercent,
  });

  static const wireLength = 22;

  final int sessionId;
  final int minuteIndex;
  final bool partial;
  final double? heartRateBpm;
  final double? spo2Percent;
  final double? respirationRatePerMin;
  final int? snoreSeconds;
  final double? snoreVolumePercent;
  final double? temperatureC;
  final double? rollDeg;
  final double? pitchDeg;
  final double? yawDeg;
  final double ppgQuality;
  final double respirationQuality;
  final double batteryPercent;

  static Mg24MinuteRecord? parse(ByteData data, int offset) {
    if (offset < 0 || offset + wireLength > data.lengthInBytes) return null;
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes + offset,
      wireLength,
    );
    final expected = data.getUint16(offset + 20, Endian.little);
    if (mg24Crc16(bytes, 0, 20) != expected) return null;
    final flags = data.getUint16(offset + 4, Endian.little);
    final packedQuality = data.getUint8(offset + 18);
    final hasSnoreVolume = flags & 0x80 != 0;
    return Mg24MinuteRecord(
      sessionId: data.getUint16(offset, Endian.little),
      minuteIndex: data.getUint16(offset + 2, Endian.little),
      partial: flags & 0x40 != 0,
      heartRateBpm:
          flags & 0x01 == 0 ? null : data.getUint8(offset + 6).toDouble(),
      spo2Percent:
          flags & 0x02 == 0 ? null : data.getUint8(offset + 7).toDouble(),
      respirationRatePerMin:
          flags & 0x04 == 0 ? null : data.getUint8(offset + 8) / 2.0,
      snoreSeconds: flags & 0x20 == 0 ? null : data.getUint8(offset + 9),
      snoreVolumePercent:
          hasSnoreVolume ? math.min(100.0, (packedQuality & 0x0f) * 7.0) : null,
      temperatureC: flags & 0x08 == 0
          ? null
          : data.getInt16(offset + 10, Endian.little) / 100.0,
      rollDeg: flags & 0x10 == 0
          ? null
          : data.getInt16(offset + 12, Endian.little) / 100.0,
      pitchDeg: flags & 0x10 == 0
          ? null
          : data.getInt16(offset + 14, Endian.little) / 100.0,
      yawDeg: flags & 0x10 == 0
          ? null
          : data.getInt16(offset + 16, Endian.little) / 100.0,
      ppgQuality: ((packedQuality >> 4) & 0x0f) * 7.0,
      respirationQuality: hasSnoreVolume ? 0.0 : (packedQuality & 0x0f) * 7.0,
      batteryPercent: data.getUint8(offset + 19).toDouble(),
    );
  }
}

class Mg24ArchiveStatus {
  const Mg24ArchiveStatus({
    required this.role,
    required this.sessionId,
    required this.unixStartMinute,
    required this.recordCount,
    required this.capacity,
    required this.recording,
  });

  final Mg24SensorRole role;
  final int sessionId;
  final int unixStartMinute;
  final int recordCount;
  final int capacity;
  final bool recording;

  static Mg24ArchiveStatus? parse(List<int> bytes) {
    const length = 26;
    if (!_validPacket(bytes, length, mg24ArchiveStatusPacketType)) return null;
    final data = _byteData(bytes);
    return Mg24ArchiveStatus(
      role: _roleFromCode(data.getUint8(3)),
      sessionId: data.getUint16(10, Endian.little),
      unixStartMinute: data.getUint32(12, Endian.little),
      recordCount: data.getUint16(16, Endian.little),
      recording: data.getUint8(18) != 0,
      capacity: data.getUint16(22, Endian.little),
    );
  }
}

class Mg24ArchivePacket {
  const Mg24ArchivePacket({
    required this.role,
    required this.sessionId,
    required this.firstRecord,
    required this.records,
  });

  static const legacyPacketLength = 122;
  static const packetLength = 232;

  final Mg24SensorRole role;
  final int sessionId;
  final int firstRecord;
  final List<Mg24MinuteRecord> records;

  static Mg24ArchivePacket? parse(List<int> bytes) {
    if (bytes.length != legacyPacketLength && bytes.length != packetLength) {
      return null;
    }
    if (!_validPacket(bytes, bytes.length, mg24ArchivePacketType)) return null;
    final data = _byteData(bytes);
    final capacity = (bytes.length - 12) ~/ Mg24MinuteRecord.wireLength;
    final count = data.getUint8(8).clamp(0, capacity).toInt();
    final records = <Mg24MinuteRecord>[];
    for (var index = 0; index < count; index++) {
      final record = Mg24MinuteRecord.parse(
        data,
        10 + index * Mg24MinuteRecord.wireLength,
      );
      if (record == null) return null;
      records.add(record);
    }
    return Mg24ArchivePacket(
      role: _roleFromCode(data.getUint8(3)),
      sessionId: data.getUint16(4, Endian.little),
      firstRecord: data.getUint16(6, Endian.little),
      records: List.unmodifiable(records),
    );
  }
}

class Mg24DownloadedArchive {
  const Mg24DownloadedArchive({
    required this.status,
    required this.records,
  });

  final Mg24ArchiveStatus status;
  final List<Mg24MinuteRecord> records;
}

enum Mg24EventKind {
  unknown,
  snoreWindow,
  breathCycle,
}

Mg24EventKind _eventKindFromCode(int code) => switch (code) {
      1 => Mg24EventKind.snoreWindow,
      2 => Mg24EventKind.breathCycle,
      _ => Mg24EventKind.unknown,
    };

class Mg24EventArchiveStatus {
  const Mg24EventArchiveStatus({
    required this.role,
    required this.kind,
    required this.sessionId,
    required this.unixStartMinute,
    required this.recordCount,
    required this.capacity,
    required this.recording,
  });

  final Mg24SensorRole role;
  final Mg24EventKind kind;
  final int sessionId;
  final int unixStartMinute;
  final int recordCount;
  final int capacity;
  final bool recording;

  static Mg24EventArchiveStatus? parse(List<int> bytes) {
    const length = 28;
    if (!_validPacket(bytes, length, mg24EventArchiveStatusPacketType)) {
      return null;
    }
    final data = _byteData(bytes);
    return Mg24EventArchiveStatus(
      role: _roleFromCode(data.getUint8(3)),
      kind: _eventKindFromCode(data.getUint8(10)),
      sessionId: data.getUint16(12, Endian.little),
      unixStartMinute: data.getUint32(14, Endian.little),
      recordCount: data.getUint16(18, Endian.little),
      recording: data.getUint8(20) != 0,
      capacity: data.getUint16(24, Endian.little),
    );
  }
}

class Mg24EventRecord {
  const Mg24EventRecord({
    required this.startTick,
    required this.durationTicks,
    required this.qualityPercent,
  });

  static const wireLength = 6;
  static const tickSeconds = 0.080;

  final int startTick;
  final int durationTicks;
  final double qualityPercent;

  double get startSeconds => startTick * tickSeconds;
  double get durationSeconds => durationTicks * tickSeconds;
  double get endSeconds => startSeconds + durationSeconds;

  static Mg24EventRecord? parse(ByteData data, int offset) {
    if (offset < 0 || offset + wireLength > data.lengthInBytes) return null;
    return Mg24EventRecord(
      startTick: data.getUint32(offset, Endian.little),
      durationTicks: data.getUint8(offset + 4),
      qualityPercent: data.getUint8(offset + 5).toDouble(),
    );
  }
}

class Mg24EventArchivePacket {
  const Mg24EventArchivePacket({
    required this.role,
    required this.kind,
    required this.sessionId,
    required this.firstRecord,
    required this.records,
  });

  static const legacyPacketLength = 120;
  static const packetLength = 234;

  final Mg24SensorRole role;
  final Mg24EventKind kind;
  final int sessionId;
  final int firstRecord;
  final List<Mg24EventRecord> records;

  static Mg24EventArchivePacket? parse(List<int> bytes) {
    if (bytes.length != legacyPacketLength && bytes.length != packetLength) {
      return null;
    }
    if (!_validPacket(bytes, bytes.length, mg24EventArchivePacketType)) {
      return null;
    }
    final data = _byteData(bytes);
    final capacity = (bytes.length - 12) ~/ Mg24EventRecord.wireLength;
    final count = data.getUint8(8).clamp(0, capacity).toInt();
    final records = <Mg24EventRecord>[];
    for (var index = 0; index < count; index++) {
      final record = Mg24EventRecord.parse(
        data,
        10 + index * Mg24EventRecord.wireLength,
      );
      if (record == null) return null;
      records.add(record);
    }
    return Mg24EventArchivePacket(
      role: _roleFromCode(data.getUint8(3)),
      sessionId: data.getUint16(4, Endian.little),
      firstRecord: data.getUint16(6, Endian.little),
      kind: _eventKindFromCode(data.getUint8(9)),
      records: List.unmodifiable(records),
    );
  }
}

class Mg24DownloadedEventArchive {
  const Mg24DownloadedEventArchive({
    required this.status,
    required this.records,
  });

  final Mg24EventArchiveStatus status;
  final List<Mg24EventRecord> records;
}

class Mg24SampleLossEstimator {
  int? _nextExpected;
  int _received = 0;
  int _missing = 0;

  double? add({required int firstSequence, required int count}) {
    if (count <= 0) return percent;
    final expected = _nextExpected;
    if (expected != null) {
      final gap = (firstSequence - expected) & 0xffffffff;
      if (gap > 0 && gap < 0x80000000) _missing += gap;
    }
    _received += count;
    _nextExpected = (firstSequence + count) & 0xffffffff;
    return percent;
  }

  double? get percent {
    final total = _received + _missing;
    return total == 0 ? null : 100.0 * _missing / total;
  }

  void reset() {
    _nextExpected = null;
    _received = 0;
    _missing = 0;
  }
}

int mg24Crc16(List<int> bytes, [int offset = 0, int? length]) {
  var crc = 0xffff;
  final end = offset + (length ?? bytes.length - offset);
  for (var index = offset; index < end; index++) {
    crc ^= (bytes[index] & 0xff) << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 != 0 ? ((crc << 1) ^ 0x1021) : crc << 1;
      crc &= 0xffff;
    }
  }
  return crc;
}

bool _validPacket(List<int> bytes, int length, int type) {
  if (bytes.length != length ||
      bytes[0] != mg24ProtocolMagic ||
      bytes[1] != mg24ProtocolVersion ||
      bytes[2] != type) {
    return false;
  }
  final data = _byteData(bytes);
  final expected = data.getUint16(length - 2, Endian.little);
  return mg24Crc16(bytes, 0, length - 2) == expected;
}

ByteData _byteData(List<int> bytes) {
  final values = Uint8List.fromList(bytes);
  return ByteData.sublistView(values);
}

Mg24SensorRole _roleFromCode(int role) =>
    role == 1 ? Mg24SensorRole.belly : Mg24SensorRole.forehead;
