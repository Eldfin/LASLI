import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'models.dart';
import 'mg24_protocol.dart';
import 'processing.dart';

final Guid mg24ServiceUuid = Guid('7a534c49-2f4d-4732-9d53-4d4732340001');
final Guid mg24DataCharacteristicUuid =
    Guid('7a534c49-2f4d-4732-9d53-4d4732340002');
final Guid mg24ControlCharacteristicUuid =
    Guid('7a534c49-2f4d-4732-9d53-4d4732340003');
final Guid mg24SummaryCharacteristicUuid =
    Guid('7a534c49-2f4d-4732-9d53-4d4732340004');
final Guid mg24WaveformCharacteristicUuid =
    Guid('7a534c49-2f4d-4732-9d53-4d4732340005');
final Guid mg24ArchiveCharacteristicUuid =
    Guid('7a534c49-2f4d-4732-9d53-4d4732340006');

const mg24ForeheadName = 'LASLI-FOREHEAD';
const mg24BellyName = 'LASLI-BELLY';
const _ppgMaximumSamples = 110;
const _mg24ConnectAttempts = 1;
const _mg24FirstSampleTimeout = Duration(seconds: 15);
const _mg24InterSensorConnectDelay = Duration(milliseconds: 2500);
const _mg24PreferredNotificationMtu = 247;

typedef Mg24ArchiveTransferProgress = void Function(
  Mg24SensorRole role,
  int downloadedRecords,
  int totalRecords,
);

typedef Mg24EventArchiveChunk = Future<void> Function(
  Mg24SensorRole role,
  int firstRecord,
  List<Mg24EventRecord> records,
);

class Mg24RecordingStartException implements Exception {
  Mg24RecordingStartException({
    required this.startedRoles,
    required this.failedRole,
    required this.cause,
  });

  final Set<Mg24SensorRole> startedRoles;
  final Mg24SensorRole failedRole;
  final Object cause;

  @override
  String toString() => '${failedRole.label}: Messstart fehlgeschlagen ($cause)';
}

class Mg24SensorSample {
  const Mg24SensorSample({
    required this.role,
    required this.receivedAt,
    this.sensorTimeS,
    this.packetSequence,
    this.ax,
    this.ay,
    this.az,
    this.gx,
    this.gy,
    this.gz,
    this.rollDeg,
    this.pitchDeg,
    this.yawDeg,
    this.angleDeg,
    this.qw,
    this.qx,
    this.qy,
    this.qz,
    this.ppgIr,
    this.ppgRed,
    this.ppgQuality,
    this.perfusionIndex,
    this.heartRateRawBpm,
    this.spo2RawPercent,
    this.ppgPeak,
    this.heartRateBpm,
    this.spo2Percent,
    this.batteryPercent,
    this.batteryVoltage,
    this.max30102Connected,
    this.max30102Bus,
    this.earTemperatureC,
    this.breathingRatePerMin,
    this.breathingQuality,
    this.snoring,
    this.snoreScore,
    this.snoreRmsDb,
    this.snoreLevelRatioPercent,
    this.snoreLowRatioPercent,
    this.snoreCrossingRatePercent,
    this.snoreRawSwing,
    this.snorePatternQualityPercent,
    this.snoreRatePerMin,
    this.snoreBreathWidthMs,
    this.snoreBurstAgeMs,
    this.snoreBurstCounter,
    this.snoreBurstActive,
    this.snoreActiveWidthMs,
    this.snoreAudioBand0To150Percent,
    this.snoreAudioBand150To300Percent,
    this.snoreAudioBand300To600Percent,
    this.snoreAudioBand600To1200Percent,
    this.snoreAudioBand1200To3000Percent,
    this.snoreEnvelopeLift,
    this.snoreCrestFactor,
    this.snoreModulationPercent,
    this.snoreBlockScorePercent,
    this.snoreContinuationScorePercent,
    this.snoreAudioContactArtifact,
    this.snoreMotionArtifact,
    this.edgeProcessed = false,
  });

  final Mg24SensorRole role;
  final DateTime receivedAt;
  final double? sensorTimeS;
  final int? packetSequence;
  final double? ax;
  final double? ay;
  final double? az;
  final double? gx;
  final double? gy;
  final double? gz;
  final double? rollDeg;
  final double? pitchDeg;
  final double? yawDeg;
  final double? angleDeg;
  final double? qw;
  final double? qx;
  final double? qy;
  final double? qz;
  final double? ppgIr;
  final double? ppgRed;
  final double? ppgQuality;
  final double? perfusionIndex;
  final double? heartRateRawBpm;
  final double? spo2RawPercent;
  final bool? ppgPeak;
  final double? heartRateBpm;
  final double? spo2Percent;
  final double? batteryPercent;
  final double? batteryVoltage;
  final bool? max30102Connected;
  final int? max30102Bus;
  final double? earTemperatureC;
  final double? breathingRatePerMin;
  final double? breathingQuality;
  final bool? snoring;
  final double? snoreScore;
  final double? snoreRmsDb;
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
  final double? snoreAudioBand0To150Percent;
  final double? snoreAudioBand150To300Percent;
  final double? snoreAudioBand300To600Percent;
  final double? snoreAudioBand600To1200Percent;
  final double? snoreAudioBand1200To3000Percent;
  final double? snoreEnvelopeLift;
  final double? snoreCrestFactor;
  final double? snoreModulationPercent;
  final double? snoreBlockScorePercent;
  final double? snoreContinuationScorePercent;
  final bool? snoreAudioContactArtifact;
  final bool? snoreMotionArtifact;
  final bool edgeProcessed;

  double? get resolvedAngleDeg =>
      angleDeg ?? pitchDeg ?? rollDeg ?? _angleFromAcceleration();

  static Mg24SensorSample? parse(
    List<int> bytes, {
    required Mg24SensorRole fallbackRole,
  }) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    final payload = text.split('\n').last.trim();
    if (payload.isEmpty) return null;

    if (payload.startsWith('{')) {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return null;
      return _fromJson(decoded, fallbackRole);
    }
    return _fromDelimited(payload, fallbackRole);
  }

  static Mg24SensorSample _fromJson(
    Map<String, dynamic> json,
    Mg24SensorRole fallbackRole,
  ) {
    final role = parseMg24Role(json['role'] ?? json['r']) ?? fallbackRole;
    final acc = _numList(json['acc'] ?? json['a']);
    final gyro = _numList(json['gyro'] ?? json['g']);
    final quat = _numList(json['quat'] ?? json['q']);
    final timeS = _readDouble(json, const ['time_s', 'ts']);
    final timeMs = _readDouble(json, const ['t', 'time_ms', 'ms']);
    return Mg24SensorSample(
      role: role,
      receivedAt: DateTime.now(),
      sensorTimeS: timeS ?? (timeMs == null ? null : timeMs / 1000.0),
      packetSequence: _readInt(json, const ['seq', 'sequence', 'packet_seq']),
      ax: _readDouble(json, const ['ax']) ?? _listAt(acc, 0),
      ay: _readDouble(json, const ['ay']) ?? _listAt(acc, 1),
      az: _readDouble(json, const ['az']) ?? _listAt(acc, 2),
      gx: _readDouble(json, const ['gx']) ?? _listAt(gyro, 0),
      gy: _readDouble(json, const ['gy']) ?? _listAt(gyro, 1),
      gz: _readDouble(json, const ['gz']) ?? _listAt(gyro, 2),
      rollDeg: _readDouble(json, const ['roll', 'roll_deg', 'ro']),
      pitchDeg: _readDouble(json, const ['pitch', 'pitch_deg', 'pi']),
      yawDeg: _readDouble(json, const ['yaw', 'yaw_deg', 'y']),
      angleDeg: _readDouble(json, const ['angle', 'angle_deg', 'tilt', 'ang']),
      qw: _readDouble(json, const ['qw', 'q0']) ?? _listAt(quat, 0),
      qx: _readDouble(json, const ['qx', 'q1']) ?? _listAt(quat, 1),
      qy: _readDouble(json, const ['qy', 'q2']) ?? _listAt(quat, 2),
      qz: _readDouble(json, const ['qz', 'q3']) ?? _listAt(quat, 3),
      ppgIr: _positive(_readDouble(json, const ['ir', 'ppg_ir'])),
      ppgRed: _positive(_readDouble(json, const ['rd', 'red', 'ppg_red'])),
      ppgQuality: _clampedPercent(_readDouble(
        json,
        const ['oq', 'oxq', 'ppg_quality', 'quality'],
      )),
      perfusionIndex: _positive(_readDouble(
        json,
        const ['pf', 'perfusion', 'perfusion_index'],
      )),
      heartRateRawBpm: _positive(_readDouble(
        json,
        const ['hrx', 'heart_rate_raw', 'raw_hr'],
      )),
      spo2RawPercent: _percent(_readDouble(
        json,
        const ['sx', 'spo2_raw', 'raw_spo2'],
      )),
      ppgPeak: _readBool(json, const ['pk', 'peak', 'ppg_peak']),
      heartRateBpm: _positive(_readDouble(
        json,
        const ['hr', 'heart', 'heart_rate', 'heart_rate_bpm', 'bpm'],
      )),
      spo2Percent: _percent(_readDouble(
        json,
        const ['spo2', 'spo2_percent', 'oxygen', 'oxygen_saturation'],
      )),
      batteryPercent: _percent(_readDouble(
        json,
        const ['bat', 'battery', 'battery_percent'],
      )),
      batteryVoltage: _positive(_readDouble(
        json,
        const ['bv', 'vbat', 'battery_voltage', 'battery_voltage_v'],
      )),
      max30102Connected: _readBool(json, const ['max', 'max30102']),
      max30102Bus: _readInt(json, const ['mb', 'max_bus', 'max30102_bus']),
      earTemperatureC: _readDouble(json, const [
        'et',
        'ear_temp',
        'ear_temp_c',
        'ear_temperature_c',
        'temperature_c',
      ]),
    );
  }

  static Mg24SensorSample? _fromDelimited(
    String payload,
    Mg24SensorRole fallbackRole,
  ) {
    final parts = payload
        .split(RegExp(r'[,;\s]+'))
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.length < 10) return null;

    var index = 0;
    final parsedRole = parseMg24Role(parts.first);
    final role = parsedRole ?? fallbackRole;
    if (parsedRole != null) index = 1;

    double? valueAt(int offset) {
      final target = index + offset;
      if (target < 0 || target >= parts.length) return null;
      return double.tryParse(parts[target].replaceAll(',', '.'));
    }

    final timeMs = valueAt(0);
    final extended = parts.length - index >= 24;
    return Mg24SensorSample(
      role: role,
      receivedAt: DateTime.now(),
      sensorTimeS: timeMs == null ? null : timeMs / 1000.0,
      packetSequence: extended ? valueAt(29)?.round() : null,
      ax: valueAt(1),
      ay: valueAt(2),
      az: valueAt(3),
      gx: valueAt(4),
      gy: valueAt(5),
      gz: valueAt(6),
      rollDeg: valueAt(7),
      pitchDeg: valueAt(8),
      yawDeg: extended ? valueAt(9) : null,
      angleDeg: extended ? valueAt(10) : valueAt(9),
      heartRateBpm: _positive(extended ? valueAt(11) : valueAt(10)),
      heartRateRawBpm: _positive(extended ? valueAt(12) : null),
      spo2Percent: _percent(extended ? valueAt(13) : valueAt(11)),
      spo2RawPercent: _percent(extended ? valueAt(14) : null),
      batteryPercent: _percent(extended ? valueAt(15) : valueAt(12)),
      batteryVoltage: _positive(extended ? valueAt(16) : valueAt(13)),
      ppgIr: _positive(extended ? valueAt(17) : null),
      ppgRed: _positive(extended ? valueAt(18) : null),
      ppgQuality: _percent(extended ? valueAt(19) : null),
      perfusionIndex: _positive(extended ? valueAt(20) : null),
      ppgPeak: _readDelimitedBool(extended ? valueAt(21) : null),
      max30102Connected: _readDelimitedBool(extended ? valueAt(22) : null),
      max30102Bus: extended ? valueAt(23)?.round() : null,
      earTemperatureC: extended ? valueAt(24) : null,
      qw: extended ? valueAt(25) : null,
      qx: extended ? valueAt(26) : null,
      qy: extended ? valueAt(27) : null,
      qz: extended ? valueAt(28) : null,
    );
  }

  double? _angleFromAcceleration() {
    final x = ax;
    final y = ay;
    final z = az;
    if (x == null || y == null || z == null) return null;
    if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
    return math.atan2(x, math.sqrt(y * y + z * z)) * 180 / math.pi;
  }
}

class Mg24SensorClient {
  Mg24SensorClient({
    required this.onState,
    required this.onSample,
    this.onWaveform,
    this.onMelFeatures,
    this.onConnectionLost,
  });

  final void Function(Mg24State state) onState;
  final void Function(Mg24SensorSample sample) onSample;
  final void Function(Mg24WaveformPacket packet)? onWaveform;
  final void Function(Mg24MelFeaturePacket packet)? onMelFeatures;
  final VoidCallback? onConnectionLost;

  Mg24State _state = const Mg24State.empty();
  _Mg24Connection? _foreheadConnection;
  _Mg24Connection? _bellyConnection;
  final _foreheadPacketLoss = BlePacketLossEstimator(minimumExpectedPackets: 5);
  final _bellyPacketLoss = BlePacketLossEstimator(minimumExpectedPackets: 5);
  final _foreheadWaveformPacketLoss = BlePacketLossEstimator();
  final _bellyWaveformPacketLoss = BlePacketLossEstimator();
  final _foreheadSampleLoss = Mg24SampleLossEstimator();
  final _bellySampleLoss = Mg24SampleLossEstimator();
  final Map<Mg24SensorRole, List<double>> _latestAudioFeatureBands = {};
  final Map<Mg24SensorRole, DateTime> _latestAudioFeatureBandAt = {};
  Mg24LiveMode _liveMode = Mg24LiveMode.valuesOnly;
  bool _stopping = false;
  int _connectOperation = 0;
  Completer<void>? _connectCancellation;
  final Map<Mg24SensorRole, BluetoothDevice> _pendingConnectDevices = {};
  int _nextConnectionGeneration = 0;
  final Map<Mg24SensorRole, int> _connectionGenerations = {};
  final Map<Mg24SensorRole, DateTime> _lastTransportUpdate = {};
  final Set<Mg24SensorRole> _edgeProtocolRoles = {};
  final Map<Mg24SensorRole, StreamController<Object>> _archiveEvents = {
    Mg24SensorRole.forehead: StreamController<Object>.broadcast(),
    Mg24SensorRole.belly: StreamController<Object>.broadcast(),
  };
  final Map<Mg24SensorRole, StreamController<String>> _controlEvents = {
    Mg24SensorRole.forehead: StreamController<String>.broadcast(),
    Mg24SensorRole.belly: StreamController<String>.broadcast(),
  };

  Mg24State get state => _state;
  Mg24LiveMode get liveMode => _liveMode;

  Future<void> setLiveMode(Mg24LiveMode mode) async {
    if (mode == Mg24LiveMode.valuesAndPlots && _liveMode != mode) {
      _foreheadSampleLoss.reset();
      _bellySampleLoss.reset();
    }
    _liveMode = mode;
    await _applyLiveModeToConnections(mode);
  }

  Future<void> _applyLiveModeToConnections(Mg24LiveMode mode) async {
    if (mode == Mg24LiveMode.valuesAndPlots) {
      await _setWaveformNotifications(true);
      await _writeCommandToConnections(mode.command);
      return;
    }
    await _writeCommandToConnections(mode.command);
    await _setWaveformNotifications(false);
  }

  Future<void> _setWaveformNotifications(bool enabled) async {
    for (final connection in [_foreheadConnection, _bellyConnection]) {
      final characteristic = connection?.waveformCharacteristic;
      if (connection == null ||
          characteristic == null ||
          !connection.device.isConnected ||
          (!characteristic.properties.notify &&
              !characteristic.properties.indicate) ||
          characteristic.isNotifying == enabled) {
        continue;
      }
      await characteristic
          .setNotifyValue(enabled)
          .timeout(const Duration(seconds: 8));
    }
  }

  Future<void> setSensorsEnabled(bool enabled) {
    return _writeCommandToConnections(
      enabled ? 'SENSORS:ON' : 'SENSORS:OFF',
    );
  }

  Future<Set<Mg24SensorRole>> startBoardRecording({
    required int sessionId,
    required DateTime startedAt,
    required Set<Mg24SensorRole> roles,
    DateTime? scheduledStartAt,
  }) async {
    final unixStartMinute = startedAt.millisecondsSinceEpoch ~/ 60000;
    final started = <Mg24SensorRole>{};
    for (final role in Mg24SensorRole.values) {
      if (!roles.contains(role)) continue;
      try {
        var acknowledged = false;
        for (var attempt = 0; attempt < 2 && !acknowledged; attempt++) {
          final scheduled = scheduledStartAt;
          final commandStartedAt = DateTime.now();
          final command = scheduled == null
              ? 'REC:START,${sessionId & 0xffff},$unixStartMinute'
              : 'REC:ARM,${sessionId & 0xffff},$unixStartMinute,'
                  '${math.max(0, scheduled.difference(DateTime.now()).inMilliseconds)}';
          try {
            await _writeCommandToRoleAwaitStatus(
              role,
              command,
              expectedStatus: scheduled == null ? 'OK:REC:START' : 'OK:REC:ARM',
              stateConfirms: (sensor) => scheduled == null
                  ? sensor.recording == true &&
                      sensor.sessionId == (sessionId & 0xffff)
                  : sensor.recordingArmed == true,
            );
            acknowledged = true;
          } on TimeoutException {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            final sensor = _sensorFor(role);
            final freshState = sensor.lastUpdate != null &&
                !sensor.lastUpdate!.isBefore(commandStartedAt);
            final boardConfirmed = freshState &&
                (scheduled == null
                    ? sensor.recording == true
                    : sensor.recordingArmed == true);
            if (boardConfirmed) {
              acknowledged = true;
              continue;
            }
            if (attempt > 0) rethrow;
            // REC:ARM is idempotent. Recalculate the remaining delay so a
            // lost acknowledgement does not shift the scheduled start.
          }
        }
        started.add(role);
      } catch (error) {
        throw Mg24RecordingStartException(
          startedRoles: Set.unmodifiable(started),
          failedRole: role,
          cause: error,
        );
      }
    }
    return Set.unmodifiable(started);
  }

  Future<Set<Mg24SensorRole>> waitForBoardRecording({
    required Set<Mg24SensorRole> roles,
    required int sessionId,
    required DateTime notBefore,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final confirmed = <Mg24SensorRole>{};
    while (DateTime.now().isBefore(deadline)) {
      for (final role in roles) {
        final sensor = _sensorFor(role);
        final fresh = sensor.lastUpdate != null &&
            !sensor.lastUpdate!.isBefore(notBefore);
        final sameSession = sensor.sessionId == (sessionId & 0xffff);
        if (fresh && sameSession && sensor.recordingStartFailed == true) {
          throw Mg24RecordingStartException(
            startedRoles: Set.unmodifiable(confirmed),
            failedRole: role,
            cause: StateError('Firmware konnte das NVM-Archiv nicht starten.'),
          );
        }
        if (fresh && sameSession && sensor.recording == true) {
          confirmed.add(role);
        }
      }
      if (confirmed.length == roles.length) {
        return Set.unmodifiable(confirmed);
      }
      final stillAwaitingConnectedBoard = roles.any(
        (role) => !confirmed.contains(role) && _sensorFor(role).connected,
      );
      if (!stillAwaitingConnectedBoard) {
        return Set.unmodifiable(confirmed);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Every requested board acknowledged REC:ARM before the countdown. A
    // missing summary after the due time is therefore an unverified BLE state,
    // not proof that the autonomous start failed. Only the explicit firmware
    // failure flag above is allowed to cancel the scheduled measurement.
    return Set.unmodifiable(confirmed);
  }

  Future<Set<Mg24SensorRole>> ensureScheduledBoardRecording({
    required Set<Mg24SensorRole> roles,
    required int sessionId,
    required DateTime startedAt,
    required DateTime notBefore,
  }) async {
    final confirmed = <Mg24SensorRole>{
      ...await waitForBoardRecording(
        roles: roles,
        sessionId: sessionId,
        notBefore: notBefore,
      ),
    };

    // REC:ARM normally starts autonomously at the countdown boundary. If a
    // board is still connected but has not started, recover with an immediate
    // command instead of letting the app enter a phantom recording state.
    final connectedUnconfirmed = roles.where((role) {
      if (confirmed.contains(role)) return false;
      return _sensorFor(role).connected;
    }).toSet();
    if (connectedUnconfirmed.isNotEmpty) {
      final recovered = await startBoardRecording(
        sessionId: sessionId,
        startedAt: startedAt,
        roles: connectedUnconfirmed,
      );
      confirmed.addAll(recovered);
      confirmed.addAll(
        await waitForBoardRecording(
          roles: connectedUnconfirmed,
          sessionId: sessionId,
          notBefore: notBefore,
          timeout: const Duration(seconds: 2),
        ),
      );
    }

    final failedConnectedRoles = roles.where((role) {
      if (confirmed.contains(role)) return false;
      return _sensorFor(role).connected;
    }).toList(growable: false);
    if (failedConnectedRoles.isNotEmpty) {
      final failedRole = failedConnectedRoles.first;
      throw Mg24RecordingStartException(
        startedRoles: Set.unmodifiable(confirmed),
        failedRole: failedRole,
        cause: StateError(
          '${failedRole.label} hat den Messstart nicht bestaetigt.',
        ),
      );
    }
    return Set.unmodifiable(confirmed);
  }

  Future<void> stopBoardRecording({Set<Mg24SensorRole>? roles}) async {
    if (roles == null) {
      await _writeCommandToConnections('REC:STOP');
      return;
    }

    // Start every per-board stop before awaiting any of them. REC:STOP is
    // acknowledged only after that board has finished its NVM work, which can
    // take several seconds. Waiting role by role could therefore leave the
    // second board recording (or let its BLE link disappear) before it ever
    // received the command.
    final stops = <Future<void>>[];
    for (final role in Mg24SensorRole.values) {
      if (!roles.contains(role)) continue;
      stops.add(
        _writeCommandToRoleAwaitStatus(
          role,
          'REC:STOP',
          expectedStatus: 'OK:REC:STOP',
          withoutResponse: true,
          stateConfirms: (sensor) =>
              sensor.recording == false && sensor.recordingArmed != true,
          timeout: const Duration(seconds: 20),
        ),
      );
    }
    await Future.wait(stops);
  }

  Future<void> resetAudioAnalysis() async {
    _latestAudioFeatureBands.clear();
    _latestAudioFeatureBandAt.clear();
    await _writeCommandToConnections('AUDIO:RESET');
  }

  Future<void> setMelTraining(bool enabled) async {
    final connection = _foreheadConnection;
    if (enabled) {
      if (connection == null || !connection.device.isConnected) {
        throw StateError('Stirn-MG24 ist nicht verbunden.');
      }
      await _requestConnectionPriority(
        connection.device,
        ConnectionPriority.high,
      );
      await _requestPreferredNotificationMtu(connection.device);
      await _setWaveformNotifications(true);
    }
    await _writeCommandToRole(
      Mg24SensorRole.forehead,
      enabled ? 'TRAIN:MEL:ON' : 'TRAIN:MEL:OFF',
    );
    if (!enabled && _liveMode == Mg24LiveMode.valuesOnly) {
      await _setWaveformNotifications(false);
    }
  }

  Future<void> _requestConnectionPriority(
    BluetoothDevice device,
    ConnectionPriority priority,
  ) async {
    if (!Platform.isAndroid || !device.isConnected) return;
    try {
      await device
          .requestConnectionPriority(connectionPriorityRequest: priority)
          .timeout(const Duration(seconds: 3));
      // Android acknowledges the request before the controller has necessarily
      // applied the new interval. Give it one connection-parameter cycle before
      // starting the sustained 182-byte notification stream.
      await Future<void>.delayed(const Duration(milliseconds: 450));
    } catch (_) {
      // The firmware-side queue still protects short stalls. The preflight in
      // MeasurementController is the authoritative throughput check.
    }
  }

  Future<void> setArchiveTransferMode(
    Mg24SensorRole role,
    bool enabled,
  ) async {
    final connection = switch (role) {
      Mg24SensorRole.forehead => _foreheadConnection,
      Mg24SensorRole.belly => _bellyConnection,
    };
    final summary = connection?.summaryCharacteristic;
    if (connection == null ||
        summary == null ||
        !connection.device.isConnected) {
      throw StateError('${role.label}: Sensor ist nicht verbunden.');
    }
    if (enabled) {
      await _requestConnectionPriority(
        connection.device,
        ConnectionPriority.high,
      );
    }
    final shouldNotify = !enabled;
    if (summary.isNotifying != shouldNotify) {
      await summary
          .setNotifyValue(shouldNotify)
          .timeout(const Duration(seconds: 8));
    }
    connection.deferControlUntil(
      DateTime.now().add(const Duration(milliseconds: 700)),
    );
  }

  Future<Map<Mg24SensorRole, Mg24DownloadedArchive>> downloadMinuteArchives({
    Set<Mg24SensorRole> roles = const {
      Mg24SensorRole.belly,
      Mg24SensorRole.forehead,
    },
    Mg24ArchiveTransferProgress? onProgress,
    Duration maximumDurationPerSensor = const Duration(minutes: 2),
  }) async {
    final result = <Mg24SensorRole, Mg24DownloadedArchive>{};
    for (final role in [Mg24SensorRole.belly, Mg24SensorRole.forehead]) {
      if (!roles.contains(role)) continue;
      final connection = switch (role) {
        Mg24SensorRole.forehead => _foreheadConnection,
        Mg24SensorRole.belly => _bellyConnection,
      };
      if (connection?.controlCharacteristic == null ||
          connection?.archiveCharacteristic == null ||
          connection?.device.isConnected != true) {
        continue;
      }
      final archive = await _downloadArchive(
        role,
        connection!,
        deadline: DateTime.now().add(maximumDurationPerSensor),
        onProgress: onProgress,
      );
      if (archive != null) result[role] = archive;
    }
    return result;
  }

  Future<Map<Mg24SensorRole, Mg24DownloadedEventArchive>>
      downloadEventArchives({
    Set<Mg24SensorRole> roles = const {
      Mg24SensorRole.belly,
      Mg24SensorRole.forehead,
    },
    Mg24ArchiveTransferProgress? onProgress,
    Map<Mg24SensorRole, int> startIndices = const {},
    Mg24EventArchiveChunk? onChunk,
    Duration maximumDurationPerSensor = const Duration(minutes: 2),
  }) async {
    final result = <Mg24SensorRole, Mg24DownloadedEventArchive>{};
    for (final role in [Mg24SensorRole.belly, Mg24SensorRole.forehead]) {
      if (!roles.contains(role)) continue;
      final connection = switch (role) {
        Mg24SensorRole.forehead => _foreheadConnection,
        Mg24SensorRole.belly => _bellyConnection,
      };
      if (connection?.controlCharacteristic == null ||
          connection?.archiveCharacteristic == null ||
          connection?.device.isConnected != true) {
        continue;
      }
      final archive = await _downloadEventArchive(
        role,
        connection!,
        startIndex: startIndices[role] ?? 0,
        deadline: DateTime.now().add(maximumDurationPerSensor),
        onProgress: onProgress,
        onChunk: onChunk,
      );
      if (archive != null) result[role] = archive;
    }
    return result;
  }

  Future<T?> _requestArchiveEvent<T extends Object>(
    Stream<Object> events, {
    required bool Function(T event) matches,
    required Future<void> Function() send,
    Duration responseTimeout = const Duration(seconds: 5),
  }) async {
    final response = Completer<T?>();
    late final StreamSubscription<Object> subscription;
    subscription = events.listen((event) {
      if (!response.isCompleted && event is T && matches(event)) {
        response.complete(event);
      }
    });
    final timer = Timer(responseTimeout, () {
      if (!response.isCompleted) response.complete(null);
    });
    try {
      // Await the GATT write itself before considering another command. A
      // Future timeout does not cancel Android's pending GATT operation.
      await send();
      return await response.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<Mg24DownloadedArchive?> _downloadArchive(
    Mg24SensorRole role,
    _Mg24Connection connection, {
    required DateTime deadline,
    Mg24ArchiveTransferProgress? onProgress,
  }) async {
    final events = _archiveEvents[role]!.stream;
    Mg24ArchiveStatus? status;
    Object? statusError;
    for (var attempt = 0; attempt < 3 && status == null; attempt++) {
      try {
        status = await _requestArchiveEvent<Mg24ArchiveStatus>(
          events,
          matches: (_) => true,
          send: () => _writeCommandToRole(role, 'ARCHIVE:STATUS'),
        );
        if (status == null) {
          statusError = TimeoutException(
            '${role.label}: Archivstatus nicht empfangen.',
          );
        }
      } catch (error) {
        statusError = error;
        // A failed write can remain pending in Android even after its Dart
        // timeout. Retrying now would collide with that same GATT operation.
        break;
      }
      if (status == null) {
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    }
    if (status == null) {
      throw StateError(
        '${role.label}: Archivstatus nicht empfangen ($statusError).',
      );
    }
    final records = <Mg24MinuteRecord>[];
    onProgress?.call(role, 0, status.recordCount);
    var index = 0;
    while (index < status.recordCount) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          '${role.label}: Minutenarchiv-Transfer hat zu lange gedauert.',
        );
      }
      Mg24ArchivePacket? packet;
      Object? packetError;
      for (var attempt = 0; attempt < 4 && packet == null; attempt++) {
        try {
          packet = await _requestArchiveEvent<Mg24ArchivePacket>(
            events,
            matches: (event) => event.firstRecord == index,
            send: () => _writeCommandToRole(role, 'ARCHIVE:$index'),
          );
        } catch (error) {
          packetError = error;
          break;
        }
        if (packet == null) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
      if (packet == null || packet.records.isEmpty) {
        throw StateError(
          '${role.label}: Archivdownload ab Minute $index fehlgeschlagen'
          '${packetError == null ? '.' : ' ($packetError).'}',
        );
      }
      records.addAll(packet.records);
      index += packet.records.length;
      onProgress?.call(
        role,
        math.min(index, status.recordCount),
        status.recordCount,
      );
    }
    return Mg24DownloadedArchive(
      status: status,
      records: List.unmodifiable(records),
    );
  }

  Future<Mg24DownloadedEventArchive?> _downloadEventArchive(
    Mg24SensorRole role,
    _Mg24Connection connection, {
    required int startIndex,
    required DateTime deadline,
    Mg24ArchiveTransferProgress? onProgress,
    Mg24EventArchiveChunk? onChunk,
  }) async {
    final events = _archiveEvents[role]!.stream;
    Mg24EventArchiveStatus? status;
    Object? statusError;
    for (var attempt = 0; attempt < 3 && status == null; attempt++) {
      try {
        status = await _requestArchiveEvent<Mg24EventArchiveStatus>(
          events,
          matches: (_) => true,
          send: () => _writeCommandToRole(role, 'EVENTS:STATUS'),
        );
        if (status == null) {
          statusError = TimeoutException(
            '${role.label}: Ereignisarchivstatus nicht empfangen.',
          );
        }
      } catch (error) {
        statusError = error;
        break;
      }
      if (status == null) {
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    }
    if (status == null) {
      throw StateError(
        '${role.label}: Ereignisarchivstatus nicht empfangen ($statusError).',
      );
    }
    final records = <Mg24EventRecord>[];
    var index = startIndex.clamp(0, status.recordCount);
    onProgress?.call(role, index, status.recordCount);
    while (index < status.recordCount) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          '${role.label}: Ereignisarchiv-Transfer hat zu lange gedauert.',
        );
      }
      Mg24EventArchivePacket? packet;
      Object? packetError;
      for (var attempt = 0; attempt < 4 && packet == null; attempt++) {
        try {
          packet = await _requestArchiveEvent<Mg24EventArchivePacket>(
            events,
            matches: (event) => event.firstRecord == index,
            send: () => _writeCommandToRole(role, 'EVENTS:$index'),
          );
        } catch (error) {
          packetError = error;
          break;
        }
        if (packet == null) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
      if (packet == null || packet.records.isEmpty) {
        throw StateError(
          '${role.label}: Eventdownload ab Index $index fehlgeschlagen'
          '${packetError == null ? '.' : ' ($packetError).'}',
        );
      }
      await onChunk?.call(role, index, packet.records);
      records.addAll(packet.records);
      index += packet.records.length;
      onProgress?.call(
        role,
        math.min(index, status.recordCount),
        status.recordCount,
      );
    }
    return Mg24DownloadedEventArchive(
      status: status,
      records: List.unmodifiable(records),
    );
  }

  Future<void> _writeCommandToConnections(String command) async {
    final connections =
        [_bellyConnection, _foreheadConnection].whereType<_Mg24Connection>();
    for (final connection in connections) {
      final control = connection.controlCharacteristic;
      if (control == null || !connection.device.isConnected) continue;
      await control.write(
        utf8.encode(command),
        withoutResponse: false,
        timeout: 8,
      );
    }
  }

  Future<void> _writeCommandToRole(
    Mg24SensorRole role,
    String command, {
    bool withoutResponse = false,
  }) async {
    final connection = switch (role) {
      Mg24SensorRole.forehead => _foreheadConnection,
      Mg24SensorRole.belly => _bellyConnection,
    };
    final control = connection?.controlCharacteristic;
    if (connection == null ||
        control == null ||
        !connection.device.isConnected) {
      throw StateError('${role.label}: Sensor ist nicht verbunden.');
    }
    final settleDelay = connection.controlReadyAt.difference(DateTime.now());
    if (settleDelay > Duration.zero) {
      if (kDebugMode) {
        debugPrint(
          '[MG24-CONTROL][${role.name}] wait '
          '${settleDelay.inMilliseconds} ms for ATT setup',
        );
      }
      await Future<void>.delayed(settleDelay);
      if (!connection.device.isConnected) {
        throw StateError(
            '${role.label}: Sensor wurde beim BLE-Aufbau getrennt.');
      }
    }
    await control.write(
      utf8.encode(command),
      withoutResponse:
          withoutResponse && control.properties.writeWithoutResponse,
      timeout: 8,
    );
  }

  Future<void> _writeCommandToRoleAwaitStatus(
    Mg24SensorRole role,
    String command, {
    required String expectedStatus,
    bool Function(Mg24SensorSummary sensor)? stateConfirms,
    bool withoutResponse = false,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = Completer<String>();
    late final StreamSubscription<String> subscription;
    subscription = _controlEvents[role]!.stream.listen((status) {
      if (kDebugMode) {
        debugPrint('[MG24-CONTROL][${role.name}] notify <- $status');
      }
      if (!response.isCompleted &&
          (status == expectedStatus || status.startsWith('ERR:'))) {
        response.complete(status);
      }
    });
    final commandStartedAt = DateTime.now();
    try {
      if (kDebugMode) {
        debugPrint('[MG24-CONTROL][${role.name}] write -> $command');
      }
      await _writeCommandToRole(
        role,
        command,
        withoutResponse: withoutResponse,
      );
      if (kDebugMode) {
        debugPrint('[MG24-CONTROL][${role.name}] GATT write acknowledged');
      }
      final deadline = DateTime.now().add(timeout);
      var nextReadAt = DateTime.now().add(const Duration(milliseconds: 300));
      var readAttempt = 0;
      while (DateTime.now().isBefore(deadline)) {
        if (response.isCompleted) {
          final status = await response.future;
          if (status != expectedStatus) {
            throw StateError('${role.label}: Firmware meldet $status.');
          }
          return;
        }
        final sensor = _sensorFor(role);
        final stateIsFresh = sensor.lastUpdate != null &&
            !sensor.lastUpdate!.isBefore(commandStartedAt);
        if (stateIsFresh && stateConfirms != null && stateConfirms(sensor)) {
          if (kDebugMode) {
            debugPrint(
              '[MG24-CONTROL][${role.name}] state confirms $command '
              '(recording=${sensor.recording}, armed=${sensor.recordingArmed}, '
              'session=${sensor.sessionId})',
            );
          }
          return;
        }

        // Android occasionally acknowledges a GATT write but drops the
        // following notification. The firmware keeps its latest control reply
        // as the characteristic value, so a sparse read-back can recover that
        // acknowledgement without resending the command.
        if (!DateTime.now().isBefore(nextReadAt)) {
          readAttempt++;
          final readStatus = await _readControlStatus(role);
          if (kDebugMode) {
            debugPrint(
              '[MG24-CONTROL][${role.name}] read #$readAttempt <- '
              '${readStatus ?? '<keine Antwort>'}',
            );
          }
          if (readStatus == expectedStatus) return;
          final delayMs = switch (readAttempt) {
            1 => 700,
            2 => 1200,
            _ => 1800,
          };
          nextReadAt = DateTime.now().add(Duration(milliseconds: delayMs));
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (response.isCompleted) {
        final status = await response.future;
        if (status == expectedStatus) return;
        throw StateError('${role.label}: Firmware meldet $status.');
      }
      throw TimeoutException(
        '${role.label}: Keine Antwort auf $command.',
        timeout,
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<String?> _readControlStatus(Mg24SensorRole role) async {
    final connection = switch (role) {
      Mg24SensorRole.forehead => _foreheadConnection,
      Mg24SensorRole.belly => _bellyConnection,
    };
    final control = connection?.controlCharacteristic;
    if (connection == null ||
        control == null ||
        !connection.device.isConnected ||
        !control.properties.read) {
      return null;
    }
    try {
      final value = await control.read(timeout: 2);
      final status = utf8.decode(value, allowMalformed: true).trim();
      return status.isEmpty ? null : status;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[MG24-CONTROL][${role.name}] read failed: $error');
      }
      return null;
    }
  }

  Future<void> scanAndConnect({
    Duration scanTimeout = const Duration(seconds: 5),
    Map<Mg24SensorRole, String> preferredRemoteIds = const {},
  }) async {
    final operation = ++_connectOperation;
    final cancellation = Completer<void>();
    final previousCancellation = _connectCancellation;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    _connectCancellation = cancellation;
    _stopping = false;
    _emit(_state.copyWith(
      scanning: true,
      status: 'Suche XIAO MG24 Sensoren ...',
    ));
    await _ensureAdapterOn();
    _ensureConnectActive(operation);

    final needsForehead = !_sensorHasFreshData(_state.forehead);
    final needsBelly = !_sensorHasFreshData(_state.belly);
    if (!needsForehead && !needsBelly) {
      _emit(_state.copyWith(
        scanning: false,
        status: _connectedStatus(),
      ));
      return;
    }

    var candidates = await _systemCandidates(
      preferredRemoteIds: preferredRemoteIds,
    );
    _ensureConnectActive(operation);
    if (_missingNeededCandidate(
      candidates,
      needsForehead: needsForehead,
      needsBelly: needsBelly,
    )) {
      final scannedCandidates = await _scanForCandidates(
        scanTimeout: scanTimeout,
        withServices: [mg24ServiceUuid],
        withKeywords: const [],
        needsForehead: needsForehead,
        needsBelly: needsBelly,
        operation: operation,
        cancellation: cancellation.future,
      );
      candidates = _mergeCandidates(candidates, scannedCandidates);
    }
    if (_missingNeededCandidate(
      candidates,
      needsForehead: needsForehead,
      needsBelly: needsBelly,
    )) {
      final fallbackCandidates = await _scanForCandidates(
        scanTimeout: const Duration(seconds: 4),
        withServices: const [],
        withKeywords: const ['LASLI', 'MG24', 'XIAO'],
        needsForehead: needsForehead,
        needsBelly: needsBelly,
        operation: operation,
        cancellation: cancellation.future,
      );
      candidates = _mergeCandidates(candidates, fallbackCandidates);
    }

    final forehead = needsForehead
        ? _candidateFor(
            candidates,
            Mg24SensorRole.forehead,
            preferredRemoteId: preferredRemoteIds[Mg24SensorRole.forehead],
          )
        : null;
    final belly = needsBelly
        ? _candidateFor(
            candidates,
            Mg24SensorRole.belly,
            preferredRemoteId: preferredRemoteIds[Mg24SensorRole.belly],
          )
        : null;
    if (forehead == null && belly == null) {
      if (_state.forehead.hasData || _state.belly.hasData) {
        _emit(_state.copyWith(
          scanning: false,
          status: _connectedStatus(),
        ));
        return;
      }
      throw StateError(
        'Kein MG24-Sensor gefunden. Die Firmware soll als '
        '$mg24ForeheadName oder $mg24BellyName werben.',
      );
    }

    _emit(_state.copyWith(
      scanning: false,
      status: 'Verbinde XIAO MG24 ...',
      forehead: _state.forehead.copyWith(connecting: forehead != null),
      belly: _state.belly.copyWith(connecting: belly != null),
    ));

    Object? lastConnectError;
    final selectedCandidates = _selectedCandidates(
      candidates,
      needsForehead: needsForehead,
      needsBelly: needsBelly,
      preferredRemoteIds: preferredRemoteIds,
    );

    Future<void> connectSelectedCandidates(
      List<_Mg24Candidate> candidatesToConnect,
    ) async {
      for (var i = 0; i < candidatesToConnect.length; i++) {
        final selectedCandidate = candidatesToConnect[i];
        final role = selectedCandidate.role;
        try {
          await _closeRoleConnection(role);
          _ensureConnectActive(operation);
          final candidate = await _freshCandidateForConnect(
            selectedCandidate,
            operation: operation,
            cancellation: cancellation.future,
          );
          final connection = await _connectOne(
            candidate,
            startupMode: Mg24LiveMode.valuesOnly,
            operation: operation,
            cancellation: cancellation.future,
          );
          _ensureConnectActive(operation);
          _setRoleConnection(role, connection);
        } catch (error) {
          final pendingDevice = _pendingConnectDevices.remove(role);
          if (pendingDevice != null) {
            await _disconnectFailedDevice(pendingDevice);
          }
          if (error is _Mg24ConnectCancelled) rethrow;
          lastConnectError = error;
          _updateSensor(
            role,
            _sensorFor(role).copyWith(
              connected: false,
              connecting: false,
              clearLastUpdate: true,
            ),
            status: '${role.label}: keine Daten empfangen.',
          );
        }
        if (i < candidatesToConnect.length - 1) {
          await _waitForConnectDelay(
            _mg24InterSensorConnectDelay,
            operation: operation,
            cancellation: cancellation.future,
          );
        }
      }
    }

    try {
      await connectSelectedCandidates(selectedCandidates);
    } finally {
      // Keep both links quiet while Android establishes the second GATT
      // session. Restore the requested waveform mode only after setup.
      if (_liveMode != Mg24LiveMode.valuesOnly) {
        try {
          _ensureConnectActive(operation);
          await _applyLiveModeToConnections(_liveMode);
        } catch (_) {
          // A connection callback reports a link that disappeared during setup.
        }
      }
    }
    _ensureConnectActive(operation);

    // Android serializes parts of GATT setup across devices. A role that was
    // connected first must therefore also wait until the second role's final
    // descriptor/write transaction has settled before receiving a control
    // command (notably a deferred REC:STOP).
    final controlReadyAt = DateTime.now().add(
      const Duration(milliseconds: 1200),
    );
    _foreheadConnection?.deferControlUntil(controlReadyAt);
    _bellyConnection?.deferControlUntil(controlReadyAt);

    _emit(_state.copyWith(
      forehead: _state.forehead.copyWith(connecting: false),
      belly: _state.belly.copyWith(connecting: false),
    ));

    if (!_state.forehead.hasData &&
        !_state.belly.hasData &&
        lastConnectError != null) {
      throw StateError(_friendlyMg24ConnectError(lastConnectError!));
    }

    _emit(_state.copyWith(
      scanning: false,
      status: [
        _connectAttemptStatus(
          expectedForehead: needsForehead,
          expectedBelly: needsBelly,
        ),
        if (lastConnectError != null)
          'Fehler: ${_friendlyMg24ConnectError(lastConnectError!)}',
      ].join(' '),
    ));
  }

  Future<_Mg24Candidate> _freshCandidateForConnect(
    _Mg24Candidate selected, {
    required int operation,
    required Future<void> cancellation,
  }) async {
    final needsForehead = selected.role == Mg24SensorRole.forehead;
    final needsBelly = selected.role == Mg24SensorRole.belly;

    // Android may retain a GATT object after an older app process was paused,
    // killed or replaced. Release that session before scanning; connecting
    // through the stale object commonly ends in a supervision timeout.
    if (selected.device.isConnected) {
      _updateSensor(
        selected.role,
        _sensorFor(selected.role),
        status: '${selected.role.label}: alten BLE-Zustand bereinigen ...',
      );
      await _disconnectStaleDevice(selected.device, androidDelay: 1000);
      await _waitForConnectDelay(
        const Duration(milliseconds: 500),
        operation: operation,
        cancellation: cancellation,
      );
    }

    var fresh = await _scanForCandidates(
      scanTimeout: const Duration(seconds: 5),
      withServices: [mg24ServiceUuid],
      withKeywords: const [],
      needsForehead: needsForehead,
      needsBelly: needsBelly,
      operation: operation,
      cancellation: cancellation,
    );
    if (!fresh.any((candidate) => candidate.role == selected.role)) {
      fresh = await _scanForCandidates(
        scanTimeout: const Duration(seconds: 3),
        withServices: const [],
        withKeywords: const ['LASLI'],
        needsForehead: needsForehead,
        needsBelly: needsBelly,
        operation: operation,
        cancellation: cancellation,
      );
    }

    final preferredRemoteId = selected.device.remoteId.toString();
    return _candidateFor(
          fresh,
          selected.role,
          preferredRemoteId: preferredRemoteId,
        ) ??
        selected;
  }

  Future<void> stop() async {
    _stopping = true;
    ++_connectOperation;
    final cancellation = _connectCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _connectCancellation = null;
    _nextConnectionGeneration++;
    _connectionGenerations.clear();
    _lastTransportUpdate.clear();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    final pendingDevices = _pendingConnectDevices.values.toSet();
    _pendingConnectDevices.clear();
    for (final device in pendingDevices) {
      try {
        await device.disconnect(
          queue: false,
          timeout: 4,
          androidDelay: 0,
        );
      } catch (_) {}
    }
    try {
      await setSensorsEnabled(false).timeout(const Duration(seconds: 4));
    } catch (_) {}

    final connections = [_foreheadConnection, _bellyConnection];
    _foreheadConnection = null;
    _bellyConnection = null;
    for (final connection in connections) {
      if (connection == null) continue;
      await connection.close();
    }
    _foreheadPacketLoss.reset();
    _bellyPacketLoss.reset();
    _foreheadWaveformPacketLoss.reset();
    _bellyWaveformPacketLoss.reset();
    _foreheadSampleLoss.reset();
    _bellySampleLoss.reset();
    _edgeProtocolRoles.clear();
    _emit(const Mg24State.empty());
    _stopping = false;
  }

  Future<void> _closeRoleConnection(Mg24SensorRole role) async {
    _connectionGenerations.remove(role);
    _lastTransportUpdate.remove(role);
    final connection = switch (role) {
      Mg24SensorRole.forehead => _foreheadConnection,
      Mg24SensorRole.belly => _bellyConnection,
    };
    switch (role) {
      case Mg24SensorRole.forehead:
        _foreheadConnection = null;
        _foreheadPacketLoss.reset();
        _foreheadWaveformPacketLoss.reset();
        _foreheadSampleLoss.reset();
        _edgeProtocolRoles.remove(role);
      case Mg24SensorRole.belly:
        _bellyConnection = null;
        _bellyPacketLoss.reset();
        _bellyWaveformPacketLoss.reset();
        _bellySampleLoss.reset();
        _edgeProtocolRoles.remove(role);
    }
    if (connection == null) return;
    await connection.close();
  }

  void _setRoleConnection(
    Mg24SensorRole role,
    _Mg24Connection connection,
  ) {
    switch (role) {
      case Mg24SensorRole.forehead:
        _foreheadConnection = connection;
      case Mg24SensorRole.belly:
        _bellyConnection = connection;
    }
  }

  Future<void> _ensureAdapterOn() async {
    final state = await FlutterBluePlus.adapterState
        .where((state) => state != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 4), onTimeout: () {
      return FlutterBluePlus.adapterStateNow;
    });

    if (state == BluetoothAdapterState.on) return;
    if (Platform.isAndroid && state == BluetoothAdapterState.off) {
      await FlutterBluePlus.turnOn(timeout: 8);
      return;
    }
    throw StateError('Bluetooth ist nicht eingeschaltet oder nicht erlaubt.');
  }

  Future<List<_Mg24Candidate>> _scanForCandidates({
    required Duration scanTimeout,
    required List<Guid> withServices,
    required List<String> withKeywords,
    required bool needsForehead,
    required bool needsBelly,
    required int operation,
    required Future<void> cancellation,
  }) async {
    final found = <String, _Mg24Candidate>{};
    final enoughFound = Completer<void>();
    late final StreamSubscription<List<ScanResult>> subscription;
    subscription = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        final candidate = _candidateFromScanResult(
          result,
          needsForehead: needsForehead,
          needsBelly: needsBelly,
        );
        if (candidate == null) continue;
        found[candidate.device.remoteId.toString()] = candidate;
      }
      if (!enoughFound.isCompleted &&
          !_missingNeededCandidate(
            found.values.toList(growable: false),
            needsForehead: needsForehead,
            needsBelly: needsBelly,
          )) {
        enoughFound.complete();
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: withServices,
        withKeywords: withKeywords,
        timeout: scanTimeout,
        androidUsesFineLocation: false,
      );
      await Future.any<void>([
        enoughFound.future,
        Future<void>.delayed(scanTimeout),
        cancellation,
      ]);
    } finally {
      await subscription.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    _ensureConnectActive(operation);

    final values = found.values.toList(growable: false)
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return values;
  }

  Future<List<_Mg24Candidate>> _systemCandidates({
    required Map<Mg24SensorRole, String> preferredRemoteIds,
  }) async {
    final devices = await FlutterBluePlus.systemDevices([mg24ServiceUuid]);
    final candidates = <_Mg24Candidate>[];
    for (final device in devices) {
      final remoteId = device.remoteId.toString();
      final role = _roleForRemoteId(remoteId, preferredRemoteIds) ??
          parseMg24Role(device.platformName) ??
          parseMg24Role(device.advName);
      if (role == null) continue;
      candidates.add(_Mg24Candidate(
        role: role,
        device: device,
        label: device.platformName.isNotEmpty
            ? device.platformName
            : device.advName.isNotEmpty
                ? device.advName
                : remoteId,
        rssi: 0,
      ));
    }
    return candidates;
  }

  Mg24SensorRole? _roleForRemoteId(
    String remoteId,
    Map<Mg24SensorRole, String> preferredRemoteIds,
  ) {
    for (final entry in preferredRemoteIds.entries) {
      if (entry.value == remoteId) return entry.key;
    }
    return null;
  }

  _Mg24Candidate? _candidateFromScanResult(
    ScanResult result, {
    required bool needsForehead,
    required bool needsBelly,
  }) {
    final advertisedName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    final label = advertisedName.isNotEmpty
        ? advertisedName
        : platformName.isNotEmpty
            ? platformName
            : result.device.remoteId.toString();
    var role = parseMg24Role(label);
    final hasService =
        result.advertisementData.serviceUuids.contains(mg24ServiceUuid);
    final looksRelevant = role != null ||
        hasService ||
        label.toLowerCase().contains('mg24') ||
        label.toLowerCase().contains('lasli');
    if (!looksRelevant) return null;
    if (role == null && hasService) {
      role = _roleForSingleMissingSensor(
        needsForehead: needsForehead,
        needsBelly: needsBelly,
      );
    }
    if (role == null) return null;
    return _Mg24Candidate(
      role: role,
      device: result.device,
      label: label,
      rssi: result.rssi,
    );
  }

  Mg24SensorRole? _roleForSingleMissingSensor({
    required bool needsForehead,
    required bool needsBelly,
  }) {
    if (needsForehead == needsBelly) return null;
    return needsForehead ? Mg24SensorRole.forehead : Mg24SensorRole.belly;
  }

  bool _missingNeededCandidate(
    List<_Mg24Candidate> candidates, {
    required bool needsForehead,
    required bool needsBelly,
  }) {
    final hasForehead = candidates
        .any((candidate) => candidate.role == Mg24SensorRole.forehead);
    final hasBelly =
        candidates.any((candidate) => candidate.role == Mg24SensorRole.belly);
    return (needsForehead && !hasForehead) || (needsBelly && !hasBelly);
  }

  List<_Mg24Candidate> _mergeCandidates(
    List<_Mg24Candidate> primary,
    List<_Mg24Candidate> fallback,
  ) {
    final byRemoteId = <String, _Mg24Candidate>{};
    for (final candidate in [...primary, ...fallback]) {
      final key = candidate.device.remoteId.toString();
      final existing = byRemoteId[key];
      if (existing == null || candidate.rssi > existing.rssi) {
        byRemoteId[key] = candidate;
      }
    }
    return byRemoteId.values.toList(growable: false)
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  Future<_Mg24Connection> _connectOne(
    _Mg24Candidate candidate, {
    required Mg24LiveMode startupMode,
    required int operation,
    required Future<void> cancellation,
  }) async {
    final role = candidate.role;
    final generation = _beginConnectionGeneration(role);
    _updateSensor(
      role,
      _sensorFor(role).copyWith(
        connected: false,
        connecting: true,
        name: candidate.label,
        remoteId: candidate.device.remoteId.toString(),
        rssi: candidate.rssi,
      ),
      status: 'Verbinde ${role.label}: ${candidate.label} ...',
    );

    final device = candidate.device;
    _pendingConnectDevices[role] = device;
    List<BluetoothService> services;
    try {
      services = await _connectAndDiscover(
        device,
        operation: operation,
        cancellation: cancellation,
      );
      _ensureConnectActive(operation);
    } catch (_) {
      if (identical(_pendingConnectDevices[role], device)) {
        _pendingConnectDevices.remove(role);
      }
      await _disconnectFailedDevice(device);
      rethrow;
    }
    var characteristic = _findDataCharacteristic(services);
    if (characteristic == null) {
      _updateSensor(
        role,
        _sensorFor(role),
        status: '${role.label}: BLE-Service wird aktualisiert ...',
      );
      services = await _refreshServicesAfterMissingCharacteristic(
        device,
        operation: operation,
        cancellation: cancellation,
      );
      _ensureConnectActive(operation);
      characteristic = _findDataCharacteristic(services);
    }
    if (characteristic == null) {
      if (identical(_pendingConnectDevices[role], device)) {
        _pendingConnectDevices.remove(role);
      }
      await _disconnectFailedDevice(device);
      throw StateError(
        '${role.label}: MG24-Daten-Characteristic nicht gefunden. '
        'Gefunden: ${_describeServices(services)}',
      );
    }
    final controlCharacteristic =
        _findCharacteristic(services, mg24ControlCharacteristicUuid);
    final summaryCharacteristic =
        _findCharacteristic(services, mg24SummaryCharacteristicUuid);
    final waveformCharacteristic =
        _findCharacteristic(services, mg24WaveformCharacteristicUuid);
    final archiveCharacteristic =
        _findCharacteristic(services, mg24ArchiveCharacteristicUuid);
    final usesEdgeProtocol =
        summaryCharacteristic != null && controlCharacteristic != null;

    final firstSample = Completer<void>();
    final disconnectedBeforeData = Completer<void>();
    void consumeValue(List<int> value) {
      if (!_isCurrentConnection(role, generation)) return;
      final sample = Mg24SensorSample.parse(value, fallbackRole: role);
      if (sample == null || !_isCompleteSensorSample(sample)) return;
      _lastTransportUpdate[role] = sample.receivedAt;
      if (sample.role == role && !firstSample.isCompleted) {
        firstSample.complete();
      }
      _handleSample(sample);
      onSample(sample);
    }

    void consumeSummary(List<int> value) {
      if (!_isCurrentConnection(role, generation)) return;
      final summary = Mg24EdgeSummary.parse(value);
      if (summary == null || summary.role != role) return;
      _lastTransportUpdate[role] = DateTime.now();
      if (!firstSample.isCompleted) firstSample.complete();
      _handleEdgeSummary(summary);
      onSample(_sampleFromEdgeSummary(summary));
    }

    void consumeWaveform(List<int> value) {
      if (!_isCurrentConnection(role, generation)) return;
      if (value.length >= 3 && value[2] == mg24MelFeaturePacketType) {
        final melPacket =
            Mg24MelFeaturePacket.parse(value, receivedAt: DateTime.now());
        if (melPacket != null && melPacket.role == role) {
          _lastTransportUpdate[role] = melPacket.receivedAt;
          onMelFeatures?.call(melPacket);
        }
        return;
      }
      final packet =
          Mg24WaveformPacket.parse(value, receivedAt: DateTime.now());
      if (packet == null || packet.role != role) return;
      _lastTransportUpdate[role] = packet.receivedAt;
      _handleWaveform(packet);
      onWaveform?.call(packet);
    }

    void consumeArchive(List<int> value) {
      if (!_isCurrentConnection(role, generation) || value.length < 3) return;
      final Object? event = switch (value[2]) {
        mg24ArchiveStatusPacketType => Mg24ArchiveStatus.parse(value),
        mg24ArchivePacketType => Mg24ArchivePacket.parse(value),
        mg24EventArchiveStatusPacketType => Mg24EventArchiveStatus.parse(value),
        mg24EventArchivePacketType => Mg24EventArchivePacket.parse(value),
        _ => null,
      };
      if (event != null) {
        _lastTransportUpdate[role] = DateTime.now();
        _archiveEvents[role]?.add(event);
      }
    }

    void consumeControl(List<int> value) {
      if (!_isCurrentConnection(role, generation)) return;
      final status = utf8.decode(value, allowMalformed: true).trim();
      if (status.isEmpty) return;
      _lastTransportUpdate[role] = DateTime.now();
      _controlEvents[role]?.add(status);
    }

    final notifySubscription =
        characteristic.onValueReceived.listen(consumeValue);
    final extraNotifySubscriptions = <StreamSubscription<List<int>>>[];
    if (summaryCharacteristic != null) {
      extraNotifySubscriptions.add(
        summaryCharacteristic.onValueReceived.listen(consumeSummary),
      );
    }
    if (waveformCharacteristic != null) {
      extraNotifySubscriptions.add(
        waveformCharacteristic.onValueReceived.listen(consumeWaveform),
      );
    }
    if (archiveCharacteristic != null) {
      extraNotifySubscriptions.add(
        archiveCharacteristic.onValueReceived.listen(consumeArchive),
      );
    }
    if (controlCharacteristic != null) {
      extraNotifySubscriptions.add(
        controlCharacteristic.onValueReceived.listen(consumeControl),
      );
    }

    final connectionSubscription = device.connectionState.listen((state) {
      if (state != BluetoothConnectionState.disconnected) return;
      if (!_isCurrentConnection(role, generation) || _stopping) return;
      if (!firstSample.isCompleted && !disconnectedBeforeData.isCompleted) {
        disconnectedBeforeData.complete();
      }
      final reason = _disconnectReasonLabel(device);
      _updateSensor(
        role,
        _sensorFor(role).copyWith(
          connected: false,
          connecting: false,
          clearLastUpdate: true,
        ),
        status: '${role.label}-MG24 getrennt$reason',
      );
      onConnectionLost?.call();
    });

    try {
      if (Platform.isAndroid) {
        await _waitForConnectDelay(
          const Duration(milliseconds: 250),
          operation: operation,
          cancellation: cancellation,
        );
      }
      if (!usesEdgeProtocol) {
        await characteristic
            .setNotifyValue(true)
            .timeout(const Duration(seconds: 8));
      } else {
        await summaryCharacteristic
            .setNotifyValue(true)
            .timeout(const Duration(seconds: 8));
      }
      if (controlCharacteristic != null &&
          (controlCharacteristic.properties.notify ||
              controlCharacteristic.properties.indicate)) {
        await controlCharacteristic
            .setNotifyValue(true)
            .timeout(const Duration(seconds: 8));
      }
      if (controlCharacteristic != null) {
        await controlCharacteristic.write(
          utf8.encode('SENSORS:ON'),
          withoutResponse: false,
          timeout: 8,
        );
        _ensureConnectActive(operation);
        await controlCharacteristic.write(
          utf8.encode(startupMode.command),
          withoutResponse: false,
          timeout: 8,
        );
        _ensureConnectActive(operation);
      }
      _updateSensor(
        role,
        _sensorFor(role).copyWith(
          connected: true,
          connecting: true,
          name: candidate.label,
          remoteId: device.remoteId.toString(),
          rssi: candidate.rssi,
        ),
        status: '${role.label}: verbunden, warte auf Daten ...',
      );
      final dataState = await _waitForFirstDataState(
        firstSample,
        disconnectedBeforeData,
        _mg24FirstSampleTimeout,
        cancellation,
      );
      if (dataState == -2) throw const _Mg24ConnectCancelled();
      if (dataState != 1 || !firstSample.isCompleted) {
        final state = dataState < 0 ? 'getrennt' : 'ohne Daten';
        throw StateError(
          '${role.label}: BLE $state'
          '${_disconnectReasonLabel(device)} '
          '(MTU ${device.mtuNow}).',
        );
      }
      for (final optional in [archiveCharacteristic]) {
        if (optional == null ||
            (!optional.properties.notify && !optional.properties.indicate)) {
          continue;
        }
        await optional.setNotifyValue(true).timeout(const Duration(seconds: 8));
      }
    } catch (error) {
      if (identical(_pendingConnectDevices[role], device)) {
        _pendingConnectDevices.remove(role);
      }
      _connectionGenerations.remove(role);
      await notifySubscription.cancel();
      for (final subscription in extraNotifySubscriptions) {
        await subscription.cancel();
      }
      await connectionSubscription.cancel();
      if (error is! _Mg24ConnectCancelled) {
        _updateSensor(
          role,
          _sensorFor(role).copyWith(
            connected: false,
            connecting: false,
            clearLastUpdate: true,
          ),
          status: '${role.label}: ${_friendlyMg24ConnectError(error)}',
        );
      }
      await _disconnectFailedDevice(device);
      if (error is TimeoutException) {
        throw StateError(
          '${role.label}: BLE verbunden, aber es kamen keine MG24-Daten an.',
        );
      }
      rethrow;
    }

    final dataWatchdog = _startDataWatchdog(
      role: role,
      device: device,
      generation: generation,
    );
    final rssiMonitor = _startRssiMonitor(
      role: role,
      device: device,
      generation: generation,
    );
    _updateSensor(
      role,
      _sensorFor(role).copyWith(
        connected: true,
        connecting: false,
        name: candidate.label,
        remoteId: device.remoteId.toString(),
        rssi: candidate.rssi,
      ),
      status: '${role.label}-MG24 verbunden',
    );
    if (identical(_pendingConnectDevices[role], device)) {
      _pendingConnectDevices.remove(role);
    }

    return _Mg24Connection(
      device: device,
      controlReadyAt: DateTime.now().add(const Duration(milliseconds: 900)),
      characteristic: characteristic,
      notifySubscription: notifySubscription,
      extraCharacteristics: [
        if (summaryCharacteristic != null) summaryCharacteristic,
        if (waveformCharacteristic != null) waveformCharacteristic,
        if (archiveCharacteristic != null) archiveCharacteristic,
        if (controlCharacteristic != null) controlCharacteristic,
      ],
      extraNotifySubscriptions: extraNotifySubscriptions,
      controlCharacteristic: controlCharacteristic,
      summaryCharacteristic: summaryCharacteristic,
      waveformCharacteristic: waveformCharacteristic,
      archiveCharacteristic: archiveCharacteristic,
      connectionSubscription: connectionSubscription,
      dataWatchdog: dataWatchdog,
      rssiMonitor: rssiMonitor,
    );
  }

  Future<List<BluetoothService>> _connectAndDiscover(
    BluetoothDevice device, {
    required int operation,
    required Future<void> cancellation,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < _mg24ConnectAttempts; attempt++) {
      try {
        await _prepareDeviceForConnectAttempt(device, attempt);
        _ensureConnectActive(operation);
        if (!device.isConnected) {
          await device
              .connect(
                license: License.free,
                timeout: const Duration(seconds: 18),
                mtu: null,
              )
              .timeout(const Duration(seconds: 21));
          _ensureConnectActive(operation);
        }
        if (Platform.isAndroid) {
          await _waitForConnectDelay(
            const Duration(milliseconds: 750),
            operation: operation,
            cancellation: cancellation,
          );
        }
        final services = await device.discoverServices(
          subscribeToServicesChanged: false,
          timeout: 18,
        );
        _ensureConnectActive(operation);
        if (services.isEmpty) {
          throw StateError('MG24-Service Discovery lieferte keine Services.');
        }
        await _requestPreferredNotificationMtu(device);
        _ensureConnectActive(operation);
        return services;
      } catch (error) {
        if (error is _Mg24ConnectCancelled) rethrow;
        lastError = error;
        await _recoverAfterConnectFailure(
          device,
          attempt,
          error,
          operation: operation,
          cancellation: cancellation,
        );
      }
    }
    throw lastError ?? StateError('MG24-Service Discovery fehlgeschlagen.');
  }

  Future<void> _requestPreferredNotificationMtu(BluetoothDevice device) async {
    if (!Platform.isAndroid || device.mtuNow >= 185) return;
    try {
      await device.requestMtu(
        _mg24PreferredNotificationMtu,
        predelay: 0.75,
        timeout: 8,
      );
    } catch (_) {
      // A delayed Android MTU event may still arrive. The first complete
      // notification below remains the authoritative transport check.
    }
  }

  bool _isCompleteSensorSample(Mg24SensorSample sample) {
    return sample.sensorTimeS != null &&
        (sample.ax != null ||
            sample.ay != null ||
            sample.az != null ||
            sample.rollDeg != null ||
            sample.pitchDeg != null);
  }

  Future<int> _waitForFirstDataState(
    Completer<void> firstSample,
    Completer<void> disconnected,
    Duration duration,
    Future<void> cancellation,
  ) {
    return Future.any<int>([
      firstSample.future.then((_) => 1),
      disconnected.future.then((_) => -1),
      cancellation.then((_) => -2),
      Future<int>.delayed(duration, () => 0),
    ]);
  }

  String _disconnectReasonLabel(BluetoothDevice device) {
    final reason = device.disconnectReason;
    if (reason == null ||
        (reason.code == null && (reason.description?.isEmpty ?? true))) {
      return '';
    }
    final code = reason.code == null ? '' : ' ${reason.code}';
    final description = reason.description?.trim();
    final text =
        description == null || description.isEmpty ? '' : ' $description';
    return ' (Android$code$text)';
  }

  Future<void> _prepareDeviceForConnectAttempt(
    BluetoothDevice device,
    int attempt,
  ) async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    if (device.isConnected) {
      if (Platform.isAndroid && attempt > 0) {
        try {
          await device.clearGattCache().timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      await _disconnectStaleDevice(
        device,
        androidDelay: attempt == 0 ? 1800 : 2600,
      );
    } else if (Platform.isAndroid && attempt > 0) {
      await Future<void>.delayed(
        Duration(milliseconds: 900 + attempt * 450),
      );
    }
  }

  Future<void> _recoverAfterConnectFailure(
    BluetoothDevice device,
    int attempt,
    Object error, {
    required int operation,
    required Future<void> cancellation,
  }) async {
    final androidGattProblem = _looksLikeAndroidGattProblem(error);
    await _disconnectFailedDevice(
      device,
      androidDelay: androidGattProblem ? 2800 : 1400,
    );

    final delayMs =
        androidGattProblem ? 1600 + attempt * 850 : 750 + attempt * 450;
    await _waitForConnectDelay(
      Duration(milliseconds: delayMs),
      operation: operation,
      cancellation: cancellation,
    );
  }

  bool _looksLikeAndroidGattProblem(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('gatt') ||
        text.contains('android-code: 133') ||
        text.contains('android code 133') ||
        text.contains('code: 133') ||
        text.contains('code 133') ||
        text.contains('133');
  }

  void _ensureConnectActive(int operation) {
    if (_stopping || operation != _connectOperation) {
      throw const _Mg24ConnectCancelled();
    }
  }

  Future<void> _waitForConnectDelay(
    Duration duration, {
    required int operation,
    required Future<void> cancellation,
  }) async {
    await Future.any<void>([
      Future<void>.delayed(duration),
      cancellation,
    ]);
    _ensureConnectActive(operation);
  }

  int _beginConnectionGeneration(Mg24SensorRole role) {
    final generation = ++_nextConnectionGeneration;
    _connectionGenerations[role] = generation;
    return generation;
  }

  bool _isCurrentConnection(Mg24SensorRole role, int generation) {
    return _connectionGenerations[role] == generation;
  }

  bool _sensorHasFreshData(
    Mg24SensorSummary sensor, {
    Duration maxAge = const Duration(seconds: 5),
  }) {
    final lastUpdate = sensor.lastUpdate;
    if (!sensor.connected || lastUpdate == null) return false;
    return DateTime.now().difference(lastUpdate) <= maxAge;
  }

  Timer _startDataWatchdog({
    required Mg24SensorRole role,
    required BluetoothDevice device,
    required int generation,
  }) {
    var staleReported = false;
    return Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isCurrentConnection(role, generation) || _stopping) {
        timer.cancel();
        return;
      }
      if (!device.isConnected) {
        timer.cancel();
        return;
      }
      final sensor = _sensorFor(role);
      final summaryUpdate = sensor.lastUpdate;
      final transportUpdate = _lastTransportUpdate[role];
      final lastUpdate = summaryUpdate == null
          ? transportUpdate
          : transportUpdate == null || summaryUpdate.isAfter(transportUpdate)
              ? summaryUpdate
              : transportUpdate;
      final stale = lastUpdate == null ||
          DateTime.now().difference(lastUpdate) > const Duration(seconds: 14);
      if (stale) {
        if (staleReported) return;
        staleReported = true;
        // A temporary notification pause is not a broken GATT link. Keeping
        // the connection lets Android and the board resume without another
        // scan/service-discovery cycle.
        _updateSensor(
          role,
          sensor.copyWith(
            connected: true,
            connecting: false,
            clearLastUpdate: true,
          ),
          status: '${role.label}: verbunden, warte auf frische Daten ...',
        );
        return;
      }

      if (!staleReported) return;
      staleReported = false;
      _updateSensor(
        role,
        sensor.copyWith(connected: true, connecting: false),
        status: _connectedStatus(),
      );
    });
  }

  Timer _startRssiMonitor({
    required Mg24SensorRole role,
    required BluetoothDevice device,
    required int generation,
  }) {
    var reading = false;
    return Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (!_isCurrentConnection(role, generation) ||
          _stopping ||
          !device.isConnected) {
        timer.cancel();
        return;
      }
      if (reading) return;
      reading = true;
      try {
        final rssi = await device.readRssi(timeout: 4);
        if (_isCurrentConnection(role, generation) &&
            rssi < 0 &&
            rssi >= -127) {
          _updateSensor(
            role,
            _sensorFor(role).copyWith(rssi: rssi),
          );
        }
      } catch (_) {
        // RSSI is diagnostic only; a failed read must not stop streaming.
      } finally {
        reading = false;
      }
    });
  }

  Future<List<BluetoothService>> _refreshServicesAfterMissingCharacteristic(
    BluetoothDevice device, {
    required int operation,
    required Future<void> cancellation,
  }) async {
    if (Platform.isAndroid && device.isConnected) {
      try {
        await device.clearGattCache().timeout(const Duration(seconds: 4));
        await _waitForConnectDelay(
          const Duration(milliseconds: 650),
          operation: operation,
          cancellation: cancellation,
        );
      } catch (error) {
        if (error is _Mg24ConnectCancelled) rethrow;
      }
    }

    if (device.isConnected) {
      try {
        final services = await device.discoverServices(
          subscribeToServicesChanged: false,
          timeout: 18,
        );
        _ensureConnectActive(operation);
        return services;
      } catch (error) {
        if (error is _Mg24ConnectCancelled) rethrow;
      }
    }

    await _disconnectFailedDevice(device);
    await _waitForConnectDelay(
      const Duration(milliseconds: 900),
      operation: operation,
      cancellation: cancellation,
    );
    return _connectAndDiscover(
      device,
      operation: operation,
      cancellation: cancellation,
    );
  }

  Future<void> _disconnectStaleDevice(
    BluetoothDevice device, {
    int androidDelay = 1600,
  }) async {
    if (!device.isConnected) return;
    try {
      await device.disconnect(
        queue: false,
        timeout: 8,
        androidDelay: androidDelay,
      );
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  Future<void> _disconnectFailedDevice(
    BluetoothDevice device, {
    int androidDelay = 800,
  }) async {
    try {
      await device.disconnect(
        queue: false,
        timeout: 8,
        androidDelay: androidDelay,
      );
    } catch (_) {}
  }

  BluetoothCharacteristic? _findDataCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == mg24DataCharacteristicUuid) {
          return characteristic;
        }
      }
    }
    for (final service in services) {
      if (service.uuid != mg24ServiceUuid) continue;
      for (final characteristic in service.characteristics) {
        final properties = characteristic.properties;
        if (properties.notify || properties.indicate) return characteristic;
      }
    }
    return null;
  }

  BluetoothCharacteristic? _findCharacteristic(
    List<BluetoothService> services,
    Guid uuid,
  ) {
    for (final service in services) {
      if (service.uuid != mg24ServiceUuid) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == uuid) return characteristic;
      }
    }
    return null;
  }

  String _describeServices(List<BluetoothService> services) {
    if (services.isEmpty) return 'keine Services';
    return services.take(8).map((service) {
      final characteristics = service.characteristics
          .take(8)
          .map((characteristic) => characteristic.uuid.toString())
          .join(',');
      return '${service.uuid}[$characteristics]';
    }).join('; ');
  }

  void _handleSample(Mg24SensorSample sample) {
    final previous = _sensorFor(sample.role);
    final packetLossPercent = _packetLossEstimatorFor(sample.role).update(
      packetSequence: sample.packetSequence,
      receivedAt: sample.receivedAt,
    );
    final sensor = _sensorFor(sample.role).copyWith(
      connected: true,
      connecting: false,
      lastUpdate: sample.receivedAt,
      angleDeg: sample.resolvedAngleDeg,
      rollDeg: sample.rollDeg,
      pitchDeg: sample.pitchDeg,
      yawDeg: sample.yawDeg,
      qw: sample.qw,
      qx: sample.qx,
      qy: sample.qy,
      qz: sample.qz,
      ax: sample.ax,
      ay: sample.ay,
      az: sample.az,
      gx: sample.gx,
      gy: sample.gy,
      gz: sample.gz,
      ppgIr: sample.ppgIr,
      ppgRed: sample.ppgRed,
      ppgQuality: sample.ppgQuality ?? previous.ppgQuality,
      perfusionIndex: sample.perfusionIndex,
      heartRateRawBpm: sample.heartRateRawBpm,
      spo2RawPercent: sample.spo2RawPercent,
      ppgRawWaveform: previous.ppgRawWaveform,
      ppgWaveform: previous.ppgWaveform,
      ppgPeaks: previous.ppgPeaks,
      batteryPercent: sample.batteryPercent,
      batteryVoltage: sample.batteryVoltage,
      earTemperatureC: sample.earTemperatureC,
      blePacketLossPercent: packetLossPercent,
    );
    _updateSensor(
      sample.role,
      sensor,
      heartRateBpm: sample.heartRateBpm,
      clearHeartRateBpm:
          sample.max30102Connected == true && sample.heartRateBpm == null,
      spo2Percent: sample.spo2Percent,
      clearSpo2Percent:
          sample.max30102Connected == true && sample.spo2Percent == null,
      max30102Connected: sample.role == Mg24SensorRole.forehead
          ? sample.max30102Connected
          : null,
      max30102Bus:
          sample.role == Mg24SensorRole.forehead ? sample.max30102Bus : null,
    );
  }

  Mg24SensorSample _sampleFromEdgeSummary(Mg24EdgeSummary summary) {
    final audioBands = _recentAudioFeatureBands(summary.role);
    return Mg24SensorSample(
      role: summary.role,
      receivedAt: DateTime.now(),
      sensorTimeS: summary.uptimeMs / 1000.0,
      packetSequence: summary.sequence,
      rollDeg: summary.rollDeg,
      pitchDeg: summary.pitchDeg,
      yawDeg: summary.yawDeg,
      angleDeg: summary.pitchDeg,
      qw: summary.qw,
      qx: summary.qx,
      qy: summary.qy,
      qz: summary.qz,
      ppgQuality: summary.ppgQuality,
      heartRateBpm: summary.heartRateBpm,
      spo2Percent: summary.spo2Percent,
      batteryPercent: summary.batteryPercent,
      max30102Connected: summary.role == Mg24SensorRole.forehead
          ? summary.max30102Connected
          : null,
      earTemperatureC: summary.temperatureC,
      breathingRatePerMin: summary.respirationRatePerMin,
      breathingQuality: summary.respirationQuality,
      snoring: summary.snoreAvailable ? summary.snoring : null,
      snoreScore: summary.snoreScore,
      snoreRmsDb: summary.snoreAvailable
          ? _snoreRmsDbFromVolume(summary.snoreVolumePercent)
          : null,
      snoreLevelRatioPercent: summary.snoreLevelRatioPercent,
      snoreLowRatioPercent: summary.snoreLowRatioPercent,
      snoreCrossingRatePercent: summary.snoreCrossingRatePercent,
      snoreRawSwing: summary.snoreRawSwing,
      snorePatternQualityPercent: summary.snorePatternQualityPercent,
      snoreRatePerMin:
          summary.snoreRatePerMin == 0 ? null : summary.snoreRatePerMin,
      snoreBreathWidthMs:
          summary.snoreBreathWidthMs == 0 ? null : summary.snoreBreathWidthMs,
      snoreBurstAgeMs:
          summary.snoreBurstAgeMs == 0xFFFF ? null : summary.snoreBurstAgeMs,
      snoreBurstCounter: summary.snoreBurstCounter,
      snoreBurstActive: summary.snoreBurstActive,
      snoreActiveWidthMs:
          summary.snoreActiveWidthMs == 0 ? null : summary.snoreActiveWidthMs,
      snoreAudioBand0To150Percent: audioBands == null ? null : audioBands[0],
      snoreAudioBand150To300Percent: audioBands == null ? null : audioBands[1],
      snoreAudioBand300To600Percent: audioBands == null ? null : audioBands[2],
      snoreAudioBand600To1200Percent: audioBands == null ? null : audioBands[3],
      snoreAudioBand1200To3000Percent:
          audioBands == null ? null : audioBands[4],
      snoreEnvelopeLift: summary.snoreEnvelopeLift,
      snoreCrestFactor: summary.snoreCrestFactor,
      snoreModulationPercent: summary.snoreModulationPercent,
      snoreBlockScorePercent: summary.snoreBlockScorePercent,
      snoreContinuationScorePercent: summary.snoreContinuationScorePercent,
      snoreAudioContactArtifact: summary.snoreAudioContactArtifact,
      snoreMotionArtifact: summary.snoreMotionArtifact,
      edgeProcessed: true,
    );
  }

  void _handleEdgeSummary(Mg24EdgeSummary summary) {
    final now = DateTime.now();
    if (_edgeProtocolRoles.add(summary.role)) {
      _packetLossEstimatorFor(summary.role).reset();
    }
    final packetLoss = _packetLossEstimatorFor(summary.role).update(
      packetSequence: summary.sequence,
      receivedAt: now,
    );
    final sensor = _sensorFor(summary.role).copyWith(
      connected: true,
      connecting: false,
      lastUpdate: now,
      angleDeg: summary.pitchDeg,
      rollDeg: summary.rollDeg,
      pitchDeg: summary.pitchDeg,
      yawDeg: summary.yawDeg,
      qw: summary.qw,
      qx: summary.qx,
      qy: summary.qy,
      qz: summary.qz,
      ppgQuality: summary.ppgQuality,
      batteryPercent: summary.batteryPercent,
      earTemperatureC: summary.temperatureC,
      blePacketLossPercent: packetLoss,
      sensorsEnabled: summary.sensorsEnabled,
      recording: summary.recording,
      recordingArmed: summary.recordingArmed,
      recordingStartFailed: summary.recordingStartFailed,
      sessionId: summary.sessionId,
      archiveRecords: summary.archiveRecords,
      archiveCapacity: summary.archiveCapacity,
    );
    _updateSensor(
      summary.role,
      sensor,
      heartRateBpm: summary.heartRateBpm,
      clearHeartRateBpm: summary.role == Mg24SensorRole.forehead &&
          summary.heartRateBpm == null,
      spo2Percent: summary.spo2Percent,
      clearSpo2Percent: summary.role == Mg24SensorRole.forehead &&
          summary.spo2Percent == null,
      breathingRatePerMin: summary.respirationRatePerMin,
      clearBreathingRatePerMin: summary.role == Mg24SensorRole.belly &&
          summary.respirationRatePerMin == null,
      breathingQuality: summary.respirationQuality,
      max30102Connected: summary.role == Mg24SensorRole.forehead
          ? summary.max30102Connected
          : null,
    );
  }

  void _handleWaveform(Mg24WaveformPacket packet) {
    final packetLossEstimator = packet.role == Mg24SensorRole.forehead
        ? _foreheadWaveformPacketLoss
        : _bellyWaveformPacketLoss;
    final waveformPacketLoss = packetLossEstimator.update(
      packetSequence: packet.packetSequence,
      receivedAt: DateTime.now(),
    );
    if (packet.stream == Mg24WaveformPacket.audioFeatureStream) {
      if (packet.samples.length >= 5) {
        _latestAudioFeatureBands[packet.role] = packet.samples
            .take(5)
            .map((value) => value.isFinite ? value : double.nan)
            .toList(growable: false);
        _latestAudioFeatureBandAt[packet.role] = DateTime.now();
      }
      _updateSensor(
        packet.role,
        _sensorFor(packet.role).copyWith(
          plotPacketLossPercent: waveformPacketLoss,
        ),
      );
      return;
    }
    final isPrimaryStream = packet.role == Mg24SensorRole.forehead
        ? packet.stream == Mg24WaveformPacket.ppgStream
        : packet.stream == Mg24WaveformPacket.respirationStream;
    final sampleLossEstimator = packet.role == Mg24SensorRole.forehead
        ? _foreheadSampleLoss
        : _bellySampleLoss;
    final sampleLoss = isPrimaryStream
        ? sampleLossEstimator.add(
            firstSequence: packet.firstSampleSequence,
            count: packet.samples.length,
          )
        : null;
    final previous = _sensorFor(packet.role);
    var waveform = previous.ppgWaveform;
    var peaks = previous.ppgPeaks;
    if (packet.stream == Mg24WaveformPacket.ppgStream) {
      waveform = [...waveform, ...packet.samples];
      peaks = [...peaks, ...packet.peaks];
      if (waveform.length > _ppgMaximumSamples) {
        final remove = waveform.length - _ppgMaximumSamples;
        waveform = waveform.sublist(remove);
        peaks = peaks.sublist(remove);
      }
    }
    _updateSensor(
      packet.role,
      previous.copyWith(
        ppgWaveform: waveform,
        ppgPeaks: peaks,
        plotPacketLossPercent: waveformPacketLoss,
        plotSampleLossPercent: sampleLoss,
      ),
    );
  }

  List<double>? _recentAudioFeatureBands(Mg24SensorRole role) {
    final at = _latestAudioFeatureBandAt[role];
    final bands = _latestAudioFeatureBands[role];
    if (at == null || bands == null || bands.length < 5) return null;
    if (DateTime.now().difference(at) > const Duration(seconds: 2)) {
      return null;
    }
    return bands;
  }

  void _updateSensor(
    Mg24SensorRole role,
    Mg24SensorSummary sensor, {
    String? status,
    double? heartRateBpm,
    bool clearHeartRateBpm = false,
    double? spo2Percent,
    bool clearSpo2Percent = false,
    double? breathingRatePerMin,
    bool clearBreathingRatePerMin = false,
    double? breathingQuality,
    bool? max30102Connected,
    int? max30102Bus,
  }) {
    _emit(_state.copyWith(
      status: status,
      forehead: role == Mg24SensorRole.forehead ? sensor : null,
      belly: role == Mg24SensorRole.belly ? sensor : null,
      heartRateBpm: heartRateBpm,
      clearHeartRateBpm: clearHeartRateBpm,
      spo2Percent: spo2Percent,
      clearSpo2Percent: clearSpo2Percent,
      breathingRatePerMin: breathingRatePerMin,
      clearBreathingRatePerMin: clearBreathingRatePerMin,
      breathingQuality: breathingQuality,
      max30102Connected: max30102Connected,
      max30102Bus: max30102Bus,
    ));
  }

  Mg24SensorSummary _sensorFor(Mg24SensorRole role) {
    switch (role) {
      case Mg24SensorRole.forehead:
        return _state.forehead;
      case Mg24SensorRole.belly:
        return _state.belly;
    }
  }

  BlePacketLossEstimator _packetLossEstimatorFor(Mg24SensorRole role) {
    return switch (role) {
      Mg24SensorRole.forehead => _foreheadPacketLoss,
      Mg24SensorRole.belly => _bellyPacketLoss,
    };
  }

  void _emit(Mg24State state) {
    _state = state;
    onState(state);
  }

  String _connectedStatus() {
    final foreheadData = _state.forehead.hasData;
    final bellyData = _state.belly.hasData;
    if (foreheadData && bellyData) {
      return 'XIAO MG24 Daten aktiv: Stirn und Bauch';
    }
    if (_state.hasPair) {
      return 'XIAO MG24 verbunden: warte auf Daten ...';
    }
    if (foreheadData) return 'XIAO MG24 Daten aktiv: Stirn';
    if (bellyData) return 'XIAO MG24 Daten aktiv: Bauch';
    if (_state.forehead.connected) return 'XIAO MG24 verbunden: Stirn wartet';
    if (_state.belly.connected) return 'XIAO MG24 verbunden: Bauch wartet';
    return 'XIAO MG24 nicht verbunden';
  }

  String _connectAttemptStatus({
    required bool expectedForehead,
    required bool expectedBelly,
  }) {
    final foreheadData = _state.forehead.hasData;
    final bellyData = _state.belly.hasData;
    if (foreheadData && bellyData) return _connectedStatus();

    final missing = [
      if (expectedForehead && !foreheadData) Mg24SensorRole.forehead.label,
      if (expectedBelly && !bellyData) Mg24SensorRole.belly.label,
    ].join(' und ');
    if (missing.isEmpty) return _connectedStatus();
    if (foreheadData || bellyData) {
      final active = [
        if (foreheadData) Mg24SensorRole.forehead.label,
        if (bellyData) Mg24SensorRole.belly.label,
      ].join(' und ');
      return '$active verbunden. $missing wurde nicht gefunden oder liefert keine Daten.';
    }
    return '$missing wurde nicht gefunden oder liefert keine Daten.';
  }

  String _friendlyMg24ConnectError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.replaceFirst('StateError: ', '');
  }

  _Mg24Candidate? _candidateFor(
    List<_Mg24Candidate> candidates,
    Mg24SensorRole role, {
    String? preferredRemoteId,
  }) {
    final preferred = preferredRemoteId?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      for (final candidate in candidates) {
        if (candidate.role == role &&
            candidate.device.remoteId.toString() == preferred) {
          return candidate;
        }
      }
    }
    for (final candidate in candidates) {
      if (candidate.role == role) return candidate;
    }
    return null;
  }

  List<_Mg24Candidate> _selectedCandidates(
    List<_Mg24Candidate> candidates, {
    required bool needsForehead,
    required bool needsBelly,
    required Map<Mg24SensorRole, String> preferredRemoteIds,
  }) {
    final forehead = needsForehead
        ? _candidateFor(
            candidates,
            Mg24SensorRole.forehead,
            preferredRemoteId: preferredRemoteIds[Mg24SensorRole.forehead],
          )
        : null;
    final belly = needsBelly
        ? _candidateFor(
            candidates,
            Mg24SensorRole.belly,
            preferredRemoteId: preferredRemoteIds[Mg24SensorRole.belly],
          )
        : null;
    return [forehead, belly].whereType<_Mg24Candidate>().toList(growable: false)
      ..sort(_compareMg24ConnectOrder);
  }

  int _compareMg24ConnectOrder(_Mg24Candidate a, _Mg24Candidate b) {
    final roleOrder =
        _connectOrderForRole(a.role) - _connectOrderForRole(b.role);
    if (roleOrder != 0) return roleOrder;
    return b.rssi.compareTo(a.rssi);
  }

  int _connectOrderForRole(Mg24SensorRole role) {
    return switch (role) {
      Mg24SensorRole.belly => 0,
      Mg24SensorRole.forehead => 1,
    };
  }
}

Mg24SensorRole? parseMg24Role(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim().toLowerCase();
  if (text.isEmpty) return null;
  if (text.contains('forehead') ||
      text.contains('stirn') ||
      text.contains('front') ||
      text.contains('head')) {
    return Mg24SensorRole.forehead;
  }
  if (text.contains('belly') ||
      text.contains('bauch') ||
      text.contains('abdomen') ||
      text.contains('chest') ||
      text.contains('brust')) {
    return Mg24SensorRole.belly;
  }
  return null;
}

typedef VoidCallback = void Function();

class _BlePacketLossObservation {
  const _BlePacketLossObservation({
    required this.receivedAt,
    required this.expectedPackets,
    required this.missingPackets,
  });

  final DateTime receivedAt;
  final int expectedPackets;
  final int missingPackets;
}

class BlePacketLossEstimator {
  BlePacketLossEstimator({
    int minimumExpectedPackets = mg24SamplingRate,
  }) : _minimumExpectedPackets = minimumExpectedPackets;

  static const _window = Duration(seconds: 20);
  static const _sequenceModulus = 0x100000000;

  final int _minimumExpectedPackets;

  final Queue<_BlePacketLossObservation> _observations =
      Queue<_BlePacketLossObservation>();
  int? _lastPacketSequence;
  int _expectedPackets = 0;
  int _missingPackets = 0;

  double? update({
    required int? packetSequence,
    required DateTime receivedAt,
  }) {
    if (packetSequence == null || packetSequence < 0) return null;

    final current = packetSequence & 0xffffffff;
    final previous = _lastPacketSequence;
    _lastPacketSequence = current;
    if (previous == null) return null;

    final delta = current >= previous
        ? current - previous
        : _sequenceModulus - previous + current;
    if (delta <= 0 || delta > 500) {
      reset();
      _lastPacketSequence = current;
      return null;
    }

    final expected = delta;
    final missing = math.max(0, expected - 1).toInt();
    _observations.addLast(_BlePacketLossObservation(
      receivedAt: receivedAt,
      expectedPackets: expected,
      missingPackets: missing,
    ));
    _expectedPackets += expected;
    _missingPackets += missing;
    _prune(receivedAt);
    return _current;
  }

  double? get _current {
    if (_expectedPackets < _minimumExpectedPackets) return null;
    return (100 * _missingPackets / _expectedPackets)
        .clamp(0.0, 100.0)
        .toDouble();
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(_window);
    while (_observations.isNotEmpty &&
        _observations.first.receivedAt.isBefore(cutoff)) {
      final removed = _observations.removeFirst();
      _expectedPackets -= removed.expectedPackets;
      _missingPackets -= removed.missingPackets;
    }
  }

  void reset() {
    _observations.clear();
    _lastPacketSequence = null;
    _expectedPackets = 0;
    _missingPackets = 0;
  }
}

class _Mg24ConnectCancelled implements Exception {
  const _Mg24ConnectCancelled();
}

class _Mg24Candidate {
  const _Mg24Candidate({
    required this.role,
    required this.device,
    required this.label,
    required this.rssi,
  });

  final Mg24SensorRole role;
  final BluetoothDevice device;
  final String label;
  final int rssi;
}

class _Mg24Connection {
  _Mg24Connection({
    required this.device,
    required this.controlReadyAt,
    required this.characteristic,
    required this.notifySubscription,
    required this.extraCharacteristics,
    required this.extraNotifySubscriptions,
    required this.controlCharacteristic,
    required this.summaryCharacteristic,
    required this.waveformCharacteristic,
    required this.archiveCharacteristic,
    required this.connectionSubscription,
    required this.dataWatchdog,
    required this.rssiMonitor,
  });

  final BluetoothDevice device;
  DateTime controlReadyAt;
  final BluetoothCharacteristic characteristic;
  final StreamSubscription<List<int>> notifySubscription;
  final List<BluetoothCharacteristic> extraCharacteristics;
  final List<StreamSubscription<List<int>>> extraNotifySubscriptions;
  final BluetoothCharacteristic? controlCharacteristic;
  final BluetoothCharacteristic? summaryCharacteristic;
  final BluetoothCharacteristic? waveformCharacteristic;
  final BluetoothCharacteristic? archiveCharacteristic;
  final StreamSubscription<BluetoothConnectionState> connectionSubscription;
  final Timer dataWatchdog;
  final Timer rssiMonitor;

  void deferControlUntil(DateTime readyAt) {
    if (readyAt.isAfter(controlReadyAt)) controlReadyAt = readyAt;
  }

  Future<void> close() async {
    dataWatchdog.cancel();
    rssiMonitor.cancel();
    await notifySubscription.cancel();
    for (final subscription in extraNotifySubscriptions) {
      await subscription.cancel();
    }
    await connectionSubscription.cancel();
    try {
      if (device.isConnected && characteristic.isNotifying) {
        await characteristic
            .setNotifyValue(false)
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {}
    for (final extra in extraCharacteristics) {
      try {
        if (device.isConnected && extra.isNotifying) {
          await extra.setNotifyValue(false).timeout(const Duration(seconds: 4));
        }
      } catch (_) {}
    }
    try {
      if (device.isConnected) {
        await device.disconnect(
          queue: false,
          timeout: 8,
          androidDelay: 2000,
        );
      }
    } catch (_) {}
  }
}

double? _readDouble(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    final parsed = _toDouble(value);
    if (parsed != null) return parsed;
  }
  return null;
}

int? _readInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

bool? _readBool(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true' || text == '1' || text == 'yes') return true;
      if (text == 'false' || text == '0' || text == 'no') return false;
    }
  }
  return null;
}

bool? _readDelimitedBool(double? value) {
  if (value == null || !value.isFinite) return null;
  return value != 0;
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.replaceAll(',', '.'));
  return null;
}

List<double>? _numList(Object? value) {
  if (value is! List) return null;
  return value.map(_toDouble).whereType<double>().toList(growable: false);
}

double? _listAt(List<double>? values, int index) {
  if (values == null || index >= values.length) return null;
  return values[index];
}

double? _positive(double? value) {
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}

double? _percent(double? value) {
  if (value == null || !value.isFinite || value <= 0) return null;
  return value.clamp(0.0, 100.0).toDouble();
}

double? _clampedPercent(double? value) {
  if (value == null || !value.isFinite) return null;
  return value.clamp(0.0, 100.0).toDouble();
}

double _snoreRmsDbFromVolume(double volumePercent) {
  final volume =
      volumePercent.isFinite ? volumePercent.clamp(0.0, 100.0).toDouble() : 0.0;
  return -70.0 + volume * 0.70;
}
