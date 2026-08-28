import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bitalino/bitalino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'android_network.dart';
import 'app_monotonic_clock.dart';
import 'models.dart';
import 'measurement_foreground_service.dart';
import 'mg24_audio_snore_detector.dart';
import 'mg24_sensor_client.dart';
import 'mg24_protocol.dart';
import 'processing.dart';
import 'radar_client.dart';
import 'sleep_journal.dart';
import 'snore_teacher_sync.dart';
import 'yamnet_snore_detector.dart';
import 'yamnet_raw_snore_tracker.dart';

enum HeartBreathSource {
  bitalino,
  mg24,
  radar,
  demo,
}

@immutable
class SnoreTrainingRecording {
  const SnoreTrainingRecording({
    required this.fileName,
    required this.label,
    required this.recordedAt,
    required this.sizeBytes,
  });

  final String fileName;
  final String label;
  final DateTime recordedAt;
  final int sizeBytes;
}

final _inactiveOrientationState = OrientationState(
  foreheadAngleDeg: double.nan,
  chestAngleDeg: double.nan,
  relativeAngleDeg: double.nan,
);
const _streamingPublishInterval = Duration(milliseconds: 40);
const _mg24SnoreToBreathingPlotOffsetSeconds = 0.0;

const _snoreTrainingColumns = [
  'timestamp',
  'row_type',
  'label',
  'manual_window',
  'manual_window_id',
  'manual_window_elapsed_s',
  'uptime_s',
  'snoring',
  'score_percent',
  'volume_percent',
  'level_ratio_percent',
  'low_ratio_percent',
  'crossing_rate_percent',
  'raw_swing',
  'pattern_quality_percent',
  'snore_rate_per_min',
  'snore_breath_width_ms',
  'burst_counter',
  'snore_burst_active',
  'snore_burst_age_ms',
  'snore_active_width_ms',
  'rms_db',
  'audio_band_0_150_percent',
  'audio_band_150_300_percent',
  'audio_band_300_600_percent',
  'audio_band_600_1200_percent',
  'audio_band_1200_3000_percent',
  'envelope_lift',
  'crest_factor',
  'modulation_percent',
  'snore_block_score_percent',
  'continuation_score_percent',
  'audio_contact_artifact',
  'motion_artifact',
  'mg24_app_raw_score_percent',
  'mg24_app_smoothed_score_percent',
  'mg24_app_snoring',
  'mg24_app_burst_counter',
  'mg24_app_burst_active',
  'mg24_app_burst_age_ms',
  'mg24_app_active_width_ms',
  'mg24_app_snore_rate_per_min',
  'yamnet_raw_score_percent',
  'yamnet_smoothed_score_percent',
  'yamnet_raw_snore',
  'yamnet_held_snore',
  'yamnet_inference_id',
  'yamnet_window_center_age_ms',
  'yamnet_rms_db',
  'yamnet_teacher_window',
  'yamnet_teacher_window_id',
  'yamnet_teacher_window_age_ms',
  'yamnet_teacher_window_width_ms',
  'yamnet_teacher_snore_rate_per_min',
];

const _snoreMelBandsPerSlice = Mg24MelFeaturePacket.bandsPerSlice;
const _snoreMelSlicesPerPacket = Mg24MelFeaturePacket.maximumSlices;
const _snoreMelPreflightDuration = Duration(milliseconds: 2500);
const _snoreMelInitialPacketTimeout = Duration(seconds: 16);
const _snoreMelRetryPacketTimeout = Duration(seconds: 8);
const _snoreMelMinimumPreflightRate = 85.0;
const _snoreMelMaximumPreflightRetries = 2;

List<String> _snoreMelTrainingColumns() => [
      'received_at',
      'estimated_first_frame_at',
      'label',
      'manual_window',
      'manual_window_id',
      'packet_sequence',
      'first_frame_sequence',
      'frame_period_us',
      'slice_count',
      'model_score_percent',
      'model_state',
      'model_frame_sequence',
      'first_frame_monotonic_us',
      'teacher_slice_mask',
      'teacher_window_ids',
      'teacher_sync_method',
      'teacher_sync_error_ms',
      for (var slice = 0; slice < _snoreMelSlicesPerPacket; slice++)
        for (var band = 0; band < _snoreMelBandsPerSlice; band++)
          'mel_${slice}_$band',
    ];

const _homeSnorePhaseHoldDuration = Duration(seconds: 10);

class MeasurementController extends ChangeNotifier {
  MeasurementSnapshot snapshot = MeasurementSnapshot.initial();

  bool useDemoData = false;
  bool useRadarData = false;
  bool useMg24Data = true;
  bool usePositionData = true;
  bool snoreEnabled = true;
  bool yamnetMeasurementEnabled = true;
  bool measurementStartSignalEnabled = true;
  Mg24LiveMode mg24LiveMode = Mg24LiveMode.valuesOnly;
  String radarHost = radarDefaultHost;
  bool scanningDevices = false;
  List<BITalinoDevice> availableDevices = const [];
  BITalinoDevice? selectedDevice;
  List<SleepQuestion> customSleepQuestions = const [];
  List<SleepSessionRecord> sleepHistory = const [];
  Set<String> _selectedCorrelationRecordIds = const {};
  Set<String> _knownCorrelationRecordIds = const {};
  SleepSessionRecord? latestSleepSession;
  SleepJournalSummary sleepSummary = const SleepJournalSummary.empty();
  List<SleepCorrelation> sleepCorrelations = const [];
  List<SleepQuestionPhysiologyCorrelation> sleepQuestionPhysiologyCorrelations =
      const [];
  List<String> personalizedSleepTips = const [
    'Nach einigen Naechten erkennt LASLI persoenliche Muster und zeigt hier konkretere Tipps.',
  ];

  HeartRateDetector? _heartDetector;
  BreathingRateDetector? _breathingDetector;
  ImuBreathingRateDetector? _mg24BreathingDetector;
  final ImuSnoreVibrationDetector _imuSnoreVibrationDetector =
      ImuSnoreVibrationDetector(mg24SamplingRate);
  OrientationEstimator? _orientationEstimator;
  CsvWindowAggregator? _csvAggregator;
  AudioSnoreDetector? _snoreDetector;
  final Mg24AudioFeatureSnoreDetector _mg24AudioSnoreDetector =
      Mg24AudioFeatureSnoreDetector();
  final YamnetRawSnoreTracker _yamnetRawSnoreTracker = YamnetRawSnoreTracker();
  final SnoreTeacherSynchronizer _snoreTeacherSynchronizer =
      SnoreTeacherSynchronizer();
  bool _snoreTrainingOwnsSnoreDetector = false;
  bool _snoreTrainingForcedValuesOnly = false;
  bool _snoreAutomaticTeacherMode = false;
  bool _developerYamnetMonitorActive = false;
  bool _developerYamnetMonitorStartInProgress = false;
  bool _mg24YamnetTeacherActive = false;
  bool _mg24YamnetTeacherStartInProgress = false;
  BITalinoController? _bitalinoController;
  Mg24SensorClient? _mg24Client;
  RadarSensorClient? _radarClient;
  Timer? _demoTimer;
  Timer? _radarTimer;
  Timer? _mg24ReconnectTimer;
  IOSink? _csvSink;
  File? _csvFile;
  IOSink? _snoreTrainingSink;
  File? _snoreTrainingFile;
  IOSink? _snoreMelTrainingSink;
  File? _snoreMelTrainingFile;
  IOSink? _yamnetTeacherSink;
  String? _snoreTrainingLabel;
  List<SnoreTrainingRecording> _snoreTrainingRecordings = const [];
  bool _snoreTrainingRecordingsLoading = false;
  bool _snoreTrainingWindowActive = false;
  DateTime? _snoreTrainingWindowStartedAt;
  int _snoreTrainingWindowId = 0;
  int _snoreTrainingSampleCount = 0;
  int _snoreTrainingCompleteFeatureCount = 0;
  int _snoreMelPacketCount = 0;
  int _snoreMelSliceCount = 0;
  int _snoreMelDroppedSliceCount = 0;
  int? _lastSnoreMelFrameSequence;
  bool _snoreMelTransportReady = false;
  DateTime? _snoreMelPreflightStartedAt;
  int _snoreMelPreflightSliceCount = 0;
  int _snoreMelPreflightDroppedSliceCount = 0;
  int? _lastSnoreMelPreflightFrameSequence;
  int _snoreMelPreflightRetryCount = 0;
  bool _snoreMelTransportRecoveryInProgress = false;
  Timer? _snoreMelPreflightTimeoutTimer;
  int _snoreMelTransportGeneration = 0;
  int? _latestSnoreMelModelScorePercent;
  bool _latestSnoreMelModelActive = false;
  bool _latestSnoreMelModelTrusted = false;
  int? _snoreAutomaticTrainingStartedUs;
  int? _snoreAutomaticTrainingStoppedUs;
  final List<_AutomaticTeacherWindow> _snoreAutomaticTeacherWindows =
      <_AutomaticTeacherWindow>[];
  final List<YamnetRawSnoreWindow> _measurementYamnetWindows =
      <YamnetRawSnoreWindow>[];
  final Queue<YamnetRawSnoreWindow> _liveYamnetWindows =
      Queue<YamnetRawSnoreWindow>();
  bool _measurementYamnetCaptureActive = false;
  bool _measurementYamnetWasRecorded = false;
  SnoreState _latestBoardSnore = const SnoreState.empty();
  bool _measurementForegroundOwner = false;
  bool _trainingForegroundOwner = false;
  bool _yamnetMonitorForegroundOwner = false;
  bool _measurementForegroundUsesMicrophone = false;
  bool _measurementForegroundUsesConnectedDevice = false;
  bool _mg24ReconnectInProgress = false;
  bool _mg24ConnectInProgress = false;
  bool _mg24DisconnectInProgress = false;
  bool _mg24ReconnectSuppressed = false;
  int _mg24ConnectionOperation = 0;
  bool _batteryOptimizationPromptShown = false;
  bool _mg24PoseCalibrationPending = false;
  DateTime? _mg24PoseCalibrationRequestedAt;
  final Set<Mg24SensorRole> _mg24PoseCalibrationFreshRolesPending =
      <Mg24SensorRole>{};
  int _mg24PoseCalibrationEpochCounter = 0;
  int _foreheadPoseCalibrationEpoch = 0;
  int _bellyPoseCalibrationEpoch = 0;
  int _mg24ConnectionLossCount = 0;
  DateTime? _lastMg24ConnectionLostAt;
  Set<Mg24SensorRole> _mg24MeasurementRoles = const {};
  Map<Mg24SensorRole, String> _persistedMg24RemoteIds = const {};
  int? _activeBoardSessionId;

  final Queue<SignalSample> _samples = Queue<SignalSample>();
  final Queue<PlotPoint> _rPeaks = Queue<PlotPoint>();
  final Queue<PlotPoint> _breathPeaks = Queue<PlotPoint>();
  final Queue<int> _mg24BreathSignalSequences = Queue<int>();
  final Map<int, PlotPoint> _mg24BreathSignalBySequence = <int, PlotPoint>{};
  final Queue<int> _mg24BreathPeakSequences = Queue<int>();
  final Set<int> _mg24BreathPeakSequenceSet = <int>{};
  final Queue<int> _mg24PendingBreathPeakSequences = Queue<int>();
  final Map<int, double> _mg24PendingBreathPeaks = <int, double>{};
  final Queue<Mg24EventRecord> _liveMg24BreathEvents = Queue<Mg24EventRecord>();
  final List<_LiveMg24SnoreAssessment> _liveMg24SnoreAssessments =
      <_LiveMg24SnoreAssessment>[];
  double? _lastLiveMg24BreathPeakTimeS;
  final Queue<TimeWindow> _snoreBreathWindows = Queue<TimeWindow>();
  final Queue<TimeWindow> _recentConfirmedSnoreBreathWindows =
      Queue<TimeWindow>();
  final Queue<_Mg24SnoreTimingWindow> _scheduledSnoreBreathWindows =
      Queue<_Mg24SnoreTimingWindow>();
  final Queue<_Mg24SnoreTimingWindow> _pendingMg24SnoreTimingWindows =
      Queue<_Mg24SnoreTimingWindow>();
  final Map<Mg24SensorRole, _Mg24SensorClockMapper> _mg24SensorClocks = {
    Mg24SensorRole.forehead: _Mg24SensorClockMapper(),
    Mg24SensorRole.belly: _Mg24SensorClockMapper(),
  };
  _Mg24SnoreTimingWindow? _activeMg24SnoreTimingWindow;
  int? _lastRecordedMg24SnoreBurstCounter;
  double? _mg24BellyPlotAnchorTimeS;
  int? _mg24BellyPlotAnchorSequence;
  double? _mg24BellyPlotSamplePeriodS;
  DateTime? _mg24BellyPlotAnchorAt;
  final List<SnoreTimelineSegment> _snoreTimeline = [];
  final math.Random _random = math.Random(17);
  final SleepMeasurementStats _sleepStats = SleepMeasurementStats();

  int _sampleNumber = 0;
  int _rPeakCount = 0;
  int _breathCount = 0;
  int _mg24ReconnectAttempts = 0;
  double? _heartRate;
  double? _breathingRate;
  double? _mg24BreathingRate;
  double? _mg24BreathingSignal;
  String? _mg24BreathingAxis;
  double? _mg24BreathingQuality;
  double? _oxygenSaturation;
  RadarState _radar = const RadarState.empty();
  Mg24State _rawMg24 = const Mg24State.empty();
  Mg24State _mg24 = const Mg24State.empty();
  _Mg24PoseCalibration? _foreheadPoseCalibration;
  _Mg24PoseCalibration? _bellyPoseCalibration;
  double _foreheadYawCorrectionDeg = 0;
  double _bellyYawCorrectionDeg = 0;
  final _Mg24RelativeYawEstimator _mg24RelativeYawEstimator =
      _Mg24RelativeYawEstimator();
  OrientationState _orientation = const OrientationState.empty();
  SnoreState _snore = const SnoreState.empty();
  DateTime? _activeSnoreStartedAt;
  String _activeSnoreSource = 'unknown';
  double _activeSnoreSourceConfidence = 0;
  final Queue<_SnoreBreathEvidence> _snoreBreathEvidence =
      Queue<_SnoreBreathEvidence>();
  int? _lastSnoreSourceInferenceId;
  DateTime? _lastSnoreSourceActivityAt;
  String _snoreSource = 'unknown';
  double _snoreSourceConfidence = 0;
  String _confirmedSnoreSource = 'unknown';
  double _confirmedSnoreSourceConfidence = 0;
  DateTime? _confirmedSnoreSourceAt;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _measurementStartedAt;
  DateTime? _measurementScheduledStartAt;
  DateTime? _mg24LiveStartedAt;
  DateTime? _sleepCycleStartedAt;
  DateTime? _sleepCycleEndedAt;
  Map<String, int>? _pendingEveningAnswers;
  SleepMeasurementSummary? _pendingRecoveredBoardSummary;
  Future<void>? _sleepJournalInitialization;
  bool _stopInProgress = false;
  bool _measurementArmed = false;
  bool _scheduledMeasurementCancelPending = false;
  bool _armedCancellationInProgress = false;
  Set<Mg24SensorRole> _pendingBoardStopRoles = const {};
  Timer? _restoredArmedStartTimer;
  Set<Mg24SensorRole> _deferredBoardStopRoles = const {};
  Map<Mg24SensorRole, String> _deferredBoardStopRemoteIds = const {};
  Map<Mg24SensorRole, int> _deferredBoardStopSessionIds = const {};
  bool _deferredBoardStopInProgress = false;
  String? _minuteArchiveWarning;

  bool get running => snapshot.running;
  bool get boardRecording {
    bool isRecording(Mg24State state) =>
        state.forehead.recording == true || state.belly.recording == true;
    return isRecording(snapshot.mg24) ||
        isRecording(_mg24) ||
        isRecording(_rawMg24);
  }

  bool get measurementActive => running || boardRecording || _measurementArmed;
  bool get measurementArmed => _measurementArmed;
  DateTime? get measurementScheduledStartAt => _measurementScheduledStartAt;
  bool get stopping => _stopInProgress;
  bool get mg24Connecting => _mg24ConnectInProgress;
  bool get mg24Disconnecting => _mg24DisconnectInProgress;
  bool get hasRecoverableBoardArchive =>
      !measurementActive &&
      _mg24Client != null &&
      ((_mg24.forehead.archiveRecords ?? 0) > 0 ||
          (_mg24.belly.archiveRecords ?? 0) > 0);
  bool get hasPendingSleepSession =>
      _pendingEveningAnswers != null && _sleepCycleStartedAt != null;
  bool get sleepSessionReadyForJournal =>
      hasPendingSleepSession &&
      (!useMg24Data ||
          _activeBoardSessionId == null ||
          _pendingRecoveredBoardSummary != null);
  bool get hasPendingBoardArchiveRecovery =>
      hasPendingSleepSession &&
      !measurementActive &&
      useMg24Data &&
      _activeBoardSessionId != null &&
      _pendingRecoveredBoardSummary == null;
  bool get canRecoverPendingBoardArchive =>
      hasPendingBoardArchiveRecovery &&
      !_stopInProgress &&
      _mg24Client != null &&
      requiredMeasurementSensorsConnected;
  bool get canStartMg24Measurement =>
      !measurementActive && !hasPendingSleepSession && _mg24.hasAnyData;
  Set<Mg24SensorRole> get connectedMeasurementSensorRoles => Set.unmodifiable({
        if (_mg24.forehead.hasData) Mg24SensorRole.forehead,
        if (_mg24.belly.hasData) Mg24SensorRole.belly,
      });
  bool get requiredMeasurementSensorsConnected {
    final roles = _mg24MeasurementRoles;
    if (roles.isEmpty) return _mg24.hasAnyData;
    for (final role in roles) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      if (!sensor.hasData) return false;
    }
    return true;
  }

  bool get canStopMeasurement =>
      measurementActive &&
      !_stopInProgress &&
      (_measurementArmed ||
          !useMg24Data ||
          requiredMeasurementSensorsConnected);

  bool isMeasurementSensor(Mg24SensorRole role) =>
      _mg24MeasurementRoles.contains(role);

  bool boardHasActiveMeasurementSession(Mg24SensorRole role) {
    final sessionId = _activeBoardSessionId;
    if (sessionId == null) return false;
    final sensor = switch (role) {
      Mg24SensorRole.forehead => _mg24.forehead,
      Mg24SensorRole.belly => _mg24.belly,
    };
    return sensor.recording == true && sensor.sessionId == (sessionId & 0xffff);
  }

  List<String> get missingMeasurementSensorLabels {
    final missing = <String>[];
    for (final role in {
      ..._mg24MeasurementRoles,
      ..._deferredBoardStopRoles,
    }) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      if (!sensor.hasData) missing.add(role.label);
    }
    return List<String>.unmodifiable(missing);
  }

  bool get snoreTrainingActive => _snoreTrainingSink != null;
  bool get snoreAutomaticTeacherMode => _snoreAutomaticTeacherMode;
  bool get developerYamnetMonitorActive => _developerYamnetMonitorActive;
  bool get developerYamnetMonitorStartInProgress =>
      _developerYamnetMonitorStartInProgress;
  bool get boardSnoreDetected =>
      _latestBoardSnore.isSnoring || _latestBoardSnore.snoreBurstActive;
  double get boardSnoreScorePercent =>
      (_latestBoardSnore.score * 100).clamp(0.0, 100.0).toDouble();
  bool? get yamnetSnoreDetected =>
      _snoreDetector == null ? null : _yamnetRawSnoreTracker.snapshot.active;
  double? get yamnetSnoreScorePercent => _snoreDetector == null
      ? null
      : (_snoreDetector!.rawScore * 100).clamp(0.0, 100.0).toDouble();
  double? get yamnetBreathingScorePercent => _snoreDetector?.classScores == null
      ? null
      : (_snoreDetector!.classScores!.breathing * 100)
          .clamp(0.0, 100.0)
          .toDouble();
  double? get yamnetWindScorePercent => _snoreDetector?.classScores == null
      ? null
      : (_snoreDetector!.classScores!.windLike * 100)
          .clamp(0.0, 100.0)
          .toDouble();
  double? get yamnetVoiceScorePercent => _snoreDetector?.classScores == null
      ? null
      : (_snoreDetector!.classScores!.voiceLike * 100)
          .clamp(0.0, 100.0)
          .toDouble();
  double? get yamnetInputGainDb => _snoreDetector?.inputGainDb;
  String? get yamnetRejectionReason => _snoreDetector?.rejectionReason;
  int get automaticTeacherWindowCount =>
      _snoreAutomaticTeacherWindows.length +
      (_yamnetRawSnoreTracker.snapshot.active ? 1 : 0);
  SnoreTeacherSyncEstimate get snoreTeacherSyncEstimate =>
      _snoreTeacherSynchronizer.estimate;
  String? get snoreTrainingLabel => _snoreTrainingLabel;
  bool get snoreTrainingWindowActive => _snoreTrainingWindowActive;
  int get snoreTrainingWindowId => _snoreTrainingWindowId;
  int get snoreTrainingSampleCount => _snoreTrainingSampleCount;
  int get snoreTrainingCompleteFeatureCount =>
      _snoreTrainingCompleteFeatureCount;
  int get snoreMelPacketCount => _snoreMelPacketCount;
  int get snoreMelSliceCount => _snoreMelSliceCount;
  int get snoreMelDroppedSliceCount => _snoreMelDroppedSliceCount;
  bool get snoreMelTransportReady => _snoreMelTransportReady;
  int get snoreMelPreflightSliceCount => _snoreMelPreflightSliceCount;
  int get snoreMelPreflightRetryCount => _snoreMelPreflightRetryCount;
  int? get latestSnoreMelModelScorePercent => _latestSnoreMelModelScorePercent;
  bool get latestSnoreMelModelActive => _latestSnoreMelModelActive;
  bool get latestSnoreMelModelTrusted => _latestSnoreMelModelTrusted;
  List<SnoreTrainingRecording> get snoreTrainingRecordings =>
      List<SnoreTrainingRecording>.unmodifiable(_snoreTrainingRecordings);
  bool get snoreTrainingRecordingsLoading => _snoreTrainingRecordingsLoading;

  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    // Home, screen-off and the app switcher only pause the Flutter UI. Keep
    // Android's GATT session alive so returning to LASLI cannot race a
    // background disconnect. While no measurement is running, switch the
    // board sensors off so a kept BLE link does not keep IMU/audio awake.
    if (state == AppLifecycleState.resumed) {
      if (!measurementActive && !snoreTrainingActive) {
        await _setMg24SensorsEnabledForLiveView(true);
      }
      return;
    }
    if (state == AppLifecycleState.detached) {
      if (running && useMg24Data) {
        // The boards own the overnight recording. Closing the Flutter process
        // must only release BLE; the persisted session is stopped explicitly
        // after all participating boards have been reconnected.
        await disconnectMg24Sensors();
      } else if (running) {
        await stop(status: 'App geschlossen. Messung gestoppt.');
      } else if (boardRecording) {
        return;
      } else if (_mg24.connected || _mg24.scanning || _mg24Client != null) {
        await disconnectMg24Sensors();
      }
      return;
    }
    if (!measurementActive && !snoreTrainingActive) {
      await _setMg24SensorsEnabledForLiveView(false);
    }
  }

  Future<void> _setMg24SensorsEnabledForLiveView(bool enabled) async {
    final client = _mg24Client;
    if (client == null || !_mg24.connected) return;
    try {
      await client
          .setSensorsEnabled(enabled)
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  HeartBreathSource get heartBreathSource {
    if (useDemoData) return HeartBreathSource.demo;
    if (useMg24Data) return HeartBreathSource.mg24;
    if (useRadarData) return HeartBreathSource.radar;
    return HeartBreathSource.mg24;
  }

  bool get needsBitalinoDevice => false;

  bool get showsPositionData => useDemoData || usePositionData || useMg24Data;

  List<SleepQuestion> get sleepQuestions =>
      [...defaultSleepQuestions, ...customSleepQuestions];

  Set<String> get selectedCorrelationRecordIds =>
      Set<String>.unmodifiable(_selectedCorrelationRecordIds);

  List<SleepSessionRecord> get selectedCorrelationSleepHistory => sleepHistory
      .where((record) => _selectedCorrelationRecordIds.contains(record.id))
      .toList(growable: false);

  bool get supportsBitalinoHardware => Platform.isAndroid || Platform.isIOS;

  CommunicationType get automaticCommunicationType =>
      Platform.isIOS ? CommunicationType.BLE : CommunicationType.BTH;

  Future<void> initializeSleepJournal() {
    return _sleepJournalInitialization ??= _initializeSleepJournal();
  }

  Future<void> _initializeSleepJournal() async {
    customSleepQuestions = await _loadCustomSleepQuestions();
    final loadedSleepHistory = await _loadSleepHistory();
    final deduplicatedSleepHistory = _deduplicateSleepHistory(
      loadedSleepHistory,
    );
    final repairedSleepHistory = await _repairBoardArchiveTimeBounds(
      deduplicatedSleepHistory,
    );
    sleepHistory = repairedSleepHistory.records;
    if (sleepHistory.length != loadedSleepHistory.length ||
        repairedSleepHistory.changed) {
      await _saveSleepHistory();
      await _rewriteSleepSessionsCsv();
    }
    await _loadMeasurementSettings();
    await _loadDeferredBoardStops();
    await _loadCorrelationNightSelection();
    await _restoreActiveMeasurementSession();
    _refreshSleepAnalysis();
    notifyListeners();
  }

  Future<void> requestInitialPlatformPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      if (Platform.isAndroid) {
        await [
          Permission.bluetoothConnect,
          Permission.bluetoothScan,
          Permission.locationWhenInUse,
          Permission.microphone,
          Permission.notification,
        ].request();
      } else {
        await [Permission.bluetooth, Permission.microphone].request();
      }
    } catch (_) {
      // Permission requests are repeated by the relevant feature when needed.
    }
    if (Platform.isAndroid) {
      await _requestInitialBatteryOptimizationExemption();
    }
  }

  Future<void> _requestInitialBatteryOptimizationExemption() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final marker = File(
        '${directory.path}${Platform.pathSeparator}.battery_optimization_prompted',
      );
      if (await marker.exists()) return;
      await marker.writeAsString(DateTime.now().toIso8601String(), flush: true);

      final alreadyAllowed =
          await MeasurementForegroundService.isIgnoringBatteryOptimizations();
      if (alreadyAllowed) return;
      _batteryOptimizationPromptShown = true;
      await MeasurementForegroundService.requestIgnoreBatteryOptimizations();
    } catch (_) {
      // Measurement start performs the same check again if startup was unable
      // to open Android's special-access dialog.
    }
  }

  Future<void> setCorrelationNightSelection(Set<String> recordIds) async {
    final available = sleepHistory.map((record) => record.id).toSet();
    final selected = recordIds.intersection(available);
    if (setEquals(selected, _selectedCorrelationRecordIds) &&
        setEquals(available, _knownCorrelationRecordIds)) {
      return;
    }
    _selectedCorrelationRecordIds = Set<String>.unmodifiable(selected);
    _knownCorrelationRecordIds = Set<String>.unmodifiable(available);
    await _saveCorrelationNightSelection();
    notifyListeners();
  }

  List<SleepQuestion> sleepQuestionsFor(SleepQuestionPhase phase) {
    return sleepQuestions
        .where((question) => question.phase == phase)
        .toList(growable: false);
  }

  Map<String, int> latestSleepAnswersFor(SleepQuestionPhase phase) {
    final questionIds =
        sleepQuestionsFor(phase).map((question) => question.id).toSet();
    final answers = <String, int>{};
    for (final record in sleepHistory) {
      for (final questionId in questionIds) {
        if (!answers.containsKey(questionId)) {
          final value = record.answers[questionId];
          if (value != null) answers[questionId] = value;
        }
      }
      if (answers.length == questionIds.length) break;
    }
    return answers;
  }

  Future<void> addCustomSleepQuestion({
    required String title,
    required SleepQuestionPhase phase,
    required SleepQuestionType type,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return;

    final question = SleepQuestion(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      title: cleanTitle,
      prompt: cleanTitle,
      phase: phase,
      type: type,
      isCustom: true,
      lowLabel: type == SleepQuestionType.scale ? 'niedrig' : null,
      highLabel: type == SleepQuestionType.scale ? 'hoch' : null,
    );
    customSleepQuestions = [...customSleepQuestions, question];
    await _saveCustomSleepQuestions();
    _refreshSleepAnalysis();
    notifyListeners();
  }

  Future<void> removeCustomSleepQuestion(String id) async {
    customSleepQuestions = customSleepQuestions
        .where((question) => question.id != id)
        .toList(growable: false);
    await _saveCustomSleepQuestions();
    _refreshSleepAnalysis();
    notifyListeners();
  }

  void prepareSleepSession(Map<String, int> eveningAnswers) {
    _pendingEveningAnswers = Map<String, int>.from(eveningAnswers);
  }

  Future<SleepSessionRecord?> completeSleepSession(
    Map<String, int> morningAnswers,
  ) async {
    final eveningAnswers = _pendingEveningAnswers;
    final startedAt = _sleepCycleStartedAt;
    final endedAt = _sleepCycleEndedAt ?? DateTime.now();
    if (eveningAnswers == null || startedAt == null) {
      snapshot = snapshot.copyWith(
        status: 'Kein offener Schlafzyklus zum Speichern gefunden.',
      );
      notifyListeners();
      return null;
    }
    if (useMg24Data &&
        _activeBoardSessionId != null &&
        _pendingRecoveredBoardSummary == null) {
      snapshot = snapshot.copyWith(
        status:
            'Das Board-Archiv muss vor der Journal-Uebernahme geladen werden.',
      );
      notifyListeners();
      return null;
    }

    final existingIndex = sleepHistory.indexWhere(
      (record) =>
          record.metrics.startedAt.difference(startedAt).abs() <
          const Duration(minutes: 1),
    );
    if (existingIndex >= 0) {
      final existing = sleepHistory[existingIndex];
      try {
        await _clearActiveMeasurementSession();
      } catch (_) {}
      _pendingEveningAnswers = null;
      _pendingRecoveredBoardSummary = null;
      _sleepCycleStartedAt = null;
      _sleepCycleEndedAt = null;
      _mg24MeasurementRoles = const {};
      _persistedMg24RemoteIds = const {};
      _activeBoardSessionId = null;
      snapshot = snapshot.copyWith(
        status: 'Diese Board-Messung ist bereits im Schlafjournal.',
      );
      notifyListeners();
      return existing;
    }

    final answers = <String, int>{
      ...eveningAnswers,
      ...morningAnswers,
    };
    final metrics = _pendingRecoveredBoardSummary ??
        _sleepStats.summary(startedAt: startedAt, endedAt: endedAt);
    final score = computeSleepScore(answers, metrics);
    var record = SleepSessionRecord(
      id: _timestamp(),
      createdAt: DateTime.now(),
      metrics: metrics,
      answers: answers,
      score: score,
      tips: const [],
      dataCsvPath: snapshot.csvPath,
    );

    final nextHistory = [record, ...sleepHistory];
    final nextCorrelations =
        computeSleepCorrelations(nextHistory, sleepQuestions);
    record = SleepSessionRecord(
      id: record.id,
      createdAt: record.createdAt,
      metrics: record.metrics,
      answers: record.answers,
      score: record.score,
      tips: buildSleepTips(record, nextCorrelations),
      dataCsvPath: record.dataCsvPath,
    );

    sleepHistory = [record, ...sleepHistory];
    await _syncCorrelationNightSelectionWithHistory();
    await _saveSleepHistory();
    await _appendSleepSessionCsv(record);
    try {
      await _clearActiveMeasurementSession();
    } catch (_) {}
    _pendingEveningAnswers = null;
    _pendingRecoveredBoardSummary = null;
    _sleepCycleStartedAt = null;
    _sleepCycleEndedAt = null;
    _mg24MeasurementRoles = const {};
    _persistedMg24RemoteIds = const {};
    _activeBoardSessionId = null;
    _refreshSleepAnalysis();
    snapshot = snapshot.copyWith(
      status:
          'Schlafzyklus gespeichert. Score: ${record.score.toStringAsFixed(0)}',
    );
    notifyListeners();
    return record;
  }

  Future<void> updateSleepSessionAnswers(
    String recordId,
    Map<String, int> additionalAnswers,
  ) async {
    if (additionalAnswers.isEmpty) return;
    final index = sleepHistory.indexWhere((record) => record.id == recordId);
    if (index < 0) return;
    final current = sleepHistory[index];
    final answers = <String, int>{
      ...current.answers,
      ...additionalAnswers,
    };
    var updated = SleepSessionRecord(
      id: current.id,
      createdAt: current.createdAt,
      metrics: current.metrics,
      answers: answers,
      score: computeSleepScore(answers, current.metrics),
      tips: const [],
      dataCsvPath: current.dataCsvPath,
    );
    final provisional = [...sleepHistory]..[index] = updated;
    final correlations = computeSleepCorrelations(provisional, sleepQuestions);
    updated = SleepSessionRecord(
      id: updated.id,
      createdAt: updated.createdAt,
      metrics: updated.metrics,
      answers: updated.answers,
      score: updated.score,
      tips: buildSleepTips(updated, correlations),
      dataCsvPath: updated.dataCsvPath,
    );
    sleepHistory = [...sleepHistory]..[index] = updated;
    await _saveSleepHistory();
    await _rewriteSleepSessionsCsv();
    _refreshSleepAnalysis();
    snapshot = snapshot.copyWith(
      status:
          'Schlafzyklus aktualisiert. Score: ${updated.score.toStringAsFixed(0)}',
    );
    notifyListeners();
  }

  Future<bool> deleteSleepSession(SleepSessionRecord record) async {
    if (!sleepHistory.any((entry) => entry.id == record.id)) return false;

    final remaining = sleepHistory
        .where((entry) => entry.id != record.id)
        .toList(growable: false);
    sleepHistory = remaining;
    await _syncCorrelationNightSelectionWithHistory();
    await _saveSleepHistory();
    await _rewriteSleepSessionsCsv();
    final deletedFiles = await _deleteSleepSessionDataFiles(record, remaining);
    _refreshSleepAnalysis();
    snapshot = snapshot.copyWith(
      status: deletedFiles == 0
          ? 'Schlafmessung aus dem Journal geloescht.'
          : 'Schlafmessung und $deletedFiles zugehoerige Dateien geloescht.',
    );
    notifyListeners();
    return true;
  }

  Future<void> refreshCsvInfo() async {
    final file = await _currentCsvFile();
    final dir = await _csvDirectory(create: true);
    if (file == null) {
      snapshot = snapshot.copyWith(
        fileLabel: 'Noch keine CSV-Datei',
        csvDirectoryPath: dir.path,
        clearCsvPath: true,
      );
    } else {
      snapshot = snapshot.copyWith(
        fileLabel: 'CSV: ${_fileName(file.path)}',
        csvPath: file.path,
        csvDirectoryPath: file.parent.path,
      );
    }
    notifyListeners();
  }

  Future<void> startSnoreTraining(String label) async {
    await _startSnoreTraining(label, automaticTeacher: false);
  }

  Future<void> startAutomaticYamnetTraining() async {
    await _startSnoreTraining('yamnet_teacher', automaticTeacher: true);
  }

  Future<void> _startSnoreTraining(
    String label, {
    required bool automaticTeacher,
  }) async {
    await stopSnoreTraining();
    final client = _mg24Client;
    if (client == null || !_mg24.forehead.connected) {
      snapshot = snapshot.copyWith(
        status: 'Audio-Training benoetigt einen verbundenen Stirn-MG24.',
      );
      notifyListeners();
      return;
    }
    _snoreAutomaticTeacherMode = automaticTeacher;
    _snoreAutomaticTrainingStartedUs = AppMonotonicClock.nowUs();
    _snoreAutomaticTrainingStoppedUs = null;
    _snoreAutomaticTeacherWindows.clear();
    _snoreTeacherSynchronizer.reset();
    _yamnetRawSnoreTracker.reset();
    final microphonePermissionGranted = await _ensureMicrophonePermission();
    if (!microphonePermissionGranted) {
      _snoreAutomaticTeacherMode = false;
      snapshot = snapshot.copyWith(
        status: 'Audio-Training benoetigt die Mikrofonberechtigung.',
      );
      notifyListeners();
      return;
    }
    _trainingForegroundOwner = true;
    await _refreshForegroundService();
    await _ensureBackgroundMeasurementAllowed(
      usesMicrophone: true,
      usesConnectedDevice: true,
    );
    if (_mg24.forehead.connected) {
      try {
        await client.setLiveMode(Mg24LiveMode.valuesOnly);
        _snoreTrainingForcedValuesOnly = true;
      } catch (_) {
        _snoreTrainingForcedValuesOnly = false;
      }
    }
    final detectorWasRunning = _snoreDetector != null;
    await _ensureMg24YamnetTeacher();
    _snoreTrainingOwnsSnoreDetector =
        !detectorWasRunning && _snoreDetector != null;
    try {
      await _mg24Client?.resetAudioAnalysis();
    } catch (_) {}
    _mg24AudioSnoreDetector.reset();
    final dir = await _csvDirectory(create: true);
    final safeLabel = label.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${dir.path}${Platform.pathSeparator}snore_training_${safeLabel}_$stamp.csv',
    );
    final melFile = File(file.path.replaceFirst(RegExp(r'\.csv$'), '.mel.csv'));
    final sink = file.openWrite();
    final melSink = melFile.openWrite();
    sink.writeln(_snoreTrainingColumns.join(','));
    melSink.writeln(_snoreMelTrainingColumns().join(','));
    _snoreTrainingFile = file;
    _snoreTrainingSink = sink;
    _snoreMelTrainingFile = melFile;
    _snoreMelTrainingSink = melSink;
    _snoreTrainingLabel = label;
    _snoreTrainingWindowActive = false;
    _snoreTrainingWindowStartedAt = null;
    _snoreTrainingWindowId = 0;
    _snoreTrainingSampleCount = 0;
    _snoreTrainingCompleteFeatureCount = 0;
    _snoreMelPacketCount = 0;
    _snoreMelSliceCount = 0;
    _snoreMelDroppedSliceCount = 0;
    _lastSnoreMelFrameSequence = null;
    _resetSnoreMelPreflight(clearRetryCount: true);
    _snoreMelTransportGeneration++;
    _latestSnoreMelModelScorePercent = null;
    _latestSnoreMelModelActive = false;
    _latestSnoreMelModelTrusted = false;
    try {
      await client.setMelTraining(true);
      _armSnoreMelPreflightTimeout(_snoreMelInitialPacketTimeout);
    } catch (error) {
      await _abortSnoreMelTrainingForTransport(
        'Log-Mel konnte nicht aktiviert werden: ${_friendlyError(error)}',
      );
      return;
    }
    snapshot = snapshot.copyWith(
      status: automaticTeacher
          ? 'YAMNet-Training: gemeinsame Audio-Zeitbasis wird aufgebaut ...'
          : 'Audio-Training "$label": Log-Mel-Datenrate wird geprueft ...',
      csvDirectoryPath: dir.path,
    );
    notifyListeners();
  }

  Future<void> stopSnoreTraining() async {
    final automaticTeacher = _snoreAutomaticTeacherMode;
    if (automaticTeacher) {
      _snoreAutomaticTrainingStoppedUs = AppMonotonicClock.nowUs();
      _captureActiveAutomaticTeacherWindow();
      _snoreTeacherSynchronizer.recompute();
    }
    _snoreMelPreflightTimeoutTimer?.cancel();
    _snoreMelPreflightTimeoutTimer = null;
    _snoreMelTransportGeneration++;
    final sink = _snoreTrainingSink;
    final file = _snoreTrainingFile;
    final melSink = _snoreMelTrainingSink;
    final melFile = _snoreMelTrainingFile;
    final label = _snoreTrainingLabel;
    if (sink != null && _snoreTrainingWindowActive) {
      _writeSnoreTrainingMarker('manual_window_end');
    }
    if (melSink != null) {
      try {
        await _mg24Client?.setMelTraining(false);
      } catch (_) {}
    }
    _snoreTrainingSink = null;
    _snoreTrainingFile = null;
    _snoreMelTrainingSink = null;
    _snoreMelTrainingFile = null;
    _snoreTrainingLabel = null;
    _snoreTrainingWindowActive = false;
    _snoreTrainingWindowStartedAt = null;
    _resetSnoreMelPreflight(clearRetryCount: true);
    _snoreMelTransportRecoveryInProgress = false;
    if (_snoreTrainingOwnsSnoreDetector) {
      final detector = _snoreDetector;
      _snoreDetector = null;
      _snoreTrainingOwnsSnoreDetector = false;
      _mg24YamnetTeacherActive = _developerYamnetMonitorActive;
      try {
        await detector?.stop();
      } catch (_) {}
    }
    await _closeYamnetTeacherLog();
    if (_snoreTrainingForcedValuesOnly) {
      _snoreTrainingForcedValuesOnly = false;
      try {
        await _mg24Client?.setLiveMode(mg24LiveMode);
      } catch (_) {}
    }
    if (sink != null) {
      await sink.flush();
      await sink.close();
      if (melSink != null) {
        await melSink.flush();
        await melSink.close();
      }
      if (automaticTeacher && melFile != null) {
        await _finalizeAutomaticTeacherMelFile(melFile);
      }
      await refreshSnoreTrainingRecordings(notify: false);
      final sync = _snoreTeacherSynchronizer.estimate;
      final syncText = automaticTeacher && sync.ready
          ? ', ${_snoreAutomaticTeacherWindows.length} YAMNet-Fenster, '
              'Sync ${sync.method} +/-${sync.errorMs?.toStringAsFixed(0) ?? '--'} ms'
          : '';
      snapshot = snapshot.copyWith(
        status:
            'Audio-Training "$label" gespeichert: ${_fileName(file?.path ?? '')}'
            '${melFile == null ? '' : ' + ${_fileName(melFile.path)}'}$syncText',
        csvPath: file?.path,
        csvDirectoryPath: file?.parent.path,
      );
      notifyListeners();
    }
    _snoreAutomaticTeacherMode = false;
    _snoreAutomaticTrainingStartedUs = null;
    _snoreAutomaticTrainingStoppedUs = null;
    _trainingForegroundOwner = false;
    await _refreshForegroundService();
  }

  Future<void> refreshSnoreTrainingRecordings({bool notify = true}) async {
    _snoreTrainingRecordingsLoading = true;
    if (notify) notifyListeners();
    try {
      final dir = await _csvDirectory(create: true);
      final recordings = <SnoreTrainingRecording>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final fileName = _fileName(entity.path);
        final match = RegExp(
          r'^snore_training_(.+)_(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:-\d+)?)\.csv$',
        ).firstMatch(fileName);
        if (match == null) continue;
        final stat = await entity.stat();
        recordings.add(
          SnoreTrainingRecording(
            fileName: fileName,
            label: match.group(1) ?? 'unbekannt',
            recordedAt: stat.modified,
            sizeBytes: stat.size,
          ),
        );
      }
      recordings.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
      _snoreTrainingRecordings = List.unmodifiable(recordings);
    } finally {
      _snoreTrainingRecordingsLoading = false;
      if (notify) notifyListeners();
    }
  }

  Future<int> exportSnoreTrainingRecordingsForAnalysis() async {
    final sourceDir = await _csvDirectory(create: false);
    final externalDir = await getExternalStorageDirectory();
    if (externalDir == null) {
      snapshot = snapshot.copyWith(
        status: 'Kein externer App-Ordner fuer den Trainingsexport gefunden.',
      );
      notifyListeners();
      return 0;
    }

    final exportDir = Directory(
      '${externalDir.path}${Platform.pathSeparator}training_export',
    );
    await exportDir.create(recursive: true);
    final exportName = RegExp(
      r'^(?:snore_training_.+|snore_teacher_yamnet_.+)\.csv$',
    );
    var copied = 0;
    await for (final entity in sourceDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final fileName = _fileName(entity.path);
      if (!exportName.hasMatch(fileName)) continue;
      await entity.copy(
        '${exportDir.path}${Platform.pathSeparator}$fileName',
      );
      copied++;
    }
    snapshot = snapshot.copyWith(
      status: '$copied Trainingsdateien fuer die Analyse exportiert.',
      csvDirectoryPath: exportDir.path,
    );
    notifyListeners();
    return copied;
  }

  Future<bool> deleteSnoreTrainingRecording(String fileName) async {
    final safeName = RegExp(
      r'^snore_training_.+_\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:-\d+)?\.csv$',
    );
    if (_fileName(fileName) != fileName || !safeName.hasMatch(fileName)) {
      return false;
    }
    if (_snoreTrainingFile != null &&
        _fileName(_snoreTrainingFile!.path) == fileName) {
      snapshot = snapshot.copyWith(
        status: 'Eine laufende Trainingsaufnahme kann nicht geloescht werden.',
      );
      notifyListeners();
      return false;
    }

    final dir = await _csvDirectory(create: false);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    if (!await file.exists()) {
      await refreshSnoreTrainingRecordings(notify: false);
      notifyListeners();
      return false;
    }
    await file.delete();
    final melFile = File(
      file.path.replaceFirst(RegExp(r'\.csv$'), '.mel.csv'),
    );
    if (await melFile.exists()) {
      await melFile.delete();
    }
    await refreshSnoreTrainingRecordings(notify: false);
    snapshot = snapshot.copyWith(
      status: 'Trainingsaufnahme geloescht: $fileName',
    );
    notifyListeners();
    return true;
  }

  void toggleSnoreTrainingWindow() {
    if (_snoreTrainingSink == null) return;
    if (_snoreAutomaticTeacherMode) return;
    if (!_snoreMelTransportReady) {
      snapshot = snapshot.copyWith(
        status: 'Bitte warten, bis die Log-Mel-Datenrate geprueft ist.',
      );
      notifyListeners();
      return;
    }
    if (_snoreTrainingWindowActive) {
      _writeSnoreTrainingMarker('manual_window_end');
      _snoreTrainingWindowActive = false;
      _snoreTrainingWindowStartedAt = null;
    } else {
      _snoreTrainingWindowId++;
      _snoreTrainingWindowActive = true;
      _snoreTrainingWindowStartedAt = DateTime.now();
      _writeSnoreTrainingMarker('manual_window_start');
    }
    notifyListeners();
  }

  Future<void> startDeveloperYamnetMonitor() async {
    if (_developerYamnetMonitorActive ||
        _developerYamnetMonitorStartInProgress) {
      return;
    }
    _developerYamnetMonitorStartInProgress = true;
    notifyListeners();
    try {
      if (!await _ensureMicrophonePermission()) {
        snapshot = snapshot.copyWith(
          status: 'YAMNet-Livevergleich benoetigt Mikrofonzugriff.',
        );
        return;
      }
      await _startSnoreDetector();
      if (_snoreDetector == null) return;
      _liveYamnetWindows.clear();
      _developerYamnetMonitorActive = true;
      _mg24YamnetTeacherActive = _mg24.forehead.connected;
      _yamnetMonitorForegroundOwner = true;
      await _refreshForegroundService();
      snapshot = snapshot.copyWith(
        status: _mg24YamnetTeacherActive
            ? 'Livevergleich aktiv: Board-Modell und YAMNet.'
            : 'YAMNet-Handytest aktiv.',
      );
    } finally {
      _developerYamnetMonitorStartInProgress = false;
      notifyListeners();
    }
  }

  Future<void> stopDeveloperYamnetMonitor() async {
    _developerYamnetMonitorActive = false;
    _yamnetMonitorForegroundOwner = false;
    if (!snoreTrainingActive && !running) {
      final detector = _snoreDetector;
      _snoreDetector = null;
      _mg24YamnetTeacherActive = false;
      try {
        await detector?.stop();
      } catch (_) {}
      _yamnetRawSnoreTracker.reset();
    }
    await _refreshForegroundService();
    notifyListeners();
  }

  void _writeSnoreTrainingMarker(String rowType) {
    final sink = _snoreTrainingSink;
    final label = _snoreTrainingLabel;
    if (sink == null || label == null) return;
    final now = DateTime.now();
    final elapsed = _snoreTrainingWindowStartedAt == null
        ? null
        : now.difference(_snoreTrainingWindowStartedAt!).inMilliseconds /
            1000.0;
    String number(double? value, [int digits = 3]) =>
        value == null || !value.isFinite ? '' : value.toStringAsFixed(digits);
    final row = List<String>.filled(_snoreTrainingColumns.length, '');
    row[0] = now.toIso8601String();
    row[1] = rowType;
    row[2] = label;
    row[3] = _snoreTrainingWindowActive ? '1' : '0';
    row[4] = _snoreTrainingWindowId.toString();
    row[5] = number(elapsed);
    sink.writeln(row.join(','));
  }

  void setUseDemoData(bool value) {
    if (running) return;
    useDemoData = value;
    if (value) {
      useRadarData = false;
      useMg24Data = false;
    }
    notifyListeners();
  }

  void setUseRadarData(bool value) {
    if (running) return;
    useRadarData = value;
    if (value) {
      useDemoData = false;
      useMg24Data = false;
    }
    notifyListeners();
  }

  void setUseMg24Data(bool value) {
    if (running) return;
    useMg24Data = value;
    if (value) {
      useDemoData = false;
      useRadarData = false;
      usePositionData = true;
    }
    notifyListeners();
  }

  void setHeartBreathSource(HeartBreathSource source) {
    if (running) return;
    switch (source) {
      case HeartBreathSource.bitalino:
        useDemoData = false;
        useRadarData = false;
        useMg24Data = true;
        usePositionData = true;
      case HeartBreathSource.mg24:
        useDemoData = false;
        useRadarData = false;
        useMg24Data = true;
        usePositionData = true;
      case HeartBreathSource.radar:
        useDemoData = false;
        useRadarData = true;
        useMg24Data = false;
      case HeartBreathSource.demo:
        useDemoData = true;
        useRadarData = false;
        useMg24Data = false;
    }
    notifyListeners();
  }

  void setUsePositionData(bool value) {
    if (running || useMg24Data) return;
    usePositionData = value;
    notifyListeners();
  }

  void setRadarHost(String value) {
    if (running || _radar.connecting) return;
    radarHost = value.trim().isEmpty ? radarDefaultHost : value.trim();
    notifyListeners();
  }

  void useRadarAutoHost() => setRadarHost(radarDefaultHost);

  void useRadarDirectHost() => setRadarHost(radarDirectHost);

  Future<void> openWifiSettings() => AndroidNetwork.openWifiSettings();

  void setSnoreEnabled(bool value) {
    if (running) return;
    snoreEnabled = value;
    notifyListeners();
  }

  Future<void> setYamnetMeasurementEnabled(bool value) async {
    if (measurementActive || yamnetMeasurementEnabled == value) return;
    yamnetMeasurementEnabled = value;
    await _saveMeasurementSettings();
    notifyListeners();
  }

  Future<void> setMeasurementStartSignalEnabled(bool value) async {
    if (measurementStartSignalEnabled == value) return;
    measurementStartSignalEnabled = value;
    notifyListeners();
    await _saveMeasurementSettings();
  }

  void selectDevice(String? address) {
    if (running || address == null) return;
    selectedDevice = _findDevice(address);
    notifyListeners();
  }

  Future<void> scanForDevices() => _scanForDevices();

  Future<bool> connectRadar({
    bool throwOnError = false,
    String? hostOverride,
  }) async {
    if (_radar.connected) return true;
    if (_radar.connecting) return false;

    final hostForAttempt = hostOverride?.trim().isNotEmpty == true
        ? hostOverride!.trim()
        : radarHost;
    if (hostOverride != null) {
      radarHost = hostForAttempt;
    }

    _radar = _radar.copyWith(
      connecting: true,
      connected: false,
      status: 'Radar-Verbindung wird vorbereitet ...',
    );
    snapshot = snapshot.copyWith(radar: _radar, status: _radar.status);
    notifyListeners();

    final boundToWifi = await AndroidNetwork.bindToWifi();
    if (boundToWifi) {
      _radar = _radar.copyWith(
        status: 'Nutze aktuelles WLAN fuer die Radar-Verbindung ...',
      );
      snapshot = snapshot.copyWith(radar: _radar, status: _radar.status);
      notifyListeners();
    }

    final onSensorSetupWifi = await isOnRadarDirectSubnet();
    if ((hostForAttempt == radarDirectHost ||
            hostForAttempt == radarDefaultHost) &&
        onSensorSetupWifi) {
      _radar = _radar.copyWith(
        connected: false,
        connecting: false,
        status:
            'Du bist im Sensor-WLAN $radarSensorSsidHint. Das ist bei dieser Firmware nur fuer die Einrichtung. Fuer Messdaten Sensor und Handy in dasselbe 2,4-GHz Home-/Handy-WLAN bringen und dann "Sensor suchen" tippen.',
      );
      snapshot = snapshot.copyWith(radar: _radar, status: _radar.status);
      notifyListeners();
      return false;
    }

    if (hostForAttempt == radarDirectHost && !onSensorSetupWifi) {
      _radar = _radar.copyWith(
        connected: false,
        connecting: false,
        status:
            'Direkte Radar-Messung ueber $radarDirectHost ist mit dieser Firmware nicht aktiv. Bitte Sensor und Handy in dasselbe 2,4-GHz Home-/Handy-WLAN bringen und "Sensor suchen" tippen.',
      );
      snapshot = snapshot.copyWith(radar: _radar, status: _radar.status);
      notifyListeners();
      return false;
    }

    final client = RadarSensorClient(
      host: hostForAttempt,
      onStatus: (status) {
        _radar = _radar.copyWith(
          connecting: true,
          connected: false,
          status: status,
        );
        snapshot = snapshot.copyWith(radar: _radar, status: status);
        notifyListeners();
      },
      onState: (state) {
        _radar = state;
        snapshot = snapshot.copyWith(radar: state, status: state.status);
        notifyListeners();
      },
    );
    _radarClient = client;

    try {
      await client.start();
      radarHost = hostForAttempt;
      return true;
    } catch (error) {
      if (_radarClient == client) {
        _radarClient = null;
      }
      _radar = _radar.copyWith(
        connected: false,
        connecting: false,
        status: 'Radar-Verbindung fehlgeschlagen: ${_friendlyError(error)}',
      );
      snapshot = snapshot.copyWith(radar: _radar, status: _radar.status);
      notifyListeners();
      if (throwOnError) throw StateError(_radar.status);
      return false;
    }
  }

  Future<void> disconnectRadar() async {
    final client = _radarClient;
    _radarClient = null;
    if (client != null) {
      try {
        await client.stop();
      } catch (_) {}
    }
    _radar = const RadarState.empty();
    snapshot = snapshot.copyWith(radar: _radar, status: 'Radar getrennt');
    notifyListeners();
  }

  Future<bool> connectMg24Sensors({
    bool throwOnError = false,
    Map<Mg24SensorRole, String> preferredRemoteIds = const {},
    bool automaticReconnect = false,
  }) async {
    if (!automaticReconnect) _mg24ReconnectSuppressed = false;
    if (_mg24.ready) {
      if (_scheduledMeasurementCancelPending) {
        await cancelArmedMg24Measurement();
      }
      await _applyDeferredBoardStops();
      return true;
    }
    if (_mg24ConnectInProgress || _mg24DisconnectInProgress) return false;
    _mg24ConnectInProgress = true;
    final operation = ++_mg24ConnectionOperation;
    if (!running) {
      _resetMg24BreathingLiveState(clearPlot: true);
    }
    _mg24 = _mg24.copyWith(
      scanning: true,
      status: 'Suche XIAO MG24 Sensoren ...',
      forehead: _mg24.forehead.copyWith(
        connecting: !_mg24.forehead.hasData,
      ),
      belly: _mg24.belly.copyWith(
        connecting: !_mg24.belly.hasData,
      ),
    );
    snapshot = snapshot.copyWith(mg24: _mg24, status: _mg24.status);
    notifyListeners();
    try {
      final permissionOk = await _ensureBluetoothPermissions();
      if (operation != _mg24ConnectionOperation) return false;
      if (!permissionOk) {
        _mg24 = _mg24.copyWith(
          scanning: false,
          status: 'Bluetooth-Berechtigung fehlt. Bitte in Android erlauben.',
          forehead: _mg24.forehead.copyWith(connecting: false),
          belly: _mg24.belly.copyWith(connecting: false),
        );
        snapshot = snapshot.copyWith(mg24: _mg24, status: _mg24.status);
        notifyListeners();
        return false;
      }

      final client = _mg24Client ??= _createMg24SensorClient();
      final remoteIds = preferredRemoteIds.isNotEmpty
          ? preferredRemoteIds
          : _knownMg24RemoteIds();

      try {
        await client.scanAndConnect(preferredRemoteIds: remoteIds);
        if (operation != _mg24ConnectionOperation ||
            !identical(_mg24Client, client)) {
          return false;
        }
        if (client.state.ready) {
          _mg24ReconnectAttempts = 0;
        }
        if (_scheduledMeasurementCancelPending) {
          await cancelArmedMg24Measurement();
        }
        await _applyDeferredBoardStops();
        return client.state.hasAnyData;
      } catch (error) {
        if (operation != _mg24ConnectionOperation ||
            !identical(_mg24Client, client)) {
          return false;
        }
        final anySensorHasData =
            client.state.forehead.hasData || client.state.belly.hasData;
        if (anySensorHasData) {
          final missing = [
            if (!client.state.forehead.hasData) 'Stirn',
            if (!client.state.belly.hasData) 'Bauch',
          ].join(' und ');
          final partialStatus = _mg24StatusWithConnectionLoss(
            'XIAO MG24 teilweise verbunden. $missing liefert noch keine Daten.',
          );
          _mg24 = _mergeMg24BreathingState(
            _mg24.copyWith(
              scanning: false,
              status: partialStatus,
              forehead: _mg24.forehead.copyWith(connecting: false),
              belly: _mg24.belly.copyWith(connecting: false),
            ),
          );
          snapshot = snapshot.copyWith(mg24: _mg24, status: partialStatus);
          notifyListeners();
          if (_scheduledMeasurementCancelPending) {
            await cancelArmedMg24Measurement();
          }
          await _applyDeferredBoardStops();
          if (throwOnError) throw StateError(_mg24.status);
          return true;
        }

        _mg24Client = null;
        try {
          await client.stop();
        } catch (_) {}
        if (operation != _mg24ConnectionOperation) return false;
        final failedStatus = _mg24StatusWithConnectionLoss(
          'XIAO MG24-Verbindung fehlgeschlagen: ${_friendlyError(error)}',
        );
        _mg24 = _mg24.copyWith(
          scanning: false,
          status: failedStatus,
          forehead: _mg24.forehead.copyWith(connecting: false),
          belly: _mg24.belly.copyWith(connecting: false),
        );
        snapshot = snapshot.copyWith(mg24: _mg24, status: _mg24.status);
        notifyListeners();
        if (throwOnError) throw StateError(_mg24.status);
        return false;
      }
    } finally {
      if (operation == _mg24ConnectionOperation) {
        _mg24ConnectInProgress = false;
        if (_mg24.scanning) {
          _mg24 = _mg24.copyWith(
            scanning: false,
            forehead: _mg24.forehead.copyWith(connecting: false),
            belly: _mg24.belly.copyWith(connecting: false),
          );
          snapshot = snapshot.copyWith(mg24: _mg24);
        }
        notifyListeners();
      }
    }
  }

  Mg24SensorClient _createMg24SensorClient() {
    late final Mg24SensorClient client;
    client = Mg24SensorClient(
      onState: (state) {
        if (!identical(_mg24Client, client)) return;
        final previousMg24 = _mg24;
        final displayStatus = _mg24StatusWithConnectionLoss(state.status);
        _rawMg24 = state.copyWith(status: displayStatus);
        _capturePendingMg24PoseCalibration(_rawMg24);
        final calibratedState = _applyMg24PoseCalibration(_rawMg24);
        _mg24 = _mergeMg24BreathingState(
          calibratedState.copyWith(status: displayStatus),
        );
        snapshot = snapshot.copyWith(
          mg24: _mg24,
          status: _stopInProgress ? snapshot.status : displayStatus,
        );
        if (_isMg24StreamingStateUpdate(previousMg24, _mg24)) {
          _publishIfNeeded();
        } else {
          notifyListeners();
        }
      },
      onSample: (sample) {
        if (identical(_mg24Client, client)) _processMg24Sample(sample);
      },
      onWaveform: (waveform) {
        if (identical(_mg24Client, client)) _processMg24Waveform(waveform);
      },
      onMelFeatures: (packet) {
        if (identical(_mg24Client, client)) {
          _appendSnoreMelTrainingPacket(packet);
        }
      },
      onConnectionLost: () {
        if (identical(_mg24Client, client)) _handleMg24ConnectionLost();
      },
    );
    return client;
  }

  Future<void> setMg24LiveMode(Mg24LiveMode mode) async {
    if (mg24LiveMode == mode) return;
    mg24LiveMode = mode;
    final client = _mg24Client;
    if (client != null && _mg24.connected) {
      try {
        await client.setLiveMode(mode);
      } catch (error) {
        snapshot = snapshot.copyWith(
          status:
              'Live-Modus konnte nicht gesetzt werden: ${_friendlyError(error)}',
        );
      }
    }
    notifyListeners();
  }

  void calibrateMg24PoseNow() {
    if (!_mg24.connected && !_rawMg24.connected) return;
    _calibrateMg24PoseForMeasurement();
    snapshot = snapshot.copyWith(mg24: _mg24);
    notifyListeners();
  }

  bool _isMg24StreamingStateUpdate(Mg24State previous, Mg24State next) {
    final sameConnectionState = previous.scanning == next.scanning &&
        previous.status == next.status &&
        previous.forehead.connected == next.forehead.connected &&
        previous.forehead.connecting == next.forehead.connecting &&
        previous.belly.connected == next.belly.connected &&
        previous.belly.connecting == next.belly.connecting;
    if (!sameConnectionState) return false;

    return previous.forehead.lastUpdate != next.forehead.lastUpdate ||
        previous.belly.lastUpdate != next.belly.lastUpdate ||
        previous.heartRateBpm != next.heartRateBpm ||
        previous.spo2Percent != next.spo2Percent ||
        previous.breathingSignal != next.breathingSignal;
  }

  void _handleMg24ConnectionLost() {
    final reconnecting = running && useMg24Data && !_mg24ReconnectSuppressed;
    if (reconnecting) {
      _recordMg24ConnectionLoss();
    }
    final message = reconnecting
        ? 'XIAO MG24-Verbindung verloren. Wiederverbindung laeuft ...'
        : 'XIAO MG24-Verbindung verloren.';
    final displayMessage = _mg24StatusWithConnectionLoss(message);
    if (!reconnecting) {
      _resetMg24BreathingLiveState(clearPlot: true);
    }
    _mg24 = _mergeMg24BreathingState(
      _mg24.copyWith(
        scanning: false,
        status: displayMessage,
        forehead: _mg24.forehead.copyWith(connecting: false),
        belly: _mg24.belly.copyWith(connecting: false),
      ),
    );
    snapshot = snapshot.copyWith(
      mg24: _mg24,
      status: displayMessage,
      samples: _breathingPlotSamplesSnapshot(),
      breathPeaks: _breathPeaks.toList(growable: false),
      breathCount: _breathCount,
    );
    notifyListeners();
    if (reconnecting) {
      _scheduleMg24Reconnect();
    }
  }

  void _scheduleMg24Reconnect() {
    if (!running ||
        !useMg24Data ||
        _mg24ReconnectSuppressed ||
        _mg24ReconnectInProgress ||
        _mg24MeasurementHasRequiredData()) {
      return;
    }
    if (_mg24ReconnectTimer?.isActive == true) return;
    final seconds = math.min(20, 2 + _mg24ReconnectAttempts * 3);
    _mg24ReconnectTimer = Timer(Duration(seconds: seconds), () {
      _mg24ReconnectTimer = null;
      unawaited(_attemptMg24Reconnect());
    });
  }

  Future<void> _attemptMg24Reconnect() async {
    if (!running ||
        !useMg24Data ||
        _mg24ReconnectSuppressed ||
        _mg24ReconnectInProgress ||
        _mg24MeasurementHasRequiredData()) {
      return;
    }
    _mg24ReconnectInProgress = true;
    _mg24ReconnectAttempts++;
    final attempt = _mg24ReconnectAttempts;
    final reconnectStatus = _mg24StatusWithConnectionLoss(
        'XIAO MG24 Wiederverbindung Versuch $attempt ...');
    _mg24 = _mg24.copyWith(
      scanning: true,
      status: reconnectStatus,
      forehead: _mg24.forehead.copyWith(connecting: !_mg24.forehead.connected),
      belly: _mg24.belly.copyWith(connecting: !_mg24.belly.connected),
    );
    snapshot = snapshot.copyWith(mg24: _mg24, status: _mg24.status);
    notifyListeners();

    final preferredRemoteIds = _knownMg24RemoteIds();
    var connected = false;
    try {
      // Keep a healthy role connected while the client scans and reconnects
      // only the missing sensor. Tearing down both GATT links here caused
      // avoidable connection churn after a single-role dropout.
      await connectMg24Sensors(
        preferredRemoteIds: preferredRemoteIds,
        automaticReconnect: true,
      );
      connected = _mg24MeasurementHasRequiredData();
    } catch (_) {
      connected = false;
    } finally {
      _mg24ReconnectInProgress = false;
    }

    if (connected) {
      _mg24ReconnectAttempts = 0;
      return;
    }
    if (running && useMg24Data && !_mg24ReconnectSuppressed) {
      _scheduleMg24Reconnect();
    }
  }

  bool _mg24MeasurementHasRequiredData() {
    final roles = _mg24MeasurementRoles;
    if (roles.isEmpty) return _mg24.hasAnyData;
    for (final role in roles) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      if (!sensor.hasData) return false;
    }
    return true;
  }

  void _cancelMg24Reconnect() {
    _mg24ReconnectTimer?.cancel();
    _mg24ReconnectTimer = null;
    _mg24ReconnectInProgress = false;
    _mg24ReconnectAttempts = 0;
  }

  void _recordMg24ConnectionLoss() {
    final now = DateTime.now();
    final previous = _lastMg24ConnectionLostAt;
    if (previous == null || now.difference(previous).inSeconds > 8) {
      _mg24ConnectionLossCount++;
    }
    _lastMg24ConnectionLostAt = now;
  }

  String _mg24StatusWithConnectionLoss(String baseStatus) {
    if (!running || _mg24ConnectionLossCount <= 0) return baseStatus;
    final suffix = _lastMg24ConnectionLostAt == null
        ? 'Verbindung war seit Messstart unterbrochen.'
        : 'Verbindung war seit Messstart $_mg24ConnectionLossCount x unterbrochen, zuletzt ${_clockLabel(_lastMg24ConnectionLostAt!)}.';
    if (baseStatus.contains('unterbrochen') ||
        baseStatus.contains('Verbindung verloren')) {
      return '$baseStatus $suffix';
    }
    return '$baseStatus Achtung: $suffix';
  }

  Map<Mg24SensorRole, String> _knownMg24RemoteIds() {
    final ids = <Mg24SensorRole, String>{
      ..._deferredBoardStopRemoteIds,
      ..._persistedMg24RemoteIds,
    };
    final foreheadId = _mg24.forehead.remoteId;
    final bellyId = _mg24.belly.remoteId;
    if (foreheadId != null && foreheadId.trim().isNotEmpty) {
      ids[Mg24SensorRole.forehead] = foreheadId;
    }
    if (bellyId != null && bellyId.trim().isNotEmpty) {
      ids[Mg24SensorRole.belly] = bellyId;
    }
    return ids;
  }

  Future<void> disconnectMg24Sensors() async {
    if (_mg24DisconnectInProgress) return;
    _mg24DisconnectInProgress = true;
    _mg24ReconnectSuppressed = true;
    ++_mg24ConnectionOperation;
    _mg24ConnectInProgress = false;
    _cancelMg24Reconnect();
    final client = _mg24Client;
    _mg24Client = null;
    _mg24BreathingSignal = null;
    _mg24BreathingRate = null;
    _mg24BreathingAxis = null;
    _mg24BreathingQuality = null;
    if (!measurementActive) {
      _clearMg24PoseCalibration();
    }
    _resetMg24BreathingLiveState(clearPlot: !running);
    _rawMg24 = const Mg24State.empty();
    _mg24 = const Mg24State.empty().copyWith(
      status: 'XIAO MG24 wird getrennt ...',
    );
    snapshot = snapshot.copyWith(
      mg24: _mg24,
      status: _mg24.status,
      samples: _breathingPlotSamplesSnapshot(),
      breathPeaks: _breathPeaks.toList(growable: false),
      breathCount: _breathCount,
    );
    notifyListeners();
    try {
      if (client != null) {
        try {
          await client.stop();
        } catch (_) {}
      }
      if (!running) {
        await _stopMg24YamnetTeacher();
      }
    } finally {
      _mg24DisconnectInProgress = false;
      _rawMg24 = const Mg24State.empty();
      _mg24 = const Mg24State.empty();
      snapshot = snapshot.copyWith(
        mg24: _mg24,
        status: 'XIAO MG24 getrennt',
        samples: _breathingPlotSamplesSnapshot(),
        breathPeaks: _breathPeaks.toList(growable: false),
        breathCount: _breathCount,
      );
      notifyListeners();
    }
  }

  void _resetMg24BreathingLiveState({required bool clearPlot}) {
    _mg24BreathingDetector = ImuBreathingRateDetector(mg24SamplingRate);
    _mg24BreathingSignal = null;
    _mg24BreathingRate = null;
    _mg24BreathingAxis = null;
    _mg24BreathingQuality = null;
    _mg24LiveStartedAt = null;
    _mg24BreathSignalSequences.clear();
    _mg24BreathSignalBySequence.clear();
    _mg24BreathPeakSequences.clear();
    _mg24BreathPeakSequenceSet.clear();
    _mg24PendingBreathPeakSequences.clear();
    _mg24PendingBreathPeaks.clear();
    _mg24BellyPlotAnchorTimeS = null;
    _mg24BellyPlotAnchorSequence = null;
    _mg24BellyPlotSamplePeriodS = null;
    _mg24BellyPlotAnchorAt = null;
    _resetMg24SensorClocks();
    if (clearPlot) {
      _mg24AudioSnoreDetector.reset();
      _yamnetRawSnoreTracker.reset();
      _snore = const SnoreState.empty();
      _resetSnoreSourceTracking();
      _resetLiveMg24SnoreSourceTracking();
    }
    if (!clearPlot) return;
    _liveYamnetWindows.clear();
    _samples.clear();
    _breathPeaks.clear();
    _snoreBreathWindows.clear();
    _recentConfirmedSnoreBreathWindows.clear();
    _scheduledSnoreBreathWindows.clear();
    _pendingMg24SnoreTimingWindows.clear();
    _activeMg24SnoreTimingWindow = null;
    _lastRecordedMg24SnoreBurstCounter = null;
    _breathCount = 0;
  }

  Mg24State _mergeMg24BreathingState(Mg24State state) {
    return state.copyWith(
      breathingRatePerMin: _mg24BreathingRate,
      clearBreathingRatePerMin: _mg24BreathingRate == null,
      breathingSignal: _mg24BreathingSignal,
      clearBreathingSignal: _mg24BreathingSignal == null,
      breathingAxis: _mg24BreathingAxis,
      clearBreathingAxis: _mg24BreathingAxis == null,
      breathingQuality: _mg24BreathingQuality,
      clearBreathingQuality: _mg24BreathingQuality == null,
    );
  }

  void _clearMg24PoseCalibration() {
    _foreheadPoseCalibration = null;
    _bellyPoseCalibration = null;
    _foreheadYawCorrectionDeg = 0;
    _bellyYawCorrectionDeg = 0;
    _mg24RelativeYawEstimator.reset();
    _foreheadPoseCalibrationEpoch = 0;
    _bellyPoseCalibrationEpoch = 0;
    _mg24PoseCalibrationPending = false;
    _mg24PoseCalibrationRequestedAt = null;
    _mg24PoseCalibrationFreshRolesPending.clear();
  }

  void _calibrateMg24PoseForMeasurement() {
    final rawState = _rawMg24.connected ? _rawMg24 : _mg24;
    final roles = _mg24MeasurementRoles.isNotEmpty
        ? _mg24MeasurementRoles
        : <Mg24SensorRole>{
            if (rawState.forehead.connected || _mg24.forehead.connected)
              Mg24SensorRole.forehead,
            if (rawState.belly.connected || _mg24.belly.connected)
              Mg24SensorRole.belly,
          };
    _foreheadPoseCalibration = null;
    _bellyPoseCalibration = null;
    _foreheadYawCorrectionDeg = 0;
    _bellyYawCorrectionDeg = 0;
    _mg24RelativeYawEstimator.reset();
    _mg24PoseCalibrationPending = roles.isNotEmpty;
    _mg24PoseCalibrationRequestedAt = DateTime.now();
    _mg24PoseCalibrationFreshRolesPending
      ..clear()
      ..addAll(roles);
    _mg24 = _mergeMg24BreathingState(rawState);
  }

  void _capturePendingMg24PoseCalibration(Mg24State state) {
    if (!_mg24PoseCalibrationPending) return;
    _captureFreshMg24PoseCalibration(
      Mg24SensorRole.forehead,
      state.forehead,
    );
    _captureFreshMg24PoseCalibration(Mg24SensorRole.belly, state.belly);
    _mg24PoseCalibrationPending =
        _mg24PoseCalibrationFreshRolesPending.isNotEmpty;
    if (!_mg24PoseCalibrationPending) {
      _mg24PoseCalibrationRequestedAt = null;
    }
  }

  void _captureFreshMg24PoseCalibration(
    Mg24SensorRole role,
    Mg24SensorSummary sensor,
  ) {
    if (!_mg24PoseCalibrationFreshRolesPending.contains(role)) return;
    final requestedAt = _mg24PoseCalibrationRequestedAt;
    if (requestedAt != null) {
      final lastUpdate = sensor.lastUpdate;
      if (lastUpdate == null || lastUpdate.isBefore(requestedAt)) return;
    }
    final calibration = _mg24PoseCalibrationFrom(sensor);
    if (calibration == null) return;
    switch (role) {
      case Mg24SensorRole.forehead:
        _foreheadPoseCalibration = calibration;
        _foreheadPoseCalibrationEpoch = ++_mg24PoseCalibrationEpochCounter;
      case Mg24SensorRole.belly:
        _bellyPoseCalibration = calibration;
        _bellyPoseCalibrationEpoch = ++_mg24PoseCalibrationEpochCounter;
    }
    _mg24PoseCalibrationFreshRolesPending.remove(role);
  }

  Mg24State _applyMg24PoseCalibration(Mg24State state) {
    if (_foreheadPoseCalibration == null && _bellyPoseCalibration == null) {
      return state;
    }
    return state.copyWith(
      forehead: _applyMg24SensorPoseCalibration(
        Mg24SensorRole.forehead,
        state.forehead,
        _foreheadPoseCalibration,
      ),
      belly: _applyMg24SensorPoseCalibration(
        Mg24SensorRole.belly,
        state.belly,
        _bellyPoseCalibration,
      ),
    );
  }

  Mg24SensorSummary _applyMg24SensorPoseCalibration(
    Mg24SensorRole role,
    Mg24SensorSummary sensor,
    _Mg24PoseCalibration? calibration,
  ) {
    if (calibration == null) return sensor;

    final angleDeg =
        _calibratedMg24Angle(sensor.angleDeg, calibration.angleDeg);
    final quaternion = _relativeMg24Quaternion(sensor, calibration);
    final quaternionAngles =
        quaternion == null ? null : _mg24EulerAnglesFromQuaternion(quaternion);
    final rollDeg = quaternionAngles?.rollDeg ??
        _calibratedMg24Angle(sensor.rollDeg, calibration.rollDeg);
    final pitchDeg = quaternionAngles?.pitchDeg ??
        _calibratedMg24Angle(sensor.pitchDeg, calibration.pitchDeg);
    final yawDegRaw = quaternionAngles?.yawDeg ??
        _calibratedMg24Angle(sensor.yawDeg, calibration.yawDeg);
    final yawDeg = _stabilizedMg24YawDeg(
      role,
      sensor,
      rollDeg,
      pitchDeg,
      yawDegRaw,
    );

    return sensor.copyWith(
      angleDeg: angleDeg,
      clearAngleDeg: angleDeg == null,
      rollDeg: rollDeg,
      clearRollDeg: rollDeg == null,
      pitchDeg: pitchDeg,
      clearPitchDeg: pitchDeg == null,
      yawDeg: yawDeg,
      clearYawDeg: yawDeg == null,
      qw: quaternion?.w,
      clearQw: quaternion == null,
      qx: quaternion?.x,
      clearQx: quaternion == null,
      qy: quaternion?.y,
      clearQy: quaternion == null,
      qz: quaternion?.z,
      clearQz: quaternion == null,
      poseCalibrationEpoch: switch (role) {
        Mg24SensorRole.forehead => _foreheadPoseCalibrationEpoch,
        Mg24SensorRole.belly => _bellyPoseCalibrationEpoch,
      },
    );
  }

  double? _stabilizedMg24YawDeg(
    Mg24SensorRole role,
    Mg24SensorSummary rawSensor,
    double? rollDeg,
    double? pitchDeg,
    double? yawDeg,
  ) {
    if (!_isFinite(yawDeg)) return yawDeg;

    var correction = switch (role) {
      Mg24SensorRole.forehead => _foreheadYawCorrectionDeg,
      Mg24SensorRole.belly => _bellyYawCorrectionDeg,
    };
    var correctedYaw = _angleDeltaDeg(yawDeg!, correction);

    final gyroMagnitude = _mg24GyroMagnitude(rawSensor);
    final nearStartTilt = _isFinite(rollDeg) &&
        _isFinite(pitchDeg) &&
        rollDeg!.abs() <= 7.5 &&
        pitchDeg!.abs() <= 7.5;
    final stationary = gyroMagnitude != null && gyroMagnitude <= 4.0;

    if (running && nearStartTilt && stationary) {
      final alpha = correctedYaw.abs() > 12.0 ? 0.22 : 0.08;
      correction = _normalizeAngleDeg(correction + correctedYaw * alpha);
      switch (role) {
        case Mg24SensorRole.forehead:
          _foreheadYawCorrectionDeg = correction;
        case Mg24SensorRole.belly:
          _bellyYawCorrectionDeg = correction;
      }
      correctedYaw = _angleDeltaDeg(yawDeg, correction);
      if (correctedYaw.abs() < 0.15) return 0;
    }

    return correctedYaw;
  }

  Future<bool> provisionRadarWifi({
    required String portalHost,
    required String ssid,
    required String password,
  }) async {
    final cleanHost =
        portalHost.trim().isEmpty ? '192.168.4.1' : portalHost.trim();
    final cleanSsid = ssid.trim();
    if (cleanSsid.isEmpty) {
      snapshot = snapshot.copyWith(status: 'Bitte WLAN-Namen eintragen.');
      notifyListeners();
      return false;
    }

    snapshot = snapshot.copyWith(
      status: 'Sende WLAN-Daten an den Radar-Hotspot ...',
    );
    notifyListeners();

    await AndroidNetwork.bindToWifi();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      await _sendRadarWifiCredentials(
        client: client,
        host: cleanHost,
        ssid: cleanSsid,
        password: password,
      );

      radarHost = radarDefaultHost;
      snapshot = snapshot.copyWith(
        status:
            'WLAN-Daten gespeichert. Sensor startet neu. Handy wieder ins gleiche Home-/Handy-WLAN bringen und dann "Sensor suchen" tippen.',
      );
      await AndroidNetwork.clearBinding();
      notifyListeners();
      return true;
    } catch (error) {
      snapshot = snapshot.copyWith(
        status:
            'WLAN-Setup fehlgeschlagen: ${_friendlyError(error)}. Bitte mit dem Sensor-Hotspot "$radarSensorSsidHint" verbinden und erneut senden.',
      );
      notifyListeners();
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendRadarWifiCredentials({
    required HttpClient client,
    required String host,
    required String ssid,
    required String password,
  }) async {
    final attempts = <Future<void> Function()>[
      () => _sendRadarWifiCredentialsGet(client, host, '/wifisave', {
            'ssid': ssid,
            'psk': password,
          }),
      () => _sendRadarWifiCredentialsPost(client, host, '/wifisave', {
            'ssid': ssid,
            'psk': password,
          }),
      () => _sendRadarWifiCredentialsGet(client, host, '/save', {
            'ssid': ssid,
            'pass': password,
          }),
    ];

    Object? lastError;
    for (final attempt in attempts) {
      try {
        await attempt();
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError(lastError?.toString() ?? 'Portal nicht erreichbar');
  }

  Future<void> _sendRadarWifiCredentialsGet(
    HttpClient client,
    String host,
    String path,
    Map<String, String> queryParameters,
  ) async {
    final uri = Uri(
      scheme: 'http',
      host: host,
      path: path,
      queryParameters: queryParameters,
    );
    final request =
        await client.getUrl(uri).timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    await _checkProvisioningResponse(response);
  }

  Future<void> _sendRadarWifiCredentialsPost(
    HttpClient client,
    String host,
    String path,
    Map<String, String> fields,
  ) async {
    final uri = Uri(scheme: 'http', host: host, path: path);
    final body = fields.entries
        .map((entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    final request =
        await client.postUrl(uri).timeout(const Duration(seconds: 8));
    request.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 8));
    await _checkProvisioningResponse(response);
  }

  Future<void> _checkProvisioningResponse(HttpClientResponse response) async {
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode}');
    }
  }

  Future<void> _scanForDevices({bool allowWhileRunning = false}) async {
    if ((!allowWhileRunning && running) ||
        scanningDevices ||
        !needsBitalinoDevice) {
      return;
    }
    if (!supportsBitalinoHardware) {
      snapshot = snapshot.copyWith(
        status: 'BITalino-Suche ist nur auf Android/iOS verfuegbar.',
      );
      notifyListeners();
      return;
    }

    scanningDevices = true;
    snapshot = snapshot.copyWith(status: 'Suche gekoppelte BITalinos ...');
    notifyListeners();

    try {
      final permissionOk = await _ensureBluetoothPermissions();
      if (!permissionOk) {
        availableDevices = const [];
        selectedDevice = null;
        snapshot = snapshot.copyWith(
          status: 'Bluetooth-Berechtigung fehlt. Bitte in Android erlauben.',
        );
        return;
      }

      final found = await BITalinoController.scanDevices(
        automaticCommunicationType,
      );
      availableDevices = found;
      final previousAddress = selectedDevice?.address;
      selectedDevice = _findDevice(previousAddress);
      if (selectedDevice == null && found.length == 1) {
        selectedDevice = found.first;
      }

      if (found.isEmpty) {
        snapshot = snapshot.copyWith(
          status:
              'Kein gekoppelter BITalino gefunden. Bitte in Android-Bluetooth koppeln und erneut suchen.',
        );
      } else if (found.length == 1) {
        snapshot = snapshot.copyWith(
          status: 'BITalino gefunden: ${_deviceLabel(found.first)}',
        );
      } else {
        snapshot = snapshot.copyWith(
          status: '${found.length} BITalinos gefunden. Bitte einen auswaehlen.',
        );
      }
    } catch (error) {
      availableDevices = const [];
      selectedDevice = null;
      snapshot = snapshot.copyWith(
        status: 'BITalino-Suche fehlgeschlagen: ${_friendlyError(error)}',
      );
    } finally {
      scanningDevices = false;
      notifyListeners();
    }
  }

  Future<bool> armMg24Measurement({
    Duration countdown = const Duration(seconds: 30),
    void Function(DateTime scheduledAt)? onScheduled,
  }) async {
    if (measurementActive || _pendingEveningAnswers == null) return false;
    final roles = connectedMeasurementSensorRoles;
    final client = _mg24Client;
    if (roles.isEmpty || client == null) {
      snapshot = snapshot.copyWith(
        status: 'Zum Starten muss mindestens ein Sensor verbunden sein.',
      );
      notifyListeners();
      return false;
    }

    final scheduledAt = DateTime.now().add(countdown);
    final sessionId = scheduledAt.millisecondsSinceEpoch & 0xffff;
    final remoteIds = <Mg24SensorRole, String>{};
    for (final role in roles) {
      final remoteId = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead.remoteId,
        Mg24SensorRole.belly => _mg24.belly.remoteId,
      };
      if (remoteId != null && remoteId.trim().isNotEmpty) {
        remoteIds[role] = remoteId;
      }
    }

    _measurementArmed = true;
    _measurementScheduledStartAt = scheduledAt;
    _measurementStartedAt = scheduledAt;
    _sleepCycleStartedAt = scheduledAt;
    _sleepCycleEndedAt = null;
    _mg24MeasurementRoles = Set.unmodifiable(roles);
    _persistedMg24RemoteIds = Map.unmodifiable(remoteIds);
    _activeBoardSessionId = sessionId;
    _scheduledMeasurementCancelPending = false;
    _pendingBoardStopRoles = const {};
    if (kDebugMode) {
      debugPrint(
        '[MG24-MEASUREMENT] arm session=$sessionId roles='
        '${roles.map((role) => role.name).join(',')} due=$scheduledAt',
      );
    }
    onScheduled?.call(scheduledAt);
    try {
      await client.startBoardRecording(
        sessionId: sessionId,
        startedAt: scheduledAt,
        scheduledStartAt: scheduledAt,
        roles: roles,
      );
      if (kDebugMode) {
        debugPrint('[MG24-MEASUREMENT] arm acknowledged session=$sessionId');
      }
      await _persistActiveMeasurementSession(recording: true);
      snapshot = snapshot.copyWith(
        status: 'Sensoren vorbereitet. Messung startet nach dem Countdown.',
        measurementStartedAt: scheduledAt,
      );
      notifyListeners();
      return true;
    } on Mg24RecordingStartException catch (error) {
      if (kDebugMode) {
        debugPrint('[MG24-MEASUREMENT] arm failed: $error');
      }
      // A timed-out GATT write can still have reached the board. Stop every
      // intended role, including the role whose acknowledgement was lost.
      _pendingBoardStopRoles = Set.unmodifiable(roles);
      _scheduledMeasurementCancelPending = true;
      await _persistActiveMeasurementSession(recording: true);
      await cancelArmedMg24Measurement();
      snapshot = snapshot.copyWith(
        status: 'Messstart konnte nicht vorbereitet werden: '
            '${_friendlyError(error)}',
      );
      notifyListeners();
      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[MG24-MEASUREMENT] arm failed: $error');
      }
      _pendingBoardStopRoles = Set.unmodifiable(roles);
      _scheduledMeasurementCancelPending = true;
      await _persistActiveMeasurementSession(recording: true);
      await cancelArmedMg24Measurement();
      snapshot = snapshot.copyWith(
        status: 'Messstart konnte nicht vorbereitet werden: '
            '${_friendlyError(error)}',
      );
      notifyListeners();
      return false;
    }
  }

  Future<void> cancelArmedMg24Measurement() async {
    if (!_measurementArmed || _armedCancellationInProgress) return;
    _armedCancellationInProgress = true;
    _scheduledMeasurementCancelPending = true;
    var pending = <Mg24SensorRole>{
      ...(_pendingBoardStopRoles.isEmpty
          ? _mg24MeasurementRoles
          : _pendingBoardStopRoles),
    };
    try {
      final client = _mg24Client;
      if (client != null) {
        for (final role in List<Mg24SensorRole>.of(pending)) {
          final sensor = switch (role) {
            Mg24SensorRole.forehead => _mg24.forehead,
            Mg24SensorRole.belly => _mg24.belly,
          };
          if (!sensor.connected) continue;
          try {
            await client.stopBoardRecording(roles: {role});
            pending.remove(role);
          } catch (_) {
            // Keep this role pending and retry on its next connection.
          }
        }
      }
      _pendingBoardStopRoles = Set.unmodifiable(pending);
      if (pending.isEmpty) {
        await _clearArmedMeasurementState();
        snapshot = snapshot.copyWith(
          status: 'Messstart abgebrochen.',
          running: false,
          clearMeasurementStartedAt: true,
        );
      } else {
        await _persistActiveMeasurementSession(recording: true);
        final labels = pending.map((role) => role.label).join(' + ');
        snapshot = snapshot.copyWith(
          status: 'Abbruch vorgemerkt. $labels wird bei der naechsten '
              'Verbindung automatisch gestoppt.',
          running: false,
        );
      }
      notifyListeners();
    } finally {
      _armedCancellationInProgress = false;
    }
  }

  Future<void> _clearArmedMeasurementState() async {
    _restoredArmedStartTimer?.cancel();
    _restoredArmedStartTimer = null;
    _measurementArmed = false;
    _scheduledMeasurementCancelPending = false;
    _pendingBoardStopRoles = const {};
    _measurementScheduledStartAt = null;
    _measurementStartedAt = null;
    _sleepCycleStartedAt = null;
    _sleepCycleEndedAt = null;
    _pendingEveningAnswers = null;
    _mg24MeasurementRoles = const {};
    _persistedMg24RemoteIds = const {};
    _activeBoardSessionId = null;
    try {
      await _clearActiveMeasurementSession();
    } catch (_) {}
  }

  Future<void> start({bool activateArmedMeasurement = false}) async {
    if (running) return;

    final armedStart = activateArmedMeasurement && _measurementArmed;
    final armedStartedAt = _measurementScheduledStartAt;
    final armedRoles = _mg24MeasurementRoles;
    final armedRemoteIds = _persistedMg24RemoteIds;
    final armedSessionId = _activeBoardSessionId;
    if (activateArmedMeasurement &&
        (!armedStart || armedStartedAt == null || armedRoles.isEmpty)) {
      snapshot = snapshot.copyWith(
        status: 'Der geplante Messstart ist nicht mehr aktiv.',
      );
      notifyListeners();
      return;
    }

    if (!armedStart && !useDemoData && !useRadarData) {
      useMg24Data = true;
      usePositionData = true;
      if (!_mg24.hasAnyData) {
        snapshot = snapshot.copyWith(
          status:
              'Zum Starten muss mindestens ein XIAO MG24 verbunden sein und Daten liefern.',
        );
        notifyListeners();
        return;
      }
    }

    _resetMeasurement();
    if (armedStart) {
      _mg24MeasurementRoles = armedRoles;
      _persistedMg24RemoteIds = armedRemoteIds;
      _activeBoardSessionId = armedSessionId;
    }
    final startedAt = armedStartedAt ?? DateTime.now();
    _measurementStartedAt = startedAt;
    _sleepCycleStartedAt = startedAt;
    _sleepCycleEndedAt = null;
    _csvAggregator = CsvWindowAggregator(
      csvWriteIntervalSeconds,
      startedAt: startedAt,
    );
    snapshot = snapshot.copyWith(
      running: true,
      status: 'Messung wird vorbereitet ...',
      measurementStartedAt: startedAt,
      samples: const [],
      rPeaks: const [],
      breathPeaks: const [],
      snoreTimeline: const [],
      rPeakCount: 0,
      breathCount: 0,
      orientation: const OrientationState.empty(),
      snore: const SnoreState.empty(),
      radar: _radar,
      mg24: _mg24,
      clearHeartRate: true,
      clearBreathingRate: true,
      clearOxygenSaturation: true,
    );
    notifyListeners();

    try {
      if (kDebugMode) {
        debugPrint(
          '[MG24-MEASUREMENT] activate armed=$armedStart '
          'session=$armedSessionId roles='
          '${armedRoles.map((role) => role.name).join(',')}',
        );
      }
      var microphonePermissionGranted = false;
      final needsBitalino = needsBitalinoDevice;
      final needsBluetooth = needsBitalino || useMg24Data;
      if (needsBitalino) {
        await _ensureSelectedDevice();
      }
      if (needsBluetooth) {
        final bluetoothPermissionGranted = await _ensureBluetoothPermissions();
        if (!bluetoothPermissionGranted) {
          throw StateError(
            'Bluetooth-Berechtigung fehlt. Bitte der App Bluetooth in Android erlauben.',
          );
        }
      }

      final needsPhoneMicrophone =
          snoreEnabled && (!useMg24Data || yamnetMeasurementEnabled);
      if (needsPhoneMicrophone) {
        microphonePermissionGranted = await _ensureMicrophonePermission();
        if (!microphonePermissionGranted) {
          snapshot = snapshot.copyWith(
            status:
                'Schnarcherkennung deaktiviert: Mikrofonberechtigung fehlt.',
          );
          notifyListeners();
        }
      }

      _measurementForegroundOwner = true;
      _measurementForegroundUsesMicrophone = microphonePermissionGranted;
      _measurementForegroundUsesConnectedDevice = needsBluetooth;
      await _refreshForegroundService();
      await _ensureBackgroundMeasurementAllowed(
        usesMicrophone: microphonePermissionGranted,
        usesConnectedDevice: needsBluetooth,
      );

      await _openCsv();
      if (needsPhoneMicrophone && microphonePermissionGranted) {
        await _startSnoreDetector();
        _measurementYamnetCaptureActive = _snoreDetector != null;
        _measurementYamnetWasRecorded = _snoreDetector != null;
      }

      if (!useDemoData && !useRadarData) {
        useMg24Data = true;
      }

      if (useDemoData) {
        _startDemo();
      } else if (useMg24Data) {
        await _startMg24Measurement(
          requiredRoles: armedStart ? armedRoles : null,
          boardAlreadyArmed: armedStart,
        );
      } else if (useRadarData) {
        await _startRadarMeasurement();
      } else {
        useMg24Data = true;
        await _startMg24Measurement(
          requiredRoles: armedStart ? armedRoles : null,
          boardAlreadyArmed: armedStart,
        );
      }
      if (armedStart) {
        _restoredArmedStartTimer?.cancel();
        _restoredArmedStartTimer = null;
        _measurementArmed = false;
        _measurementScheduledStartAt = null;
        _scheduledMeasurementCancelPending = false;
        _pendingBoardStopRoles = const {};
        await _persistActiveMeasurementSession(recording: true);
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[MG24-MEASUREMENT] activation failed: $error');
      }
      if (armedStart) {
        final errorStatus = 'Start fehlgeschlagen: ${_friendlyError(error)}';
        _measurementArmed = true;
        _measurementScheduledStartAt = armedStartedAt;
        await cancelArmedMg24Measurement();
        final cleanupStatus = snapshot.status;
        snapshot = snapshot.copyWith(
          running: false,
          status: cleanupStatus.startsWith('Abbruch vorgemerkt')
              ? '$errorStatus $cleanupStatus'
              : errorStatus,
        );
        notifyListeners();
      } else {
        _pendingEveningAnswers = null;
        _sleepCycleStartedAt = null;
        _sleepCycleEndedAt = null;
        await stop(status: 'Start fehlgeschlagen: ${_friendlyError(error)}');
      }
    }
  }

  Future<void> stop({String? status}) async {
    if (_stopInProgress) return;
    if (_isUnstartedBoardMeasurementState()) {
      _stopInProgress = true;
      snapshot = snapshot.copyWith(
        status: 'Fehlgeschlagenen Messstart wird verworfen ...',
      );
      notifyListeners();
      try {
        await _discardUnstartedBoardMeasurementState();
      } finally {
        _stopInProgress = false;
        notifyListeners();
      }
      return;
    }
    if (_measurementArmed) {
      await cancelArmedMg24Measurement();
      return;
    }
    _stopInProgress = true;
    snapshot = snapshot.copyWith(status: 'Messung wird beendet ...');
    notifyListeners();
    try {
      await _stopInternal(status: status);
    } finally {
      _stopInProgress = false;
      notifyListeners();
    }
  }

  bool _isUnstartedBoardMeasurementState() {
    final sessionId = _activeBoardSessionId;
    final roles = _mg24MeasurementRoles;
    if ((!running && !_measurementArmed) ||
        sessionId == null ||
        roles.isEmpty) {
      return false;
    }
    final scheduledAt = _measurementScheduledStartAt;
    for (final role in roles) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      final stateIsFresh = scheduledAt == null ||
          (sensor.lastUpdate != null &&
              !sensor.lastUpdate!.isBefore(scheduledAt));
      if (!sensor.hasData ||
          !stateIsFresh ||
          sensor.recording == true ||
          sensor.recordingArmed == true ||
          sensor.sessionId == (sessionId & 0xffff)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _discardUnstartedBoardMeasurementState() async {
    _cancelMg24Reconnect();
    _measurementForegroundOwner = false;
    _measurementForegroundUsesMicrophone = false;
    _measurementForegroundUsesConnectedDevice = false;
    await _refreshForegroundService();
    final sink = _csvSink;
    _csvSink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    _csvFile = null;
    await _clearArmedMeasurementState();
    snapshot = snapshot.copyWith(
      running: false,
      status: 'Fehlgeschlagener Messstart verworfen. Sensoren sind bereit.',
      clearMeasurementStartedAt: true,
      clearCsvPath: true,
    );
  }

  Future<void> _stopInternal({String? status}) async {
    final needsMg24Stop = useMg24Data && (running || boardRecording);
    final requestedStopRoles = _activeArchiveRoles;
    final connectedStopRoles = requestedStopRoles.where((role) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      return sensor.connected;
    }).toSet();
    final commandStopRoles = connectedStopRoles.where((role) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead,
        Mg24SensorRole.belly => _mg24.belly,
      };
      return sensor.recording != false || sensor.recordingArmed == true;
    }).toSet();
    final deferredStopRoles = requestedStopRoles.difference(connectedStopRoles);
    if (needsMg24Stop &&
        (_mg24Client == null ||
            connectedStopRoles.isEmpty ||
            deferredStopRoles.isNotEmpty)) {
      final sensorText = requestedStopRoles.isEmpty
          ? 'Messsensor'
          : requestedStopRoles.map((role) => role.label).join(' + ');
      snapshot = snapshot.copyWith(
        status: 'Messung laeuft weiter. Zum gemeinsamen Beenden bitte alle '
            'Messsensoren verbinden: $sensorText.',
      );
      notifyListeners();
      return;
    }
    final mg24MayNeedStop = _mg24Client != null && (running || boardRecording);
    if (!running &&
        _demoTimer == null &&
        _radarTimer == null &&
        _bitalinoController == null &&
        !_measurementForegroundOwner &&
        !mg24MayNeedStop) {
      return;
    }

    _demoTimer?.cancel();
    _demoTimer = null;
    _radarTimer?.cancel();
    _radarTimer = null;
    _cancelMg24Reconnect();
    _clearMg24PoseCalibration();
    _sleepCycleEndedAt ??= DateTime.now();
    _closeActiveSnoreSegment(_sleepCycleEndedAt!);
    _finishMeasurementYamnetCapture(_sleepCycleEndedAt!);

    final controller = _bitalinoController;
    _bitalinoController = null;
    if (controller != null) {
      try {
        if (controller.recording) {
          await controller.stop();
        }
      } catch (_) {}
      try {
        if (controller.connected) {
          await controller.disconnect();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }

    String? boardArchivePath;
    String? boardEventArchivePath;
    final mg24Client = _mg24Client;
    if (mg24Client != null) {
      try {
        snapshot = snapshot.copyWith(
          status: 'Datenuebertragung wird vorbereitet ...',
        );
        notifyListeners();
        if (mg24Client.liveMode != Mg24LiveMode.valuesOnly) {
          await mg24Client
              .setLiveMode(Mg24LiveMode.valuesOnly)
              .timeout(const Duration(seconds: 3));
        }
      } catch (_) {
        // Stopping and archive recovery remain possible if live-mode cleanup
        // is not acknowledged by a weak BLE link.
      }
      Object? stopCommandError;
      if (commandStopRoles.isNotEmpty) {
        try {
          await mg24Client
              .stopBoardRecording(roles: commandStopRoles)
              .timeout(const Duration(seconds: 45));
        } catch (error) {
          stopCommandError = error;
        }
      }
      var boardStopConfirmed = await _waitForRequiredBoardsToStop(
        mg24Client,
        roles: connectedStopRoles,
        timeout: const Duration(seconds: 4),
      );
      Map<Mg24SensorRole, Mg24DownloadedArchive>? archives;
      try {
        snapshot = snapshot.copyWith(
          status: 'Board-Messung beendet. Minutenarchiv wird vorbereitet ...',
        );
        notifyListeners();
        archives = await _downloadActiveMinuteArchives(
          mg24Client,
          roles: connectedStopRoles,
        );
        boardStopConfirmed = true;
        boardArchivePath = await _writeMg24MinuteArchive(archives);
        _recoverSleepSessionFromBoardArchive(archives);
      } catch (error) {
        boardStopConfirmed = boardStopConfirmed ||
            _requiredBoardsReportStopped(
              mg24Client.state,
              roles: connectedStopRoles,
            );
        final stopErrorText = stopCommandError == null
            ? ''
            : ' Stoppbefehl: ${_friendlyError(stopCommandError)}.';
        status = boardStopConfirmed
            ? 'Messung ist auf den Boards beendet. Das Minutenarchiv konnte '
                'noch nicht geladen werden: ${_friendlyError(error)}. '
                'Die Daten bleiben auf den Boards und koennen erneut geladen werden.$stopErrorText'
            : 'Messung laeuft vorsichtshalber weiter: '
                '${_friendlyError(error)}.$stopErrorText';
      }
      if (boardStopConfirmed) {
        await _clearDeferredBoardStops(connectedStopRoles);
      } else {
        // The GATT acknowledgement can be lost after the board has already
        // received REC:STOP. Repeating the idempotent command on reconnect is
        // safer than assuming either outcome.
        await _queueDeferredBoardStops(connectedStopRoles);
      }
      if (!boardStopConfirmed) {
        _sleepCycleEndedAt = null;
        if (_measurementYamnetWasRecorded && _snoreDetector != null) {
          _measurementYamnetCaptureActive = true;
        }
        snapshot = snapshot.copyWith(status: status);
        notifyListeners();
        return;
      }
      if (archives != null) {
        try {
          snapshot = snapshot.copyWith(
            status: 'Ereignisarchiv wird vorbereitet ...',
          );
          notifyListeners();
          final eventArchives = await _downloadActiveEventArchives(
            mg24Client,
            roles: archives.keys.toSet(),
          );
          boardEventArchivePath = await _writeMg24EventArchive(eventArchives);
        } catch (error) {
          status ??=
              'Messung beendet, Board-Eventarchiv konnte nicht geladen werden: '
              '${_friendlyError(error)}';
        }
        // Keep both boards connected after a successful stop. Disconnecting
        // here made a normal measurement end look like a BLE failure and made
        // the next live session needlessly expensive to establish.
      }
    }

    final snoreDetector = _snoreDetector;
    _snoreDetector = null;
    _snoreTrainingOwnsSnoreDetector = false;
    _mg24YamnetTeacherActive = false;
    _mg24YamnetTeacherStartInProgress = false;
    if (snoreDetector != null) {
      try {
        await snoreDetector.stop();
      } catch (_) {}
    }
    await _closeYamnetTeacherLog();

    _measurementForegroundOwner = false;
    _measurementForegroundUsesMicrophone = false;
    _measurementForegroundUsesConnectedDevice = false;
    await _refreshForegroundService();

    final sink = _csvSink;
    _csvSink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
    final currentDataCsvPath = boardArchivePath ?? _csvFile?.path;
    if (currentDataCsvPath != null) {
      _csvFile = File(currentDataCsvPath);
    }

    final duration = _elapsedSeconds();
    _measurementStartedAt = null;
    if (useMg24Data && _sleepCycleStartedAt != null) {
      try {
        await _persistActiveMeasurementSession(recording: false);
      } catch (error) {
        status ??=
            'Messung beendet, Sitzungsstatus konnte nicht gesichert werden: '
            '${_friendlyError(error)}';
      }
    }
    snapshot = snapshot.copyWith(
      running: false,
      mg24: _mg24,
      status: status ??
          'Gestoppt. Dauer: ${duration.toStringAsFixed(1)} s, '
              'R-Peaks: $_rPeakCount, Atemzuege: $_breathCount, '
              'Schnarch-Phasen: ${_snore.snoreCount}'
              '${boardArchivePath == null ? '' : ', Minutenarchiv gespeichert'}'
              '${boardEventArchivePath == null ? '' : ', Eventarchiv gespeichert'}'
              '${deferredStopRoles.isEmpty ? '' : '. ${deferredStopRoles.map((role) => role.label).join(' + ')} wird bei der naechsten Verbindung automatisch gestoppt'}',
      fileLabel: currentDataCsvPath == null
          ? snapshot.fileLabel
          : 'CSV: ${_fileName(currentDataCsvPath)}',
      csvPath: currentDataCsvPath,
      snoreTimeline: _snoreTimelineSnapshot(),
      clearMeasurementStartedAt: true,
    );
    notifyListeners();
  }

  Set<Mg24SensorRole> get _activeArchiveRoles {
    if (_mg24MeasurementRoles.isNotEmpty) return _mg24MeasurementRoles;
    return <Mg24SensorRole>{
      if (_mg24.belly.hasData) Mg24SensorRole.belly,
      if (_mg24.forehead.hasData) Mg24SensorRole.forehead,
    };
  }

  bool _requiredBoardsReportStopped(
    Mg24State state, {
    Set<Mg24SensorRole>? roles,
  }) {
    final requiredRoles = roles ?? _activeArchiveRoles;
    if (requiredRoles.isEmpty) return false;
    for (final role in requiredRoles) {
      final sensor = switch (role) {
        Mg24SensorRole.forehead => state.forehead,
        Mg24SensorRole.belly => state.belly,
      };
      if (!sensor.hasData || sensor.recording != false) return false;
    }
    return true;
  }

  Future<bool> _waitForRequiredBoardsToStop(
    Mg24SensorClient client, {
    Set<Mg24SensorRole>? roles,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (_requiredBoardsReportStopped(client.state, roles: roles)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (DateTime.now().isBefore(deadline));
    return _requiredBoardsReportStopped(client.state, roles: roles);
  }

  void _showArchiveTransferProgress(
    String archiveLabel,
    Mg24SensorRole role,
    int downloaded,
    int total,
  ) {
    final progress = total <= 0 ? 'leer' : '$downloaded/$total';
    snapshot = snapshot.copyWith(
      status: '$archiveLabel ${role.label}: $progress Datensaetze',
    );
    notifyListeners();
  }

  Future<Map<Mg24SensorRole, Mg24DownloadedArchive>>
      _downloadActiveMinuteArchives(
    Mg24SensorClient client, {
    Set<Mg24SensorRole>? roles,
  }) async {
    final requiredRoles = roles ?? _activeArchiveRoles;
    _minuteArchiveWarning = null;
    if (requiredRoles.isEmpty) {
      throw StateError('Keine Messsensoren fuer den Archivdownload bekannt.');
    }
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final downloaded = await client.downloadMinuteArchives(
          roles: requiredRoles,
          maximumDurationPerSensor: const Duration(seconds: 75),
          onProgress: (role, current, total) => _showArchiveTransferProgress(
            'Minutenarchiv',
            role,
            current,
            total,
          ),
        );
        final archives = <Mg24SensorRole, Mg24DownloadedArchive>{
          for (final entry in downloaded.entries)
            if (requiredRoles.contains(entry.key) &&
                _archiveMatchesActiveSession(entry.value.status))
              entry.key: entry.value,
        };
        final notDownloaded = requiredRoles.difference(downloaded.keys.toSet());
        if (notDownloaded.isNotEmpty) {
          throw StateError(
            'Archiv nicht empfangen fuer '
            '${notDownloaded.map((role) => role.label).join(' + ')}.',
          );
        }
        final missing = requiredRoles.difference(archives.keys.toSet());
        if (archives.isEmpty) {
          final received = downloaded.entries
              .map((entry) => '${entry.key.label}: Session '
                  '${entry.value.status.sessionId}, Startminute '
                  '${entry.value.status.unixStartMinute}')
              .join('; ');
          throw StateError(
            'Kein Archiv passt zur vorgemerkten Messung. Empfangen: $received.',
          );
        }
        if (missing.isNotEmpty) {
          final labels = missing.map((role) => role.label).join(' + ');
          _minuteArchiveWarning =
              '$labels gehoert zu einer anderen Messung und wurde nicht vermischt.';
          snapshot = snapshot.copyWith(
            status: 'Teilarchiv wird uebernommen. $_minuteArchiveWarning',
          );
          notifyListeners();
        }
        final stillRecording = archives.values
            .where((archive) => archive.status.recording)
            .map((archive) => archive.status.role.label)
            .toList(growable: false);
        if (stillRecording.isNotEmpty) {
          throw StateError(
            'Board-Stopp nicht bestaetigt: ${stillRecording.join(' + ')} misst weiter.',
          );
        }
        return archives;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          snapshot = snapshot.copyWith(
            status: 'Minutenarchiv unterbrochen. Neuer Versuch ...',
          );
          notifyListeners();
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
    }
    throw StateError(
        _friendlyError(lastError ?? 'Archivdownload fehlgeschlagen'));
  }

  bool _archiveMatchesActiveSession(Mg24ArchiveStatus status) {
    final activeSessionId = _activeBoardSessionId;
    if (activeSessionId == null) return true;
    if (status.sessionId == (activeSessionId & 0xffff)) return true;
    final expectedStart = _sleepCycleStartedAt ?? _measurementStartedAt;
    return expectedStart != null &&
        expectedStart.millisecondsSinceEpoch ~/ 60000 == status.unixStartMinute;
  }

  Future<Map<Mg24SensorRole, Mg24DownloadedEventArchive>>
      _downloadActiveEventArchives(
    Mg24SensorClient client, {
    Set<Mg24SensorRole>? roles,
  }) async {
    final requiredRoles = roles ?? _activeArchiveRoles;
    final downloaded = await client.downloadEventArchives(
      roles: requiredRoles,
      maximumDurationPerSensor: const Duration(seconds: 75),
      onProgress: (role, current, total) => _showArchiveTransferProgress(
        'Ereignisarchiv',
        role,
        current,
        total,
      ),
    );
    return <Mg24SensorRole, Mg24DownloadedEventArchive>{
      for (final entry in downloaded.entries)
        if (requiredRoles.contains(entry.key) &&
            (_activeBoardSessionId == null ||
                entry.value.status.sessionId == _activeBoardSessionId))
          entry.key: entry.value,
    };
  }

  Future<bool> recoverPendingBoardArchive() async {
    if (!canRecoverPendingBoardArchive) return false;
    final client = _mg24Client;
    if (client == null) return false;

    _stopInProgress = true;
    snapshot = snapshot.copyWith(
      status: 'Gestoppte Board-Messung wird ins Journal uebernommen ...',
    );
    notifyListeners();
    try {
      final archives = await _downloadActiveMinuteArchives(client);
      final archiveWarning = _minuteArchiveWarning;
      final boardArchivePath = await _writeMg24MinuteArchive(archives);
      _recoverSleepSessionFromBoardArchive(archives);
      try {
        final eventArchives = await _downloadActiveEventArchives(
          client,
          roles: archives.keys.toSet(),
        );
        await _writeMg24EventArchive(eventArchives);
      } catch (_) {
        // Minute values are sufficient for the journal; event details remain
        // recoverable from the boards on a later developer export.
      }
      if (boardArchivePath != null) {
        _csvFile = File(boardArchivePath);
      }
      await _persistActiveMeasurementSession(recording: false);
      snapshot = snapshot.copyWith(
        running: false,
        status: archiveWarning == null
            ? 'Board-Archiv geladen. Schlafzyklus wird gespeichert ...'
            : 'Teilarchiv geladen. $archiveWarning Schlafzyklus wird gespeichert ...',
        fileLabel: boardArchivePath == null
            ? snapshot.fileLabel
            : 'CSV: ${_fileName(boardArchivePath)}',
        csvPath: boardArchivePath ?? snapshot.csvPath,
        clearMeasurementStartedAt: true,
      );
      notifyListeners();
      return true;
    } catch (error) {
      snapshot = snapshot.copyWith(
        status:
            'Board-Archiv konnte nicht geladen werden: ${_friendlyError(error)}. Die Daten bleiben auf den Sensoren.',
      );
      notifyListeners();
      return false;
    } finally {
      _stopInProgress = false;
      notifyListeners();
    }
  }

  Future<void> recoverLatestBoardMeasurement() async {
    if (_stopInProgress || measurementActive) return;
    final client = _mg24Client;
    if (client == null) return;

    _stopInProgress = true;
    snapshot = snapshot.copyWith(
      status: 'Letzte Board-Messung wird geladen ...',
    );
    notifyListeners();
    try {
      final archives = await client.downloadMinuteArchives();
      if (archives.isEmpty) {
        snapshot = snapshot.copyWith(
          status: 'Auf den verbundenen Sensoren liegt kein Minutenarchiv.',
        );
        return;
      }
      final primary =
          archives[Mg24SensorRole.forehead] ?? archives[Mg24SensorRole.belly];
      if (primary == null) return;
      final startedAt = _archiveStartedAt(
        sessionId: primary.status.sessionId,
        unixStartMinute: primary.status.unixStartMinute,
      );
      final duplicate = sleepHistory.any(
        (record) =>
            record.metrics.startedAt.difference(startedAt).abs() <=
            const Duration(minutes: 1),
      );
      if (duplicate) {
        snapshot = snapshot.copyWith(
          status: 'Diese Board-Messung ist bereits im Schlafjournal.',
        );
        return;
      }

      final boardArchivePath = await _writeMg24MinuteArchive(archives);
      try {
        final eventArchives = await client.downloadEventArchives();
        await _writeMg24EventArchive(eventArchives);
      } catch (_) {}

      _sleepCycleStartedAt = null;
      _sleepCycleEndedAt = null;
      _pendingEveningAnswers = null;
      _pendingRecoveredBoardSummary = null;
      _recoverSleepSessionFromBoardArchive(archives);
      if (boardArchivePath != null) {
        _csvFile = File(boardArchivePath);
        snapshot = snapshot.copyWith(
          csvPath: boardArchivePath,
          fileLabel: 'CSV: ${_fileName(boardArchivePath)}',
        );
      }
      final record = await completeSleepSession(const <String, int>{});
      if (record == null) {
        snapshot = snapshot.copyWith(
          status: 'Board-Messung konnte nicht ins Journal uebernommen werden.',
        );
      }
    } catch (error) {
      snapshot = snapshot.copyWith(
        status:
            'Board-Messung konnte nicht geladen werden: ${_friendlyError(error)}',
      );
    } finally {
      _stopInProgress = false;
      notifyListeners();
    }
  }

  Future<void> disposeController() async {
    _snoreMelPreflightTimeoutTimer?.cancel();
    if (snoreTrainingActive) await stopSnoreTraining();
    if (_developerYamnetMonitorActive) {
      await stopDeveloperYamnetMonitor();
    }
    if (running && useMg24Data) {
      await disconnectMg24Sensors();
    } else {
      await stop();
      await disconnectMg24Sensors();
    }
    await disconnectRadar();
  }

  Future<void> openCurrentCsv() async {
    final file = await _requireCsvFile();
    if (file == null) return;

    await _flushCsv();
    final result = await OpenFilex.open(file.path, type: 'text/csv');
    if (result.type == ResultType.done) {
      snapshot =
          snapshot.copyWith(status: 'CSV geoeffnet: ${_fileName(file.path)}');
    } else if (result.type == ResultType.noAppToOpen) {
      snapshot = snapshot.copyWith(
        status:
            'Keine App zum Oeffnen von CSV gefunden. Bitte "Teilen" verwenden.',
      );
    } else {
      snapshot = snapshot.copyWith(
        status: 'CSV konnte nicht geoeffnet werden: ${result.message}',
      );
    }
    notifyListeners();
  }

  Future<void> shareCurrentCsv() async {
    final file = await _requireCsvFile();
    if (file == null) return;

    await _flushCsv();
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            mimeType: 'text/csv',
            name: _fileName(file.path),
          ),
        ],
        subject: 'LASLI Messung',
        text: 'LASLI CSV-Datei: ${_fileName(file.path)}',
      ),
    );
  }

  Future<String?> readCurrentCsvPreview({int maxLines = 120}) async {
    final file = await _requireCsvFile();
    if (file == null) return null;

    await _flushCsv();
    final lines = await file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .take(maxLines + 1)
        .toList();
    if (lines.length > maxLines) {
      return [
        ...lines.take(maxLines),
        '',
        '... Vorschau nach $maxLines Zeilen gekuerzt.',
      ].join('\n');
    }
    return lines.join('\n');
  }

  Future<void> openSleepSessionsCsv() async {
    final file = await _sleepSessionsCsvFile(create: true);
    if (!await file.exists()) {
      await file.writeAsString('${sleepSessionCsvColumns.join(',')}\n');
    }
    final result = await OpenFilex.open(file.path, type: 'text/csv');
    if (result.type == ResultType.done) {
      snapshot = snapshot.copyWith(status: 'Schlafzyklen-CSV geoeffnet.');
    } else {
      snapshot = snapshot.copyWith(
        status:
            'Schlafzyklen-CSV konnte nicht geoeffnet werden: ${result.message}',
      );
    }
    notifyListeners();
  }

  Future<void> shareSleepSessionsCsv() async {
    final file = await _sleepSessionsCsvFile(create: true);
    if (!await file.exists()) {
      await file.writeAsString('${sleepSessionCsvColumns.join(',')}\n');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            mimeType: 'text/csv',
            name: _fileName(file.path),
          ),
        ],
        subject: 'LASLI Schlafzyklen',
        text: 'LASLI Schlafzyklen-CSV',
      ),
    );
  }

  void _resetMeasurement() {
    _heartDetector = HeartRateDetector(samplingRate);
    _breathingDetector = BreathingRateDetector(samplingRate);
    _mg24BreathingDetector = null;
    _orientationEstimator = OrientationEstimator();
    _csvAggregator = CsvWindowAggregator(csvWriteIntervalSeconds);
    _sampleNumber = 0;
    _rPeakCount = 0;
    _breathCount = 0;
    _heartRate = null;
    _breathingRate = null;
    _mg24BreathingRate = null;
    _mg24BreathingSignal = null;
    _mg24BreathingAxis = null;
    _mg24BreathingQuality = null;
    _imuSnoreVibrationDetector.reset();
    _mg24AudioSnoreDetector.reset();
    _yamnetRawSnoreTracker.reset();
    _measurementYamnetWindows.clear();
    _liveYamnetWindows.clear();
    _measurementYamnetCaptureActive = false;
    _measurementYamnetWasRecorded = false;
    _mg24YamnetTeacherActive = false;
    _mg24YamnetTeacherStartInProgress = false;
    _mg24LiveStartedAt = null;
    _mg24ConnectionLossCount = 0;
    _lastMg24ConnectionLostAt = null;
    _mg24MeasurementRoles = const {};
    _persistedMg24RemoteIds = const {};
    _activeBoardSessionId = null;
    _clearMg24PoseCalibration();
    _oxygenSaturation = null;
    _orientation = const OrientationState.empty();
    _snore = const SnoreState.empty();
    _sleepStats.reset();
    _pendingRecoveredBoardSummary = null;
    _snoreTimeline.clear();
    _activeSnoreStartedAt = null;
    _activeSnoreSource = 'unknown';
    _activeSnoreSourceConfidence = 0;
    _resetSnoreSourceTracking();
    _samples.clear();
    _rPeaks.clear();
    _breathPeaks.clear();
    _mg24BreathSignalSequences.clear();
    _mg24BreathSignalBySequence.clear();
    _mg24BreathPeakSequences.clear();
    _mg24BreathPeakSequenceSet.clear();
    _mg24PendingBreathPeakSequences.clear();
    _mg24PendingBreathPeaks.clear();
    _resetLiveMg24SnoreSourceTracking();
    _mg24BellyPlotAnchorTimeS = null;
    _mg24BellyPlotAnchorSequence = null;
    _mg24BellyPlotSamplePeriodS = null;
    _mg24BellyPlotAnchorAt = null;
    _resetMg24SensorClocks();
    _snoreBreathWindows.clear();
    _recentConfirmedSnoreBreathWindows.clear();
    _scheduledSnoreBreathWindows.clear();
    _pendingMg24SnoreTimingWindows.clear();
    _activeMg24SnoreTimingWindow = null;
    _lastRecordedMg24SnoreBurstCounter = null;
  }

  void _recoverSleepSessionFromBoardArchive(
    Map<Mg24SensorRole, Mg24DownloadedArchive> archives,
  ) {
    if (archives.isEmpty) return;
    final forehead = archives[Mg24SensorRole.forehead];
    final belly = archives[Mg24SensorRole.belly];
    final primary = forehead ?? belly;
    if (primary == null) return;

    final startedAt = _archiveStartedAt(
      sessionId: primary.status.sessionId,
      unixStartMinute: primary.status.unixStartMinute,
    );
    final recordCount = math.max(
      forehead?.status.recordCount ?? 0,
      belly?.status.recordCount ?? 0,
    );
    final archivedEndedAt = startedAt.add(
      Duration(minutes: math.max(1, recordCount)),
    );
    final requestedEndedAt = _sleepCycleEndedAt;
    final endedAt = requestedEndedAt != null &&
            requestedEndedAt.difference(archivedEndedAt).abs() <=
                const Duration(minutes: 2)
        ? requestedEndedAt
        : archivedEndedAt;
    final heartRates = forehead?.records
            .map((record) => record.heartRateBpm)
            .whereType<double>() ??
        const <double>[];
    final breathingRates = belly?.records
            .map((record) => record.respirationRatePerMin)
            .whereType<double>() ??
        const <double>[];
    final earTemperatures = forehead?.records
            .map((record) => record.temperatureC)
            .whereType<double>()
            .where((value) => value >= 30 && value <= 42) ??
        const <double>[];
    final boardSnoreSeconds = forehead?.records.fold<int>(
          0,
          (sum, record) => sum + ((record.snoreSeconds ?? 0) > 0 ? 60 : 0),
        ) ??
        0;
    final durationSeconds = math.max(
      1.0,
      endedAt.difference(startedAt).inMilliseconds / 1000.0,
    );

    _sleepCycleStartedAt = startedAt;
    _pendingEveningAnswers ??= <String, int>{};
    _pendingRecoveredBoardSummary = SleepMeasurementSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: durationSeconds,
      meanHeartRateBpm: _robustMeanSeriesValue(
        heartRates,
        rejectDistance: 12,
      ),
      meanBreathingRatePerMin: _robustMeanSeriesValue(
        breathingRates,
        rejectDistance: 4,
      ),
      meanEarTemperatureC: _robustMeanSeriesValue(
        earTemperatures,
        rejectDistance: 0.4,
      ),
      meanRelativeAngleDeg: null,
      snoreTimeFraction: ((_measurementYamnetWasRecorded
                  ? _measurementYamnetPhaseSeconds(startedAt, endedAt)
                  : boardSnoreSeconds) /
              durationSeconds)
          .clamp(0.0, 1.0)
          .toDouble(),
      relativeAngleSnore: const RelativeAngleSnoreAnalysis.empty(),
      poseSnore: const PoseSnoreAnalysis.empty(),
    );
  }

  Future<void> _openCsv() async {
    final dir = await _csvDirectory(create: true);
    final stamp = _timestamp();
    _csvFile = File('${dir.path}${Platform.pathSeparator}messung_$stamp.csv');
    _csvSink = _csvFile!.openWrite();
    _csvSink!.writeln(csvColumns.join(','));
    snapshot = snapshot.copyWith(
      fileLabel: 'CSV: messung_$stamp.csv',
      csvPath: _csvFile!.path,
      csvDirectoryPath: dir.path,
    );
    notifyListeners();
  }

  Future<String?> _writeMg24MinuteArchive(
    Map<Mg24SensorRole, Mg24DownloadedArchive> archives,
  ) async {
    if (archives.isEmpty) return null;
    final forehead = archives[Mg24SensorRole.forehead];
    final belly = archives[Mg24SensorRole.belly];
    final primary = forehead ?? belly;
    if (primary == null) return null;
    final directory =
        _csvFile?.parent ?? await getApplicationDocumentsDirectory();
    final startedAt = _archiveStartedAt(
      sessionId: primary.status.sessionId,
      unixStartMinute: primary.status.unixStartMinute,
    );
    final stamp = _fileTimestamp(startedAt);
    final file = File(
      '${directory.path}${Platform.pathSeparator}mg24_minuten_$stamp.csv',
    );
    final foreheadByMinute = {
      for (final record in forehead?.records ?? const <Mg24MinuteRecord>[])
        record.minuteIndex: record,
    };
    final bellyByMinute = {
      for (final record in belly?.records ?? const <Mg24MinuteRecord>[])
        record.minuteIndex: record,
    };
    final count = math.max(
      forehead?.status.recordCount ?? 0,
      belly?.status.recordCount ?? 0,
    );
    final sink = file.openWrite();
    sink.writeln([
      'Uhrzeit',
      'Minute',
      'Herzfrequenz_bpm',
      'SpO2_Prozent',
      'Atemfrequenz_pro_min',
      'Geschnarcht',
      'Geschnarcht_Sekunden',
      'Schnarchlautstaerke_Prozent',
      'YAMNet_Geschnarcht_Sekunden',
      'YAMNet_Schnarchzuege',
      'Ohrtemperatur_C',
      'Stirn_Roll_Grad',
      'Stirn_Pitch_Grad',
      'Stirn_Yaw_Grad',
      'Bauch_Roll_Grad',
      'Bauch_Pitch_Grad',
      'Bauch_Yaw_Grad',
      'Relativ_Yaw_Grad',
      'MAX_Qualitaet_Prozent',
      'Atmung_Qualitaet_Prozent',
      'Akku_Stirn_Prozent',
      'Akku_Bauch_Prozent',
    ].join(','));
    for (var minute = 0; minute < count; minute++) {
      final head = foreheadByMinute[minute];
      final chest = bellyByMinute[minute];
      final time = startedAt.add(Duration(minutes: minute));
      final yamnet = _measurementYamnetMinute(time);
      sink.writeln([
        time.toIso8601String(),
        minute,
        _csvNumber(head?.heartRateBpm, 0),
        _csvNumber(head?.spo2Percent, 0),
        _csvNumber(chest?.respirationRatePerMin, 1),
        _csvSnoreSeen(head?.snoreSeconds),
        head?.snoreSeconds?.toString() ?? '',
        _csvNumber(head?.snoreVolumePercent, 0),
        _csvNumber(yamnet?.seconds, 2),
        yamnet?.count.toString() ?? '',
        _csvNumber(head?.temperatureC, 2),
        _csvNumber(head?.rollDeg, 2),
        _csvNumber(head?.pitchDeg, 2),
        _csvNumber(head?.yawDeg, 2),
        _csvNumber(chest?.rollDeg, 2),
        _csvNumber(chest?.pitchDeg, 2),
        _csvNumber(chest?.yawDeg, 2),
        _csvNumber(_archiveRelativeYawDeg(head, chest), 2),
        _csvNumber(head?.ppgQuality, 0),
        _csvNumber(chest?.respirationQuality, 0),
        _csvNumber(head?.batteryPercent, 0),
        _csvNumber(chest?.batteryPercent, 0),
      ].join(','));
    }
    await sink.flush();
    await sink.close();
    return file.path;
  }

  Future<String?> _writeMg24EventArchive(
    Map<Mg24SensorRole, Mg24DownloadedEventArchive> archives,
  ) async {
    if (archives.isEmpty) return null;
    final forehead = archives[Mg24SensorRole.forehead];
    final belly = archives[Mg24SensorRole.belly];
    final primary = forehead ?? belly;
    if (primary == null) return null;
    final directory =
        _csvFile?.parent ?? await getApplicationDocumentsDirectory();
    final startedAt = _archiveStartedAt(
      sessionId: primary.status.sessionId,
      unixStartMinute: primary.status.unixStartMinute,
    );
    final stamp = _fileTimestamp(startedAt);
    final file = File(
      '${directory.path}${Platform.pathSeparator}mg24_events_$stamp.csv',
    );

    final breathEvents = belly?.status.kind == Mg24EventKind.breathCycle
        ? belly!.records
        : const <Mg24EventRecord>[];
    final boardSnoreEvents = forehead?.status.kind == Mg24EventKind.snoreWindow
        ? forehead!.records
        : const <Mg24EventRecord>[];
    final yamnetSnoreEvents = _measurementYamnetEventRecords(startedAt);
    final usesYamnetEvents = yamnetSnoreEvents.isNotEmpty;
    final snoreEvents = usesYamnetEvents ? yamnetSnoreEvents : boardSnoreEvents;
    final sourceBySnore = _classifyOfflineSnoreSources(
      snoreEvents,
      breathEvents,
      snoreBoundaryUncertaintyS:
          usesYamnetEvents ? yamnetBoundaryUncertaintySeconds : 0,
    );
    final rows = <_Mg24OfflineEventRow>[
      for (final event in breathEvents)
        _Mg24OfflineEventRow(
          role: Mg24SensorRole.belly,
          kind: Mg24EventKind.breathCycle,
          record: event,
        ),
      for (final event in snoreEvents)
        _Mg24OfflineEventRow(
          role: Mg24SensorRole.forehead,
          kind: Mg24EventKind.snoreWindow,
          record: event,
          source: sourceBySnore[event],
          detector: usesYamnetEvents ? 'YAMNet' : 'MG24',
        ),
    ]..sort((a, b) => a.record.startSeconds.compareTo(b.record.startSeconds));

    final sink = file.openWrite();
    sink.writeln([
      'Uhrzeit',
      'Sensor',
      'Event_Typ',
      'Detektor',
      'Start_s',
      'Ende_s',
      'Dauer_s',
      'Qualitaet_Prozent',
      'Quelle',
      'Quelle_Konfidenz_Prozent',
      'Atem_Overlap_Prozent',
      'Atem_Phase',
      'Atem_Start_s',
      'Atem_Ende_s',
      'Atem_Dauer_s',
    ].join(','));
    for (final row in rows) {
      final event = row.record;
      final source = row.source;
      final time = startedAt.add(
        Duration(milliseconds: (event.startSeconds * 1000).round()),
      );
      sink.writeln([
        time.toIso8601String(),
        row.role.label,
        row.kind == Mg24EventKind.snoreWindow
            ? 'Schnarchfenster'
            : 'Atemzyklus',
        row.detector,
        event.startSeconds.toStringAsFixed(2),
        event.endSeconds.toStringAsFixed(2),
        event.durationSeconds.toStringAsFixed(2),
        event.qualityPercent.toStringAsFixed(0),
        source?.source ?? '',
        source == null ? '' : (source.confidence * 100).toStringAsFixed(0),
        source == null ? '' : (source.overlapRatio * 100).toStringAsFixed(0),
        source?.phaseLabel ?? '',
        _csvNumber(source?.breathStartS, 2),
        _csvNumber(source?.breathEndS, 2),
        _csvNumber(source?.breathDurationS, 2),
      ].join(','));
    }
    await sink.flush();
    await sink.close();
    return file.path;
  }

  List<Mg24EventRecord> _measurementYamnetEventRecords(DateTime startedAt) {
    if (!_measurementYamnetWasRecorded || _measurementYamnetWindows.isEmpty) {
      return const <Mg24EventRecord>[];
    }
    final records = <Mg24EventRecord>[];
    for (final window in _measurementYamnetWindows) {
      final startS = window.startAt.difference(startedAt).inMicroseconds /
          Duration.microsecondsPerSecond;
      final endS = window.endAt.difference(startedAt).inMicroseconds /
          Duration.microsecondsPerSecond;
      if (!startS.isFinite || !endS.isFinite || endS <= 0) continue;
      final clippedStartS = math.max(0.0, startS);
      final durationS = endS - clippedStartS;
      if (durationS <= 0) continue;
      records.add(
        Mg24EventRecord(
          startTick: (clippedStartS / Mg24EventRecord.tickSeconds)
              .round()
              .clamp(0, 0xFFFFFFFF),
          durationTicks:
              (durationS / Mg24EventRecord.tickSeconds).round().clamp(1, 255),
          qualityPercent: 100,
        ),
      );
    }
    records.sort((a, b) => a.startTick.compareTo(b.startTick));
    return records;
  }

  _Mg24OfflineSnoreSource _classifyOfflineSnoreSource(
    Mg24EventRecord snore,
    List<Mg24EventRecord> breaths,
    _Mg24OfflinePhasePreference phasePreference, {
    double snoreBoundaryUncertaintyS = 0,
  }) {
    if (breaths.isEmpty || !_hasOfflineBreathCoverage(snore, breaths)) {
      return const _Mg24OfflineSnoreSource(
        source: 'unknown',
        confidence: 0,
        overlapRatio: 0,
      );
    }
    // Without a repeatable inhale half, the archive contains breathing data
    // but not enough evidence to align its polarity with inhalation.
    if (phasePreference.phase == 0) {
      return const _Mg24OfflineSnoreSource(
        source: 'unknown',
        confidence: 0,
        overlapRatio: 0,
      );
    }
    final best = _bestOfflineBreathHalfOverlap(
      snore,
      breaths,
      preferredPhase: phasePreference.phase,
      snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
    );
    final snoreDuration = math.max(
      0.08,
      _snoreEvaluationBounds(
        snore,
        snoreBoundaryUncertaintyS,
      ).durationS,
    );
    final overlapRatio = best.overlapS / snoreDuration;
    if (best.phase == 0 || overlapRatio < 0.22) {
      return const _Mg24OfflineSnoreSource(
        source: 'external',
        confidence: 0.78,
        overlapRatio: 0,
      );
    }
    if (!_isOfflineSnoreDurationPlausible(snoreDuration, best)) {
      return _Mg24OfflineSnoreSource(
        source: 'unknown',
        confidence: 0,
        overlapRatio: overlapRatio,
        phase: best.phase,
        breathStartS: best.startS,
        breathEndS: best.endS,
      );
    }
    if (overlapRatio >= 0.72) {
      return _Mg24OfflineSnoreSource(
        source: 'wearer',
        confidence: math.min(0.96, 0.42 + overlapRatio * 0.52),
        overlapRatio: overlapRatio,
        phase: best.phase,
        breathStartS: best.startS,
        breathEndS: best.endS,
      );
    }
    return _Mg24OfflineSnoreSource(
      source: 'unknown',
      confidence: 0,
      overlapRatio: overlapRatio,
      phase: best.phase,
      breathStartS: best.startS,
      breathEndS: best.endS,
    );
  }

  Map<Mg24EventRecord, _Mg24OfflineSnoreSource> _classifyOfflineSnoreSources(
    List<Mg24EventRecord> snores,
    List<Mg24EventRecord> breaths, {
    double snoreBoundaryUncertaintyS = 0,
  }) {
    final result = Map<Mg24EventRecord, _Mg24OfflineSnoreSource>.identity();
    if (snores.isEmpty) return result;

    final sortedSnores = [...snores]
      ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    final sortedBreaths = [...breaths]
      ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    final globalPhasePreference = _offlineBreathPhasePreference(
      sortedSnores,
      sortedBreaths,
      snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
    );
    final phases = <List<Mg24EventRecord>>[];
    var currentPhase = <Mg24EventRecord>[];
    for (final snore in sortedSnores) {
      final previous = currentPhase.isEmpty ? null : currentPhase.last;
      final gapS =
          previous == null ? 0.0 : snore.startSeconds - previous.endSeconds;
      if (previous != null && gapS > 10.0) {
        phases.add(currentPhase);
        currentPhase = <Mg24EventRecord>[];
      }
      currentPhase.add(snore);
    }
    if (currentPhase.isNotEmpty) phases.add(currentPhase);

    for (final phase in phases) {
      // The projected belly signal can invert after a posture change. Prefer a
      // stable night-wide polarity, but learn it within this snore phase when
      // both halves are equally represented across the whole night.
      final phasePreference = globalPhasePreference.phase != 0
          ? globalPhasePreference
          : _offlineBreathPhasePreference(
              phase,
              sortedBreaths,
              snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
            );
      final evidence = <_Mg24SnorePhaseEvidence>[];
      final alignedBreathCycles = <int>{};
      var coveredWindowCount = 0;
      var alignedWindowCount = 0;
      for (final snore in phase) {
        final covered = phasePreference.phase != 0 &&
            _hasOfflineBreathCoverage(snore, sortedBreaths);
        final best = phasePreference.phase == 0
            ? const _Mg24OfflineHalfOverlap()
            : _bestOfflineBreathHalfOverlap(
                snore,
                sortedBreaths,
                preferredPhase: phasePreference.phase,
                snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
              );
        final individual = _classifyOfflineSnoreSource(
          snore,
          sortedBreaths,
          phasePreference,
          snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
        );
        final aligned = covered && individual.source == 'wearer';
        if (covered) coveredWindowCount++;
        if (aligned) {
          alignedWindowCount++;
          if (best.startS != null) {
            alignedBreathCycles.add(
              (best.startS! / Mg24EventRecord.tickSeconds).round(),
            );
          }
        }
        evidence.add(
          _Mg24SnorePhaseEvidence(
            snore: snore,
            covered: covered,
            aligned: aligned,
            best: best,
            individual: individual,
          ),
        );
      }

      final alignedRatio = coveredWindowCount == 0
          ? 0.0
          : alignedWindowCount / coveredWindowCount;
      final hasCoverageContext =
          coveredWindowCount >= 3 && phasePreference.phase != 0;
      String phaseSource;
      double phaseConfidence;
      if (!hasCoverageContext) {
        phaseSource = 'unknown';
        phaseConfidence = 0;
      } else if (alignedRatio >= 0.70 && alignedBreathCycles.length >= 3) {
        phaseSource = 'wearer';
        phaseConfidence = math.min(
          0.96,
          0.50 +
              alignedRatio * 0.25 +
              math.min(1.0, alignedBreathCycles.length / 5.0) * 0.10 +
              phasePreference.confidence * 0.11,
        );
      } else if (alignedRatio <= 0.35) {
        phaseSource = 'external';
        phaseConfidence = math.min(
          0.92,
          0.56 +
              (1.0 - alignedRatio) * 0.22 +
              phasePreference.confidence * 0.10,
        );
      } else {
        phaseSource = 'unknown';
        phaseConfidence = 0;
      }

      for (final item in evidence) {
        final snoreDuration = math.max(
          0.08,
          _snoreEvaluationBounds(
            item.snore,
            snoreBoundaryUncertaintyS,
          ).durationS,
        );
        final overlapRatio =
            item.covered ? item.best.overlapS / snoreDuration : 0.0;
        final source =
            phaseSource == item.individual.source ? phaseSource : 'unknown';
        result[item.snore] = _Mg24OfflineSnoreSource(
          source: source,
          confidence: source == 'unknown' ? 0 : phaseConfidence,
          overlapRatio: overlapRatio,
          phase: item.covered ? item.best.phase : 0,
          breathStartS: item.covered ? item.best.startS : null,
          breathEndS: item.covered ? item.best.endS : null,
        );
      }
    }
    return result;
  }

  @visibleForTesting
  String classifyOfflineSnoreSourceForTest({
    required Mg24EventRecord snore,
    required List<Mg24EventRecord> breaths,
    required List<Mg24EventRecord> snores,
    double snoreBoundaryUncertaintyS = 0,
  }) {
    return _normalizeSnoreSource(
          _classifyOfflineSnoreSources(
            snores,
            breaths,
            snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
          )[snore]
              ?.source,
        ) ??
        'unknown';
  }

  bool _hasOfflineBreathCoverage(
    Mg24EventRecord snore,
    List<Mg24EventRecord> breaths,
  ) {
    final centerS = (snore.startSeconds + snore.endSeconds) * 0.5;
    for (final breath in breaths) {
      if (breath.endSeconds < centerS) continue;
      if (breath.startSeconds > centerS) return false;
      return breath.startSeconds <= centerS && breath.endSeconds >= centerS;
    }
    return false;
  }

  _Mg24OfflinePhasePreference _offlineBreathPhasePreference(
    List<Mg24EventRecord> snores,
    List<Mg24EventRecord> breaths, {
    double snoreBoundaryUncertaintyS = 0,
  }) {
    var phase1Overlap = 0.0;
    var phase2Overlap = 0.0;
    for (final snore in snores) {
      if (snore.durationSeconds < 0.16 || snore.durationSeconds > 6.0) {
        continue;
      }
      phase1Overlap += _bestOfflineBreathHalfOverlap(
        snore,
        breaths,
        preferredPhase: 1,
        snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
      ).overlapS;
      phase2Overlap += _bestOfflineBreathHalfOverlap(
        snore,
        breaths,
        preferredPhase: 2,
        snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
      ).overlapS;
    }
    final best = math.max(phase1Overlap, phase2Overlap);
    final other = math.min(phase1Overlap, phase2Overlap);
    if (best < 0.8 || best < other * 1.28) {
      return const _Mg24OfflinePhasePreference(phase: 0, confidence: 0);
    }
    return _Mg24OfflinePhasePreference(
      phase: phase1Overlap > phase2Overlap ? 1 : 2,
      confidence: ((best - other) / math.max(0.1, best)).clamp(0.0, 1.0),
    );
  }

  bool _isOfflineSnoreDurationPlausible(
    double duration,
    _Mg24OfflineHalfOverlap breathHalf,
  ) {
    if (duration < 0.16 || duration > 6.0 || breathHalf.durationS <= 0) {
      return false;
    }
    final durationRatio = duration / breathHalf.durationS;
    return durationRatio >= 0.12 && durationRatio <= 1.90;
  }

  _Mg24OfflineHalfOverlap _bestOfflineBreathHalfOverlap(
    Mg24EventRecord snore,
    List<Mg24EventRecord> breaths, {
    required int preferredPhase,
    double snoreBoundaryUncertaintyS = 0,
  }) {
    final evaluation = _snoreEvaluationBounds(snore, snoreBoundaryUncertaintyS);
    var best = const _Mg24OfflineHalfOverlap();
    for (final breath in breaths) {
      if (breath.endSeconds < evaluation.startS - 1.0) continue;
      if (breath.startSeconds > evaluation.endS + 1.0) break;
      final half = breath.durationSeconds * 0.5;
      final phases = preferredPhase == 0
          ? const [1, 2]
          : <int>[preferredPhase.clamp(1, 2)];
      for (final phase in phases) {
        final startS =
            phase == 1 ? breath.startSeconds : breath.startSeconds + half;
        final endS =
            phase == 1 ? breath.startSeconds + half : breath.endSeconds;
        final overlap = math.max(
          0.0,
          math.min(evaluation.endS, endS) - math.max(evaluation.startS, startS),
        );
        if (overlap > best.overlapS) {
          best = _Mg24OfflineHalfOverlap(
            overlapS: overlap,
            phase: phase,
            startS: startS,
            endS: endS,
          );
        }
      }
    }
    return best;
  }

  ({double startS, double endS, double durationS}) _snoreEvaluationBounds(
    Mg24EventRecord snore,
    double boundaryUncertaintyS,
  ) {
    final rawDuration = math.max(0.0, snore.durationSeconds);
    final maximumTrim = math.max(0.0, (rawDuration - 0.16) * 0.5);
    final trim = math.min(
      math.max(0.0, boundaryUncertaintyS),
      maximumTrim,
    );
    final startS = snore.startSeconds + trim;
    final endS = math.max(startS, snore.endSeconds - trim);
    return (startS: startS, endS: endS, durationS: endS - startS);
  }

  String _csvNumber(double? value, int decimals) =>
      value == null || !value.isFinite ? '' : value.toStringAsFixed(decimals);

  DateTime _archiveStartedAt({
    required int sessionId,
    required int unixStartMinute,
  }) {
    final appStart = _sleepCycleStartedAt ?? _measurementStartedAt;
    if (appStart != null &&
        appStart.millisecondsSinceEpoch ~/ 60000 == unixStartMinute &&
        (_activeBoardSessionId == null ||
            (_activeBoardSessionId! & 0xffff) == sessionId)) {
      return appStart;
    }
    return DateTime.fromMillisecondsSinceEpoch(
      unixStartMinute * 60000,
    ).toLocal();
  }

  ({double seconds, int count})? _measurementYamnetMinute(DateTime start) {
    if (!_measurementYamnetWasRecorded) return null;
    final end = start.add(const Duration(minutes: 1));
    var seconds = 0.0;
    var count = 0;
    for (final window in _measurementYamnetWindows) {
      if (!window.startAt.isBefore(end) || !window.endAt.isAfter(start)) {
        continue;
      }
      final overlapStart =
          window.startAt.isAfter(start) ? window.startAt : start;
      final overlapEnd = window.endAt.isBefore(end) ? window.endAt : end;
      seconds += overlapEnd.difference(overlapStart).inMicroseconds /
          Duration.microsecondsPerSecond;
      if (!window.startAt.isBefore(start) && window.startAt.isBefore(end)) {
        count++;
      }
    }
    return (
      seconds: seconds.clamp(0.0, 60.0).toDouble(),
      count: count,
    );
  }

  double _measurementYamnetPhaseSeconds(DateTime startedAt, DateTime endedAt) {
    if (!_measurementYamnetWasRecorded || !endedAt.isAfter(startedAt)) return 0;
    var seconds = 0.0;
    var minuteStart = startedAt;
    while (minuteStart.isBefore(endedAt)) {
      final minuteEnd = minuteStart.add(const Duration(minutes: 1));
      final yamnet = _measurementYamnetMinute(minuteStart);
      if ((yamnet?.seconds ?? 0) > 0) {
        final clippedEnd = minuteEnd.isBefore(endedAt) ? minuteEnd : endedAt;
        seconds += clippedEnd.difference(minuteStart).inMicroseconds /
            Duration.microsecondsPerSecond;
      }
      minuteStart = minuteEnd;
    }
    final durationSeconds = endedAt.difference(startedAt).inMicroseconds /
        Duration.microsecondsPerSecond;
    return seconds.clamp(0.0, durationSeconds).toDouble();
  }

  double? _archiveRelativeYawDeg(
    Mg24MinuteRecord? forehead,
    Mg24MinuteRecord? belly,
  ) {
    final foreheadYaw = forehead?.yawDeg;
    final bellyYaw = belly?.yawDeg;
    if (!_isFinite(foreheadYaw) || !_isFinite(bellyYaw)) return null;
    return 0;
  }

  String _csvSnoreSeen(int? snoreSeconds) =>
      snoreSeconds == null ? '' : (snoreSeconds > 0 ? '1' : '0');

  Future<void> _startSnoreDetector() async {
    if (_snoreDetector != null) return;
    late final AudioSnoreDetector detector;
    try {
      _snore = const SnoreState.empty();
      _yamnetRawSnoreTracker.reset();
      _resetSnoreSourceTracking();
      detector = AudioSnoreDetector(
        onEnergyFrame: (frame) {
          if (!identical(_snoreDetector, detector) ||
              !_snoreAutomaticTeacherMode) {
            return;
          }
          _snoreTeacherSynchronizer.addPhoneEnergy(
            centerMonotonicUs: frame.centerMonotonicUs,
            rmsDb: frame.rmsDb,
          );
        },
        onInference: (frame) {
          if (identical(_snoreDetector, detector)) {
            _handleYamnetInference(detector, frame);
          }
        },
      );
      _snoreDetector = detector;
      await detector.start();
    } catch (error) {
      if (identical(_snoreDetector, detector)) {
        _snoreDetector = null;
      }
      try {
        await detector.stop();
      } catch (_) {}
      snapshot = snapshot.copyWith(
        status: 'Schnarcherkennung deaktiviert: $error',
      );
      notifyListeners();
    }
  }

  void _handleYamnetInference(
    AudioSnoreDetector detector,
    YamnetInferenceFrame frame,
  ) {
    final result = _yamnetRawSnoreTracker.update(
      detector,
      AppMonotonicClock.wallTime(frame.endMonotonicUs),
      threshold: _snoreAutomaticTeacherMode
          ? yamnetRawTeacherSnoreThreshold
          : yamnetMeasurementSnoreThreshold,
      minimumConsecutiveCandidates: _snoreAutomaticTeacherMode
          ? 1
          : yamnetMeasurementMinimumConsecutiveFrames,
      decisionScore:
          _snoreAutomaticTeacherMode ? detector.rawScore : frame.decisionScore,
    );
    final completed = result.completedWindow;
    if (_snoreAutomaticTeacherMode && completed != null) {
      _addAutomaticTeacherWindow(completed);
    }
    if (_measurementYamnetCaptureActive && completed != null) {
      _addMeasurementYamnetWindow(completed);
    }
    if ((_measurementYamnetCaptureActive || _developerYamnetMonitorActive) &&
        completed != null) {
      _addLiveYamnetWindow(completed);
    }
    if (_measurementYamnetCaptureActive || _developerYamnetMonitorActive) {
      final measuredAt = AppMonotonicClock.wallTime(frame.endMonotonicUs);
      final timeS = _measurementSecondsAt(measuredAt);
      final yamnetSnore = _snoreStateWithSource(
        _snoreStateFromYamnet(detector, result),
        timeS,
      );
      _snore = _withRecentHomeSnorePhaseHold(yamnetSnore, measuredAt);
      if (running) {
        _updateSnoreTimeline(yamnetSnore, measuredAt);
      }
    }
    _publishIfNeeded();
  }

  double _measurementSecondsAt(DateTime time) {
    final startedAt = _measurementStartedAt ?? _sleepCycleStartedAt;
    if (startedAt == null) return _elapsedSeconds();
    return math.max(
      0.0,
      time.difference(startedAt).inMicroseconds /
          Duration.microsecondsPerSecond,
    );
  }

  SnoreState _snoreStateFromYamnet(
    AudioSnoreDetector detector,
    YamnetRawSnoreResult result,
  ) {
    final completed = result.completedWindow;
    final activeStartAt = result.activeStartAt;
    final activeEndAt = result.activeEndAt;
    final activeWidthMs = activeStartAt == null || activeEndAt == null
        ? null
        : activeEndAt.difference(activeStartAt).inMicroseconds /
            Duration.microsecondsPerMillisecond;
    final windowCenterAt = result.active
        ? detector.rawWindowCenterAt
        : completed?.startAt.add(
            Duration(
              microseconds: completed.endAt
                      .difference(completed.startAt)
                      .inMicroseconds ~/
                  2,
            ),
          );
    return SnoreState(
      isSnoring: result.active,
      detectedNow: result.detectedNow,
      score: result.rawScore.clamp(0.0, 1.0).toDouble(),
      rmsDb: result.rmsDb,
      snoreCount: result.windowId,
      backend: 'yamnet',
      inferenceId: result.inferenceId,
      windowCenterAt: windowCenterAt,
      snoreRatePerMin: result.snoreRatePerMin,
      snoreBreathWidthMs: completed?.widthMs,
      snoreBurstActive: result.active,
      snoreActiveWidthMs: activeWidthMs,
    );
  }

  void _addMeasurementYamnetWindow(YamnetRawSnoreWindow window) {
    if (!window.endAt.isAfter(window.startAt)) return;
    for (final existing in _measurementYamnetWindows) {
      final startDistance =
          existing.startAt.difference(window.startAt).inMilliseconds.abs();
      final endDistance =
          existing.endAt.difference(window.endAt).inMilliseconds.abs();
      if (startDistance <= 20 && endDistance <= 20) return;
    }
    _measurementYamnetWindows.add(window);
  }

  void _addLiveYamnetWindow(YamnetRawSnoreWindow window) {
    if (!window.endAt.isAfter(window.startAt)) return;
    for (final existing in _liveYamnetWindows) {
      final startDistance =
          existing.startAt.difference(window.startAt).inMilliseconds.abs();
      final endDistance =
          existing.endAt.difference(window.endAt).inMilliseconds.abs();
      if (startDistance <= 20 && endDistance <= 20) return;
    }
    _liveYamnetWindows.addLast(window);
    while (_liveYamnetWindows.length > 120) {
      _liveYamnetWindows.removeFirst();
    }
    _refreshLiveConfirmedSnoreSource();
  }

  void _finishMeasurementYamnetCapture(DateTime endedAt) {
    if (!_measurementYamnetCaptureActive) return;
    final completed = _yamnetRawSnoreTracker.finish(endedAt);
    if (completed != null) _addMeasurementYamnetWindow(completed);
    _measurementYamnetCaptureActive = false;
    _measurementYamnetWindows.sort(
      (a, b) => a.startAt.compareTo(b.startAt),
    );
  }

  Future<void> _ensureMg24YamnetTeacher() async {
    if (_mg24YamnetTeacherStartInProgress) return;
    if (_snoreDetector != null) {
      _mg24YamnetTeacherActive = true;
      await _ensureYamnetTeacherLog();
      return;
    }
    _mg24YamnetTeacherStartInProgress = true;
    try {
      final granted = await _ensureMicrophonePermission();
      if (!granted) {
        snapshot = snapshot.copyWith(
          status: 'YAMNet-Teacher deaktiviert: Mikrofonberechtigung fehlt.',
        );
        notifyListeners();
        return;
      }
      await _startSnoreDetector();
      if (_snoreDetector != null) {
        _mg24YamnetTeacherActive = true;
        await _ensureYamnetTeacherLog();
      }
    } finally {
      _mg24YamnetTeacherStartInProgress = false;
    }
  }

  Future<void> _ensureYamnetTeacherLog() async {
    if (_yamnetTeacherSink != null) return;
    final dir = await _csvDirectory(create: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${dir.path}${Platform.pathSeparator}snore_teacher_yamnet_$stamp.csv',
    );
    final sink = file.openWrite();
    sink.writeln(_snoreTrainingColumns.join(','));
    _yamnetTeacherSink = sink;
    snapshot = snapshot.copyWith(
      status:
          'YAMNet-Teacher loggt MG24-Mikrofeatures: ${_fileName(file.path)}',
      csvDirectoryPath: dir.path,
    );
    notifyListeners();
  }

  Future<void> _closeYamnetTeacherLog() async {
    final sink = _yamnetTeacherSink;
    _yamnetTeacherSink = null;
    if (sink == null) return;
    await sink.flush();
    await sink.close();
  }

  Future<void> _stopMg24YamnetTeacher() async {
    _mg24YamnetTeacherActive = false;
    _mg24YamnetTeacherStartInProgress = false;
    _developerYamnetMonitorActive = false;
    _developerYamnetMonitorStartInProgress = false;
    _yamnetMonitorForegroundOwner = false;
    await _closeYamnetTeacherLog();
    final detector = _snoreDetector;
    if (detector != null && !_snoreTrainingOwnsSnoreDetector && !running) {
      _snoreDetector = null;
      try {
        await detector.stop();
      } catch (_) {}
    }
    await _refreshForegroundService();
  }

  Future<void> _startMg24Measurement({
    Set<Mg24SensorRole>? requiredRoles,
    bool boardAlreadyArmed = false,
  }) async {
    _mg24BreathingDetector = ImuBreathingRateDetector(mg24SamplingRate);
    if (boardAlreadyArmed) {
      if (requiredRoles == null || requiredRoles.isEmpty) {
        throw StateError(
            'Keine Sensoren fuer den geplanten Start gespeichert.');
      }
      final client = _mg24Client;
      if (client == null) {
        throw StateError('XIAO MG24 Steuerkanal ist nicht verfuegbar.');
      }
      final sessionId = _activeBoardSessionId ??
          ((_measurementStartedAt ?? DateTime.now()).millisecondsSinceEpoch &
              0xffff);
      final confirmedRoles = await client.ensureScheduledBoardRecording(
        roles: requiredRoles,
        sessionId: sessionId,
        startedAt: _measurementStartedAt ?? DateTime.now(),
        notBefore: (_measurementScheduledStartAt ?? DateTime.now())
            .subtract(const Duration(seconds: 1)),
      );
      _mg24MeasurementRoles = Set.unmodifiable(requiredRoles);
      _calibrateMg24PoseForMeasurement();
      final roleText = requiredRoles.map((role) => role.label).join(' + ');
      final allConfirmed = confirmedRoles.length == requiredRoles.length;
      snapshot = snapshot.copyWith(
        status: allConfirmed
            ? 'Board-Messung gestartet: $roleText'
            : 'Startzeit erreicht: $roleText. Getrennte Sensoren starten autonom.',
        mg24: _mg24,
      );
      notifyListeners();
      return;
    }
    if (!_mg24.hasAnyData) {
      final connected = await connectMg24Sensors();
      if (!connected && !_mg24.hasAnyData) {
        throw StateError('XIAO MG24 konnte nicht verbunden werden.');
      }
    }

    final client = _mg24Client;
    if (client == null) {
      throw StateError('XIAO MG24 Steuerkanal ist nicht verfuegbar.');
    }
    final measurementRoles = requiredRoles ?? connectedMeasurementSensorRoles;
    if (measurementRoles.isEmpty) {
      throw StateError('XIAO MG24 liefert noch keine Messdaten.');
    }
    _mg24MeasurementRoles = Set.unmodifiable(measurementRoles);
    await client.setLiveMode(mg24LiveMode);
    final startedAt = _measurementStartedAt ?? DateTime.now();
    final sessionId = startedAt.millisecondsSinceEpoch & 0xffff;
    _activeBoardSessionId = sessionId;
    final remoteIds = <Mg24SensorRole, String>{};
    for (final role in measurementRoles) {
      final remoteId = switch (role) {
        Mg24SensorRole.forehead => _mg24.forehead.remoteId,
        Mg24SensorRole.belly => _mg24.belly.remoteId,
      };
      if (remoteId != null && remoteId.trim().isNotEmpty) {
        remoteIds[role] = remoteId;
      }
    }
    _persistedMg24RemoteIds = Map.unmodifiable(remoteIds);
    try {
      await client.startBoardRecording(
        sessionId: sessionId,
        startedAt: startedAt,
        roles: measurementRoles,
      );
    } on Mg24RecordingStartException catch (error) {
      _mg24MeasurementRoles = Set.unmodifiable(error.startedRoles);
      if (error.startedRoles.isNotEmpty) {
        try {
          await client.stopBoardRecording(roles: error.startedRoles);
        } catch (_) {}
      }
      rethrow;
    }
    await _persistActiveMeasurementSession(recording: true);

    _calibrateMg24PoseForMeasurement();
    final roleText = [
      if (measurementRoles.contains(Mg24SensorRole.forehead)) 'Stirn',
      if (measurementRoles.contains(Mg24SensorRole.belly)) 'Bauch',
    ].join(' + ');
    snapshot = snapshot.copyWith(
      status: measurementRoles.contains(Mg24SensorRole.belly)
          ? 'XIAO MG24 laeuft: $roleText'
          : 'XIAO MG24 laeuft: Stirn-only (HF, Ohrtemperatur, Kopfposition)',
      mg24: _mg24,
    );
    notifyListeners();
  }

  Future<void> _startRadarMeasurement() async {
    if (!_radar.connected) {
      final connected = await connectRadar(throwOnError: true);
      if (!connected) {
        throw StateError('Radar konnte nicht verbunden werden.');
      }
    }

    snapshot = snapshot.copyWith(
      status: 'Radar fuer Herz/Atmung laeuft',
    );
    notifyListeners();
    _processRadarTick();
    _radarTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _processRadarTick(),
    );
  }

  void _processRadarTick() {
    if (!running) return;

    final now = DateTime.now();
    final csvAggregator = _csvAggregator!;
    final timeS = _elapsedSeconds();
    final snore = _snoreStateAt(timeS);
    final orientation = _orientation;
    final csvOrientation =
        usePositionData ? orientation : _inactiveOrientationState;
    final heartRate = _radar.heartRateBpm;
    final breathingRate = _radar.breathingRatePerMin;

    _heartRate = heartRate;
    _breathingRate = breathingRate;
    _orientation = orientation;
    _updateSnoreTimeline(snore, now);
    _snore = snore;
    _sleepStats.add(
      heartRate: heartRate,
      breathingRate: breathingRate,
      relativeAngleDeg:
          usePositionData ? orientation.relativeAngleDeg : double.nan,
      isSnoring: _snoreActiveForSleepStats(snore, now),
      sampledAt: now,
      hasSnoreData: snore.backend != 'none',
    );

    _pushLimited(
      _samples,
      SignalSample(
        timeS: timeS,
        ecg: heartRate ?? 0,
        resp: breathingRate ?? 0,
        a3: orientation.foreheadAngleDeg,
        a4: orientation.chestAngleDeg,
      ),
      plotSeconds * samplingRate,
    );

    final rows = csvAggregator.update(
      timeS,
      heartRate,
      breathingRate,
      null,
      snore,
      csvOrientation,
      _radar,
      _mg24,
    );
    for (final row in rows) {
      _csvSink?.writeln(row.join(','));
    }

    _publishIfNeeded(force: true);
  }

  void _startDemo() {
    snapshot = snapshot.copyWith(status: 'Demo-Modus laeuft');
    notifyListeners();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      for (var i = 0; i < 2; i++) {
        final t = _sampleNumber / samplingRate;
        final resp = 510 + 85 * math.sin(2 * math.pi * 0.23 * t);
        final beatPhase = t % 0.82;
        final spike = 320 * math.exp(-math.pow((beatPhase - 0.05) / 0.018, 2));
        final ecg = 512 + spike + _random.nextDouble() * 10 - 5;
        final orientationRaw = _demoOrientationRaw(t);
        _processAnalog([
          resp.round(),
          ecg.round(),
          orientationRaw[0].round(),
          orientationRaw[1].round(),
        ], includeVitals: true, includePosition: true);
      }
    });
  }

  List<double> _demoOrientationRaw(double timeS) {
    return [
      510 + 58 * math.sin(2 * math.pi * 0.035 * timeS),
      515 + 42 * math.sin(2 * math.pi * 0.028 * timeS + 0.5),
    ];
  }

  void _processMg24Sample(Mg24SensorSample sample) {
    if (!useMg24Data && !_mg24.connected && !_mg24.scanning) return;

    final breathingDetector =
        _mg24BreathingDetector ??= ImuBreathingRateDetector(mg24SamplingRate);
    final startedAt = _measurementStartedAt;
    final measurementActive = running &&
        useMg24Data &&
        (startedAt == null || !sample.receivedAt.isBefore(startedAt));
    final csvAggregator = _csvAggregator;
    final fallbackTimeS =
        measurementActive ? _elapsedSeconds() : _mg24LiveSeconds();
    final syncedTimeS = _syncMg24SensorClock(
      sample.role,
      sample.sensorTimeS,
      sample.receivedAt,
      fallbackTimeS,
    );
    final timeS = syncedTimeS ?? fallbackTimeS;
    var snore = _snore;
    final angle = sample.resolvedAngleDeg;
    _imuSnoreVibrationDetector.update(
      roleKey: sample.role.name,
      timeS: timeS,
      ax: sample.ax,
      ay: sample.ay,
      az: sample.az,
      gx: sample.gx,
      gy: sample.gy,
      gz: sample.gz,
    );

    final foreheadAngle = -_finiteNullableOr(_mg24.forehead.rollDeg, 0);
    final bellyAngle = -_finiteNullableOr(_mg24.belly.rollDeg, 0);
    final hasBothYawSensors =
        _rawMg24.forehead.connected && _rawMg24.belly.connected;
    final relativeYaw = hasBothYawSensors
        ? const _Mg24RelativeYawEstimate(
            yawDeg: 0,
            qualityPercent: 100,
            uncertaintyDeg: 0,
          )
        : const _Mg24RelativeYawEstimate.empty();
    final orientation = OrientationState(
      foreheadAngleDeg: foreheadAngle,
      chestAngleDeg: bellyAngle,
      relativeAngleDeg: _angleDeltaDeg(foreheadAngle, bellyAngle),
      relativeYawDeg: relativeYaw.yawDeg,
      relativeYawQualityPercent: relativeYaw.qualityPercent,
      relativeYawUncertaintyDeg: relativeYaw.uncertaintyDeg,
    );
    final hasForeheadPose = _mg24.forehead.connected &&
        _isFinite(_mg24.forehead.rollDeg) &&
        _isFinite(_mg24.forehead.pitchDeg) &&
        _isFinite(_mg24.forehead.yawDeg);
    final hasBellyPose = _mg24.belly.connected &&
        _isFinite(_mg24.belly.rollDeg) &&
        _isFinite(_mg24.belly.pitchDeg) &&
        _isFinite(_mg24.belly.yawDeg);

    BreathingResult? breathing;
    if (sample.role == Mg24SensorRole.belly) {
      if (sample.edgeProcessed) {
        _mg24BreathingRate = sample.breathingRatePerMin;
        _mg24BreathingQuality = sample.breathingQuality;
        _mg24BreathingAxis = 'MG24 lokal';
      } else {
        breathing = breathingDetector.update(
          sampleTimeS: timeS,
          angleDeg: angle,
          rollDeg: sample.rollDeg,
          pitchDeg: sample.pitchDeg,
          ax: sample.ax,
          ay: sample.ay,
          az: sample.az,
          gx: sample.gx,
          gy: sample.gy,
          gz: sample.gz,
          qw: sample.qw,
          qx: sample.qx,
          qy: sample.qy,
          qz: sample.qz,
        );
      }
      if (breathing != null) {
        final axisLabel = breathing.axisLabel;
        if (axisLabel != null &&
            _mg24BreathingAxis != null &&
            axisLabel != _mg24BreathingAxis) {
          _breathPeaks.clear();
        }
        _mg24BreathingSignal = breathing.filteredResp;
        _mg24BreathingRate = breathing.breathingRate;
        _mg24BreathingAxis = axisLabel;
        _mg24BreathingQuality = breathing.qualityPercent;
      }
      if (breathing != null && breathing.isBreath) {
        _breathCount++;
        final peakTime = math.max(
          0.0,
          breathing.breathPeakTime ?? timeS,
        );
        _pushLimited(
          _breathPeaks,
          PlotPoint(
            peakTime,
            breathing.breathPeakValue ?? breathing.filteredResp,
          ),
          100,
        );
      }
    }
    if (sample.edgeProcessed && sample.role == Mg24SensorRole.forehead) {
      if (snoreEnabled &&
          _mg24YamnetTeacherActive &&
          _snoreTrainingSink != null) {
        unawaited(_ensureYamnetTeacherLog());
      }
      if (_snoreTrainingSink != null || _yamnetTeacherSink != null) {
        _mg24AudioSnoreDetector.update(sample);
      }
      final completedMg24Window = _updateMg24TimedSnoreBreathWindow(
        sample,
        timeS,
      );
      _appendSnoreTrainingSample(sample);
      if (snoreEnabled) {
        snore = _snoreStateFromMg24Board(sample, completedMg24Window);
        _latestBoardSnore = snore;
      } else {
        _resetSnoreSourceTracking();
        snore = const SnoreState.empty();
        _latestBoardSnore = const SnoreState.empty();
      }
    } else if (sample.edgeProcessed) {
      snore = _snore;
    } else if (measurementActive) {
      snore = _snoreStateAt(timeS);
    }
    final measurementYamnetDetector = _snoreDetector;
    if (_measurementYamnetCaptureActive && measurementYamnetDetector != null) {
      snore = _snoreStateWithSource(
        _snoreStateFromYamnet(
          measurementYamnetDetector,
          _yamnetRawSnoreTracker.snapshot,
        ),
        timeS,
      );
    }

    final hasActiveOximeterSample = sample.max30102Connected == true;
    if (useMg24Data) {
      _heartRate = sample.heartRateBpm ??
          (hasActiveOximeterSample ? null : _mg24.heartRateBpm ?? _heartRate);
      _oxygenSaturation = sample.spo2Percent ??
          (hasActiveOximeterSample
              ? null
              : _mg24.spo2Percent ?? _oxygenSaturation);
      _breathingRate = _mg24BreathingRate;
    }
    _mg24 = _mergeMg24BreathingState(_mg24);
    _orientation = orientation;
    final snoreForStatistics = snore;
    snore = _withRecentHomeSnorePhaseHold(snore, sample.receivedAt);
    if (measurementActive) {
      _updateSnoreTimeline(
        _snoreActiveForSleepStats(snoreForStatistics, sample.receivedAt)
            ? snoreForStatistics
            : snoreForStatistics.copyWith(
                isSnoring: false,
                detectedNow: false,
                snoreBurstActive: false,
                clearSnoreActiveWidthMs: true,
              ),
        sample.receivedAt,
      );
    }
    _snore = snore;

    if (measurementActive) {
      _sleepStats.add(
        heartRate: _heartRate,
        breathingRate: _breathingRate,
        earTemperatureC: _mg24.forehead.earTemperatureC,
        relativeAngleDeg: hasForeheadPose && hasBellyPose
            ? orientation.relativeAngleDeg
            : double.nan,
        isSnoring: _snoreActiveForSleepStats(
          snoreForStatistics,
          sample.receivedAt,
        ),
        sampledAt: sample.receivedAt,
        foreheadRollDeg: _mg24.forehead.rollDeg,
        foreheadPitchDeg: _mg24.forehead.pitchDeg,
        foreheadYawDeg: hasForeheadPose ? 0 : null,
        bellyRollDeg: _mg24.belly.rollDeg,
        bellyPitchDeg: _mg24.belly.pitchDeg,
        bellyYawDeg: hasBellyPose ? 0 : null,
        hasForeheadPose: hasForeheadPose,
        hasBellyPose: hasBellyPose,
        hasSnoreData: snore.backend != 'none',
      );
    }

    final filteredBreathingSignal = _mg24BreathingSignal;
    if (!sample.edgeProcessed &&
        sample.role == Mg24SensorRole.belly &&
        filteredBreathingSignal != null &&
        filteredBreathingSignal.isFinite) {
      _pushSignalSampleWindow(
        _samples,
        SignalSample(
          timeS: timeS,
          ecg: _heartRate ?? 0,
          resp: filteredBreathingSignal,
          a3: foreheadAngle,
          a4: bellyAngle,
        ),
        mg24BreathingPlotSeconds.toDouble(),
        mg24BreathingPlotSeconds * mg24SamplingRate,
      );
    }

    if (measurementActive && csvAggregator != null) {
      final rows = csvAggregator.update(
        timeS,
        _heartRate,
        _breathingRate,
        _oxygenSaturation,
        snoreForStatistics,
        orientation,
        _radar,
        _mg24,
      );
      for (final row in rows) {
        _csvSink?.writeln(row.join(','));
      }
    }

    _sampleNumber++;
    _publishIfNeeded();
  }

  SnoreState _snoreStateFromMg24Board(
    Mg24SensorSample sample,
    _Mg24SnoreTimingWindow? completedWindow,
  ) {
    final activeWindow = _activeMg24SnoreTimingWindow;
    final active = sample.snoreBurstActive == true || sample.snoring == true;
    final score =
        ((sample.snorePatternQualityPercent ?? sample.snoreScore ?? 0) / 100.0)
            .clamp(0.0, 1.0)
            .toDouble();
    final widthMs = completedWindow?.widthMs ?? sample.snoreBreathWidthMs;
    final assessment = completedWindow == null
        ? (_liveMg24SnoreAssessments.isEmpty
            ? null
            : _liveMg24SnoreAssessments.last)
        : _recordLiveMg24SnoreWindow(completedWindow);
    final source = assessment?.source;
    return SnoreState(
      isSnoring: active,
      detectedNow: completedWindow != null,
      score: score,
      rmsDb: sample.snoreRmsDb ?? -120,
      snoreCount: sample.snoreBurstCounter ?? 0,
      backend: 'mg24-ml',
      inferenceId: sample.snoreBurstCounter ?? 0,
      windowCenterAt: completedWindow?.endAt ?? activeWindow?.endAt,
      patternQuality: score,
      snoreRatePerMin: sample.snoreRatePerMin,
      snoreBreathWidthMs: widthMs,
      snoreBurstActive: active,
      snoreActiveWidthMs: active ? sample.snoreActiveWidthMs : null,
      source: source?.source ?? 'unknown',
      sourceConfidence: source?.confidence ?? 0,
    );
  }

  _LiveMg24SnoreAssessment _recordLiveMg24SnoreWindow(
    _Mg24SnoreTimingWindow window,
  ) {
    for (final existing in _liveMg24SnoreAssessments) {
      if (_sameLiveMg24SnoreWindow(existing.window, window)) {
        return existing;
      }
    }
    final plotWindow = _plotTimeWindowForSnoreTiming(window) ??
        TimeWindow(window.plotStartS, window.plotEndS);
    final snore = _liveMg24EventRecord(
      plotWindow.startS,
      plotWindow.endS - plotWindow.startS,
      qualityPercent: 100,
    );
    final assessment = _LiveMg24SnoreAssessment(
      window: window,
      plotWindow: plotWindow,
      event: snore,
    );
    _liveMg24SnoreAssessments.add(assessment);
    while (_liveMg24SnoreAssessments.length > 240) {
      _liveMg24SnoreAssessments.removeAt(0);
    }
    _refreshLiveMg24SnoreAssessments();
    return assessment;
  }

  bool _sameLiveMg24SnoreWindow(
    _Mg24SnoreTimingWindow a,
    _Mg24SnoreTimingWindow b,
  ) {
    if (a.counter != null && b.counter != null) {
      return a.counter == b.counter;
    }
    return (a.plotStartS - b.plotStartS).abs() <= 0.08 &&
        (a.plotEndS - b.plotEndS).abs() <= 0.08;
  }

  void _refreshLiveMg24SnoreAssessments() {
    if (_liveMg24SnoreAssessments.isEmpty) return;
    final snores = _liveMg24SnoreAssessments
        .map((assessment) => assessment.event)
        .toList(growable: false);
    final breaths = _liveMg24BreathEvents.toList(growable: false);
    final sourceBySnore = _classifyOfflineSnoreSources(snores, breaths);
    for (final assessment in _liveMg24SnoreAssessments) {
      assessment.source = sourceBySnore[assessment.event] ??
          const _Mg24OfflineSnoreSource(
            source: 'unknown',
            confidence: 0,
            overlapRatio: 0,
          );
    }

    final latest = _liveMg24SnoreAssessments.last.source;
    if (_snore.backend == 'mg24-ml') {
      _snore = _snore.copyWith(
        source: latest.source,
        sourceConfidence: latest.confidence,
      );
    }
  }

  Mg24EventRecord _liveMg24EventRecord(
    double startS,
    double durationS, {
    required int qualityPercent,
  }) {
    return Mg24EventRecord(
      startTick: (math.max(0.0, startS) / Mg24EventRecord.tickSeconds)
          .round()
          .clamp(0, 0xffffffff)
          .toInt(),
      durationTicks: (math.max(Mg24EventRecord.tickSeconds, durationS) /
              Mg24EventRecord.tickSeconds)
          .round()
          .clamp(1, 255)
          .toInt(),
      qualityPercent: qualityPercent.clamp(0, 100).toDouble(),
    );
  }

  void _recordLiveMg24BreathPeak(double timeS) {
    if (!timeS.isFinite || timeS < 0) return;
    final previous = _lastLiveMg24BreathPeakTimeS;
    _lastLiveMg24BreathPeakTimeS = timeS;
    if (previous == null) return;
    final durationS = timeS - previous;
    if (durationS < 1.2 || durationS > 12.0) return;
    _liveMg24BreathEvents.addLast(
      _liveMg24EventRecord(
        previous,
        durationS,
        qualityPercent: (_mg24BreathingQuality ?? 100).round(),
      ),
    );
    while (_liveMg24BreathEvents.length > 1200) {
      _liveMg24BreathEvents.removeFirst();
    }
    _refreshLiveMg24SnoreAssessments();
    _refreshLiveConfirmedSnoreSource();
  }

  void _resetLiveMg24SnoreSourceTracking() {
    _liveMg24BreathEvents.clear();
    _liveMg24SnoreAssessments.clear();
    _lastLiveMg24BreathPeakTimeS = null;
  }

  SnoreState _withRecentHomeSnorePhaseHold(SnoreState current, DateTime now) {
    if (current.isSnoring || current.detectedNow || current.snoreBurstActive) {
      return current;
    }
    final currentAt = current.windowCenterAt;
    if (currentAt != null) {
      final currentAge = now.difference(currentAt);
      if (!currentAge.isNegative && currentAge <= _homeSnorePhaseHoldDuration) {
        return current;
      }
    }

    final previous = _snore;
    if (!_hasHomeSnorePhaseEvidence(previous)) return current;
    final previousAt = previous.windowCenterAt;
    if (previousAt == null) return current;
    final previousAge = now.difference(previousAt);
    if (previousAge.isNegative || previousAge > _homeSnorePhaseHoldDuration) {
      return current;
    }

    return current.copyWith(
      backend: current.backend == 'none' ? previous.backend : current.backend,
      score: math.max(current.score, previous.score),
      rmsDb: math.max(current.rmsDb, previous.rmsDb),
      snoreCount: math.max(current.snoreCount, previous.snoreCount),
      windowCenterAt: previousAt,
      source: current.source == 'unknown' ? previous.source : current.source,
      sourceConfidence:
          math.max(current.sourceConfidence, previous.sourceConfidence),
      patternQuality: current.patternQuality ?? previous.patternQuality,
      snoreRatePerMin: current.snoreRatePerMin ?? previous.snoreRatePerMin,
      snoreBreathWidthMs:
          current.snoreBreathWidthMs ?? previous.snoreBreathWidthMs,
      snoreBurstActive: false,
      clearSnoreActiveWidthMs: true,
    );
  }

  bool _hasHomeSnorePhaseEvidence(SnoreState snore) {
    return snore.isSnoring ||
        snore.detectedNow ||
        snore.snoreBurstActive ||
        snore.snoreBreathWidthMs != null ||
        snore.snoreActiveWidthMs != null ||
        (snore.backend != 'none' && snore.score > 0);
  }

  bool _snoreActiveForSleepStats(SnoreState snore, DateTime now) {
    if (!snore.isSnoring) return false;
    if (snore.snoreBurstActive || snore.detectedNow) return true;

    final centerAt = snore.windowCenterAt;
    final widthMs = snore.snoreBreathWidthMs ?? snore.snoreActiveWidthMs;
    if (centerAt != null &&
        widthMs != null &&
        widthMs.isFinite &&
        widthMs > 0) {
      final age = now.difference(centerAt);
      return !age.isNegative && age <= const Duration(milliseconds: 900);
    }

    return snore.backend != 'none' && snore.score >= 0.65;
  }

  _Mg24SnoreTimingWindow? _updateMg24TimedSnoreBreathWindow(
    Mg24SensorSample sample,
    double fallbackEndS,
  ) {
    final currentWindow = _mg24SnoreTimingWindowFromSample(
      sample,
      sampleTimeS: fallbackEndS,
    );
    final active = sample.snoreBurstActive == true && currentWindow != null;
    if (active) {
      final previous = _activeMg24SnoreTimingWindow;
      var stableWindow = currentWindow;
      if (previous != null) {
        final sameCounter = currentWindow.counter != null &&
            previous.counter != null &&
            previous.counter == currentWindow.counter;
        if (sameCounter) {
          stableWindow = previous.withWidthMs(
            math.max(previous.widthMs, currentWindow.widthMs),
          );
        } else if (currentWindow.counter != null && previous.counter != null) {
          _queuePendingMg24SnoreTimingWindow(previous);
        }
      }
      _activeMg24SnoreTimingWindow = stableWindow;
    } else {
      var completed = _completedMg24SnoreTimingWindowFromSample(
        sample,
        sampleTimeS: fallbackEndS,
      );
      final previous = _activeMg24SnoreTimingWindow;
      if (completed != null && previous != null) {
        final sameCounter = completed.counter != null &&
            previous.counter != null &&
            completed.counter == previous.counter;
        if (sameCounter) {
          completed = previous.withWidthMs(
            math.max(previous.widthMs, completed.widthMs),
          );
        }
      }
      completed ??= previous;
      _activeMg24SnoreTimingWindow = null;
      if (completed != null) {
        _queuePendingMg24SnoreTimingWindow(completed);
      }
    }

    return _recordConfirmedMg24SnoreTimingWindows();
  }

  _Mg24SnoreTimingWindow? _mg24SnoreTimingWindowFromSample(
    Mg24SensorSample sample, {
    required double sampleTimeS,
  }) {
    final ageMs = sample.snoreBurstAgeMs;
    final widthMs = sample.snoreActiveWidthMs;
    if (ageMs == null ||
        widthMs == null ||
        ageMs < 0 ||
        !widthMs.isFinite ||
        widthMs <= 0) {
      return null;
    }
    final ageUs = (ageMs * Duration.microsecondsPerMillisecond).round();
    final widthUs = (widthMs * Duration.microsecondsPerMillisecond)
        .round()
        .clamp(1, 65535000)
        .toInt();
    final endSensorTimeS = sample.sensorTimeS == null
        ? null
        : sample.sensorTimeS! - ageUs / Duration.microsecondsPerSecond;
    final startSensorTimeS = endSensorTimeS == null
        ? null
        : endSensorTimeS - widthUs / Duration.microsecondsPerSecond;
    final plotEndS = _mg24TimelineTimeForSensorTime(
          sample.role,
          endSensorTimeS,
        ) ??
        (sampleTimeS - ageMs / 1000.0);
    final plotStartS = _mg24TimelineTimeForSensorTime(
          sample.role,
          startSensorTimeS,
        ) ??
        (plotEndS - widthUs / Duration.microsecondsPerSecond);
    final endAt = _timestampForTimelineTime(plotEndS) ??
        sample.receivedAt.subtract(Duration(microseconds: ageUs));
    final startAt = _timestampForTimelineTime(plotStartS) ??
        endAt.subtract(Duration(microseconds: widthUs));
    if (!endAt.isAfter(startAt)) return null;
    return _Mg24SnoreTimingWindow(
      startAt: startAt,
      endAt: endAt,
      plotStartS: plotStartS,
      plotEndS: plotEndS,
      counter: sample.snoreBurstCounter,
    );
  }

  _Mg24SnoreTimingWindow? _completedMg24SnoreTimingWindowFromSample(
    Mg24SensorSample sample, {
    required double sampleTimeS,
  }) {
    if (sample.snoreBurstActive == true) return null;
    final ageMs = sample.snoreBurstAgeMs;
    final widthMs = sample.snoreBreathWidthMs;
    if (ageMs == null ||
        widthMs == null ||
        ageMs < 0 ||
        !widthMs.isFinite ||
        widthMs <= 0) {
      return null;
    }
    final counter = sample.snoreBurstCounter;
    if (counter != null && counter == _lastRecordedMg24SnoreBurstCounter) {
      return null;
    }
    final ageUs = (ageMs * Duration.microsecondsPerMillisecond).round();
    final widthUs = (widthMs * Duration.microsecondsPerMillisecond)
        .round()
        .clamp(1, 65535000)
        .toInt();
    final endSensorTimeS = sample.sensorTimeS == null
        ? null
        : sample.sensorTimeS! - ageUs / Duration.microsecondsPerSecond;
    final startSensorTimeS = endSensorTimeS == null
        ? null
        : endSensorTimeS - widthUs / Duration.microsecondsPerSecond;
    final plotEndS = _mg24TimelineTimeForSensorTime(
          sample.role,
          endSensorTimeS,
        ) ??
        (sampleTimeS - ageMs / 1000.0);
    final plotStartS = _mg24TimelineTimeForSensorTime(
          sample.role,
          startSensorTimeS,
        ) ??
        (plotEndS - widthUs / Duration.microsecondsPerSecond);
    final endAt = _timestampForTimelineTime(plotEndS) ??
        sample.receivedAt.subtract(Duration(microseconds: ageUs));
    final startAt = _timestampForTimelineTime(plotStartS) ??
        endAt.subtract(Duration(microseconds: widthUs));
    if (!endAt.isAfter(startAt)) return null;
    return _Mg24SnoreTimingWindow(
      startAt: startAt,
      endAt: endAt,
      plotStartS: plotStartS,
      plotEndS: plotEndS,
      counter: counter,
    );
  }

  void _queuePendingMg24SnoreTimingWindow(_Mg24SnoreTimingWindow window) {
    final counter = window.counter;
    if (counter != null) {
      if (counter == _lastRecordedMg24SnoreBurstCounter) return;
      for (final pending in _pendingMg24SnoreTimingWindows) {
        if (pending.counter == counter) return;
      }
    }
    _pendingMg24SnoreTimingWindows.add(window);
    while (_pendingMg24SnoreTimingWindows.length > 12) {
      _pendingMg24SnoreTimingWindows.removeFirst();
    }
  }

  _Mg24SnoreTimingWindow? _recordConfirmedMg24SnoreTimingWindows() {
    final retained = Queue<_Mg24SnoreTimingWindow>();
    _Mg24SnoreTimingWindow? lastRecorded;
    final now = DateTime.now();
    while (_pendingMg24SnoreTimingWindows.isNotEmpty) {
      final window = _pendingMg24SnoreTimingWindows.removeFirst();
      if (window.counter != null &&
          window.counter == _lastRecordedMg24SnoreBurstCounter) {
        continue;
      }
      // Start/end already come from the trained forehead-board classifier.
      // YAMNet is no longer a gate, so windows are also retained when the
      // phone is disconnected for the night.
      if (snoreEnabled) {
        final recorded = _recordMg24TimedSnoreBreathWindow(window);
        if (recorded) {
          if (window.counter != null) {
            _lastRecordedMg24SnoreBurstCounter = window.counter;
          }
          lastRecorded = window;
        } else if (now.difference(window.endAt).inSeconds < 8) {
          retained.add(window);
        }
      } else if (now.difference(window.endAt).inSeconds < 8) {
        retained.add(window);
      }
    }
    _pendingMg24SnoreTimingWindows.addAll(retained);
    return lastRecorded;
  }

  bool _recordMg24TimedSnoreBreathWindow(_Mg24SnoreTimingWindow window) {
    if (!window.startAt.isBefore(window.endAt) ||
        !window.plotStartS.isFinite ||
        !window.plotEndS.isFinite ||
        window.plotEndS <= window.plotStartS) {
      return false;
    }
    _scheduleSnoreBreathTimingWindow(window);
    return true;
  }

  void _scheduleSnoreBreathTimingWindow(_Mg24SnoreTimingWindow window) {
    final counter = window.counter;
    if (counter != null) {
      for (final scheduled in _scheduledSnoreBreathWindows) {
        if (scheduled.counter == counter) return;
      }
    } else {
      for (final scheduled in _scheduledSnoreBreathWindows) {
        final startDistanceUs =
            scheduled.startAt.difference(window.startAt).inMicroseconds.abs();
        final endDistanceUs =
            scheduled.endAt.difference(window.endAt).inMicroseconds.abs();
        if (startDistanceUs < 80000 && endDistanceUs < 80000) return;
      }
    }
    _scheduledSnoreBreathWindows.addLast(window);
    while (_scheduledSnoreBreathWindows.length > 24) {
      _scheduledSnoreBreathWindows.removeFirst();
    }
    _flushScheduledSnoreBreathPlotWindows();
  }

  void _flushScheduledSnoreBreathPlotWindows() {
    if (_scheduledSnoreBreathWindows.isEmpty) return;
    final plotWallTime = _latestBreathingPlotWallTime();
    if (plotWallTime == null) return;
    final retained = Queue<_Mg24SnoreTimingWindow>();
    final staleCutoff = plotWallTime.subtract(
      Duration(seconds: mg24BreathingPlotSeconds + 4),
    );
    while (_scheduledSnoreBreathWindows.isNotEmpty) {
      final window = _scheduledSnoreBreathWindows.removeFirst();
      if (window.endAt.isBefore(staleCutoff)) {
        continue;
      }
      final visibleStartAt = window.startAt.add(
        Duration(
          microseconds:
              (_mg24SnoreToBreathingPlotOffsetSeconds * 1000000).round(),
        ),
      );
      if (visibleStartAt.isAfter(
        plotWallTime.add(const Duration(milliseconds: 60)),
      )) {
        retained.addLast(window);
        continue;
      }
      final plotWindow = _plotTimeWindowForSnoreTiming(window);
      if (plotWindow != null) {
        _recordSnoreBreathPlotWindow(plotWindow);
      } else {
        retained.addLast(window);
      }
    }
    _scheduledSnoreBreathWindows.addAll(retained);
  }

  void _recordSnoreBreathPlotWindow(TimeWindow window) {
    var preferred = window;
    final retained = <TimeWindow>[];
    for (final existing in _snoreBreathWindows) {
      if (_snoreBreathPlotWindowsSameEvent(existing, window)) {
        preferred = _preferredSnoreBreathPlotWindow(existing, preferred);
      } else {
        retained.add(existing);
      }
    }
    _snoreBreathWindows
      ..clear()
      ..addAll(retained);
    _pushLimited(_snoreBreathWindows, preferred, 80);
    _recordRecentConfirmedSnoreBreathWindow(preferred);
    _pruneSnoreBreathPlotWindows();
  }

  void _recordRecentConfirmedSnoreBreathWindow(TimeWindow window) {
    var preferred = window;
    final retained = <TimeWindow>[];
    for (final existing in _recentConfirmedSnoreBreathWindows) {
      if (_snoreBreathPlotWindowsSameEvent(existing, window)) {
        preferred = _preferredSnoreBreathPlotWindow(existing, preferred);
      } else {
        retained.add(existing);
      }
    }
    _recentConfirmedSnoreBreathWindows
      ..clear()
      ..addAll(retained);
    _pushLimited(_recentConfirmedSnoreBreathWindows, preferred, 12);
    final durationS = preferred.endS - preferred.startS;
    debugPrint(
      'LASLI_SNORE_WINDOW confirmed '
      'start_s=${preferred.startS.toStringAsFixed(3)} '
      'end_s=${preferred.endS.toStringAsFixed(3)} '
      'duration_s=${durationS.toStringAsFixed(3)}',
    );
  }

  List<TimeWindow> _deduplicateSnoreBreathPlotWindows(
    Iterable<TimeWindow> source,
  ) {
    final sorted = source
        .where(_validSnoreBreathPlotWindow)
        .toList(growable: true)
      ..sort((a, b) => a.startS.compareTo(b.startS));
    final deduplicated = <TimeWindow>[];
    for (final window in sorted) {
      var merged = false;
      for (var i = 0; i < deduplicated.length; i++) {
        if (_snoreBreathPlotWindowsSameEvent(deduplicated[i], window)) {
          deduplicated[i] =
              _preferredSnoreBreathPlotWindow(deduplicated[i], window);
          merged = true;
          break;
        }
      }
      if (!merged) deduplicated.add(window);
    }
    return deduplicated;
  }

  bool _validSnoreBreathPlotWindow(TimeWindow window) =>
      window.startS.isFinite &&
      window.endS.isFinite &&
      window.endS > window.startS;

  bool _snoreBreathPlotWindowsSameEvent(TimeWindow a, TimeWindow b) {
    if (!_validSnoreBreathPlotWindow(a) || !_validSnoreBreathPlotWindow(b)) {
      return false;
    }
    final overlap = math.min(a.endS, b.endS) - math.max(a.startS, b.startS);
    final durationA = a.endS - a.startS;
    final durationB = b.endS - b.startS;
    final shorterDuration = math.max(0.08, math.min(durationA, durationB));
    if (overlap > 0 && overlap / shorterDuration >= 0.30) {
      return true;
    }

    final centerA = (a.startS + a.endS) * 0.5;
    final centerB = (b.startS + b.endS) * 0.5;
    final centerDistance = (centerA - centerB).abs();
    final startDistance = (a.startS - b.startS).abs();
    final endDistance = (a.endS - b.endS).abs();
    return centerDistance <= 1.10 ||
        startDistance <= 0.55 ||
        endDistance <= 0.55;
  }

  TimeWindow _preferredSnoreBreathPlotWindow(TimeWindow a, TimeWindow b) {
    final durationA = a.endS - a.startS;
    final durationB = b.endS - b.startS;
    if (durationB > durationA + 0.16) return b;
    if (durationA > durationB + 0.16) return a;
    return b.endS >= a.endS ? b : a;
  }

  void _pruneSnoreBreathPlotWindows() {
    final plotEndS = _latestBreathingPlotTimeS();
    if (plotEndS == null || !plotEndS.isFinite) return;
    final minTime = math.max(0.0, plotEndS - mg24BreathingPlotSeconds - 2.0);
    while (_snoreBreathWindows.isNotEmpty &&
        _snoreBreathWindows.first.endS < minTime) {
      _snoreBreathWindows.removeFirst();
    }
  }

  TimeWindow? _plotTimeWindowForSnoreTiming(_Mg24SnoreTimingWindow window) {
    final mappedStartS = _breathingPlotTimeForTimestamp(window.startAt);
    final mappedEndS = _breathingPlotTimeForTimestamp(window.endAt);
    final startS = (mappedStartS ?? window.plotStartS) +
        _mg24SnoreToBreathingPlotOffsetSeconds;
    final endS = (mappedEndS ?? window.plotEndS) +
        _mg24SnoreToBreathingPlotOffsetSeconds;
    if (startS.isFinite && endS.isFinite && endS > startS) {
      return TimeWindow(math.max(0.0, startS), math.max(0.0, endS));
    }
    return null;
  }

  double? _latestBreathingPlotTimeS() {
    if (_samples.isNotEmpty) {
      final sampleTimeS = _samples.last.timeS;
      if (sampleTimeS.isFinite) return sampleTimeS;
    }
    final anchorTimeS = _mg24BellyPlotAnchorTimeS;
    return anchorTimeS != null && anchorTimeS.isFinite ? anchorTimeS : null;
  }

  DateTime? _latestBreathingPlotWallTime() => _mg24BellyPlotAnchorAt;

  double? _breathingPlotLatencySeconds() {
    final anchorAt = _latestBreathingPlotWallTime();
    if (anchorAt == null) return null;
    final transportLatencyS =
        DateTime.now().difference(anchorAt).inMicroseconds /
            Duration.microsecondsPerSecond;
    final latencyS = transportLatencyS;
    if (!latencyS.isFinite || latencyS < -0.5 || latencyS > 30.0) {
      return null;
    }
    return math.max(0.0, latencyS);
  }

  double? _breathingPlotTimeForTimestamp(DateTime timestamp) {
    final anchorAt = _mg24BellyPlotAnchorAt;
    final anchorTimeS = _mg24BellyPlotAnchorTimeS;
    if (anchorAt == null || anchorTimeS == null || !anchorTimeS.isFinite) {
      return null;
    }
    final deltaS = timestamp.difference(anchorAt).inMicroseconds / 1000000.0;
    final timeS = anchorTimeS + deltaS;
    if (!timeS.isFinite || timeS < 0) return null;
    return timeS;
  }

  void _appendSnoreTrainingSample(Mg24SensorSample sample) {
    if (sample.role != Mg24SensorRole.forehead) return;
    final manualSink = _snoreTrainingSink;
    final manualLabel = _snoreTrainingLabel;
    if (manualSink != null && manualLabel != null) {
      _snoreTrainingSampleCount++;
      if (_hasCompleteSnoreTrainingFeatures(sample)) {
        _snoreTrainingCompleteFeatureCount++;
      }
      _writeSnoreFeatureTrainingSample(
        sink: manualSink,
        label: manualLabel,
        manualWindow: _snoreTrainingWindowActive,
        manualWindowId: _snoreTrainingWindowId == 0
            ? ''
            : _snoreTrainingWindowId.toString(),
        manualWindowElapsedS: _snoreTrainingWindowElapsed(sample.receivedAt),
        sample: sample,
      );
    }

    final teacherSink = _yamnetTeacherSink;
    if (_mg24YamnetTeacherActive && teacherSink != null) {
      final teacher = _yamnetRawSnoreTracker.snapshot;
      _writeSnoreFeatureTrainingSample(
        sink: teacherSink,
        label: 'yamnet_teacher',
        manualWindow: teacher.active,
        manualWindowId:
            teacher.windowId == 0 ? '' : teacher.windowId.toString(),
        manualWindowElapsedS: teacher.activeWidthMs == null
            ? null
            : teacher.activeWidthMs! / 1000.0,
        sample: sample,
      );
    }
  }

  void _resetSnoreMelPreflight({required bool clearRetryCount}) {
    _snoreMelPreflightTimeoutTimer?.cancel();
    _snoreMelPreflightTimeoutTimer = null;
    _snoreMelTransportReady = false;
    _snoreMelPreflightStartedAt = null;
    _snoreMelPreflightSliceCount = 0;
    _snoreMelPreflightDroppedSliceCount = 0;
    _lastSnoreMelPreflightFrameSequence = null;
    if (clearRetryCount) _snoreMelPreflightRetryCount = 0;
  }

  void _armSnoreMelPreflightTimeout(Duration timeout) {
    _snoreMelPreflightTimeoutTimer?.cancel();
    final generation = _snoreMelTransportGeneration;
    _snoreMelPreflightTimeoutTimer = Timer(timeout, () {
      if (generation != _snoreMelTransportGeneration ||
          _snoreTrainingSink == null ||
          _snoreMelTransportReady ||
          _snoreMelTransportRecoveryInProgress) {
        return;
      }
      unawaited(
        _recoverSnoreMelTransport('keine ausreichende Log-Mel-Datenrate'),
      );
    });
  }

  void _observeSnoreMelPreflight(Mg24MelFeaturePacket packet) {
    if (_snoreMelTransportRecoveryInProgress) return;
    final firstSequence = packet.firstFrameSequence & 0xffffffff;
    final previousSequence = _lastSnoreMelPreflightFrameSequence;
    if (previousSequence != null) {
      final expected = (previousSequence + 1) & 0xffffffff;
      final gap = (firstSequence - expected) & 0xffffffff;
      if (gap > 0 && gap < 0x80000000) {
        _snoreMelPreflightDroppedSliceCount += gap;
      }
    }
    _lastSnoreMelPreflightFrameSequence =
        (firstSequence + packet.slices.length - 1) & 0xffffffff;
    _snoreMelPreflightStartedAt ??= packet.receivedAt;
    _snoreMelPreflightSliceCount += packet.slices.length;

    final elapsed = packet.receivedAt.difference(_snoreMelPreflightStartedAt!);
    if (elapsed < _snoreMelPreflightDuration) return;
    final elapsedSeconds = elapsed.inMicroseconds / 1000000.0;
    final sliceRate = elapsedSeconds <= 0
        ? 0.0
        : _snoreMelPreflightSliceCount / elapsedSeconds;
    if (_snoreMelPreflightDroppedSliceCount == 0 &&
        sliceRate >= _snoreMelMinimumPreflightRate) {
      _snoreMelPreflightTimeoutTimer?.cancel();
      _snoreMelPreflightTimeoutTimer = null;
      _snoreMelTransportReady = true;
      _snoreMelPacketCount = 0;
      _snoreMelSliceCount = 0;
      _snoreMelDroppedSliceCount = 0;
      _lastSnoreMelFrameSequence = null;
      snapshot = snapshot.copyWith(
        status:
            'Audio-Training bereit (${sliceRate.toStringAsFixed(0)} Log-Mel-Slices/s).',
      );
      notifyListeners();
      return;
    }
    unawaited(
      _recoverSnoreMelTransport(
        'nur ${sliceRate.toStringAsFixed(0)} statt mindestens '
        '${_snoreMelMinimumPreflightRate.toStringAsFixed(0)} Slices/s',
      ),
    );
  }

  Future<void> _recoverSnoreMelTransport(String reason) async {
    if (_snoreMelTransportRecoveryInProgress ||
        _snoreTrainingSink == null ||
        _snoreMelTransportReady) {
      return;
    }
    if (_snoreMelPreflightRetryCount >= _snoreMelMaximumPreflightRetries) {
      await _abortSnoreMelTrainingForTransport(
        'Log-Mel-Verbindung zu langsam ($reason). Aufnahme verworfen.',
      );
      return;
    }

    final client = _mg24Client;
    if (client == null || !_mg24.forehead.connected) {
      await _abortSnoreMelTrainingForTransport(
        'Stirn-MG24 waehrend der Datenratenpruefung getrennt. '
        'Aufnahme verworfen.',
      );
      return;
    }

    _snoreMelTransportRecoveryInProgress = true;
    final generation = _snoreMelTransportGeneration;
    _snoreMelPreflightRetryCount++;
    _snoreMelPreflightTimeoutTimer?.cancel();
    _snoreMelPreflightTimeoutTimer = null;
    snapshot = snapshot.copyWith(
      status: 'Log-Mel-Verbindung wird neu vorbereitet '
          '($_snoreMelPreflightRetryCount/$_snoreMelMaximumPreflightRetries): '
          '$reason.',
    );
    notifyListeners();
    try {
      await client.setMelTraining(false);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (generation != _snoreMelTransportGeneration ||
          _snoreTrainingSink == null) {
        return;
      }
      _resetSnoreMelPreflight(clearRetryCount: false);
      await client.setMelTraining(true);
      if (generation != _snoreMelTransportGeneration ||
          _snoreTrainingSink == null) {
        return;
      }
      _armSnoreMelPreflightTimeout(_snoreMelRetryPacketTimeout);
    } catch (error) {
      if (generation == _snoreMelTransportGeneration &&
          _snoreTrainingSink != null) {
        await _abortSnoreMelTrainingForTransport(
          'Log-Mel-Neustart fehlgeschlagen: ${_friendlyError(error)}. '
          'Aufnahme verworfen.',
        );
      }
    } finally {
      _snoreMelTransportRecoveryInProgress = false;
    }
  }

  Future<void> _abortSnoreMelTrainingForTransport(String reason) async {
    final trainingFile = _snoreTrainingFile;
    final melFile = _snoreMelTrainingFile;
    await stopSnoreTraining();
    for (final file in [trainingFile, melFile]) {
      if (file != null && await file.exists()) {
        await file.delete();
      }
    }
    await refreshSnoreTrainingRecordings(notify: false);
    snapshot = snapshot.copyWith(status: reason);
    notifyListeners();
  }

  void _appendSnoreMelTrainingPacket(Mg24MelFeaturePacket packet) {
    if (packet.role != Mg24SensorRole.forehead) return;
    final sink = _snoreMelTrainingSink;
    final label = _snoreTrainingLabel;
    if (sink == null || label == null || packet.slices.isEmpty) return;
    final receivedMonotonicUs = AppMonotonicClock.nowUs();
    if (_snoreAutomaticTeacherMode) {
      _snoreTeacherSynchronizer.addBoardPacket(
        firstFrameSequence: packet.firstFrameSequence & 0xffffffff,
        framePeriodUs: packet.framePeriodUs,
        receivedMonotonicUs: receivedMonotonicUs,
        slices: packet.slices,
      );
    }
    if (!_snoreMelTransportReady) {
      _observeSnoreMelPreflight(packet);
      return;
    }

    final firstSequence = packet.firstFrameSequence & 0xffffffff;
    final previousSequence = _lastSnoreMelFrameSequence;
    if (previousSequence != null) {
      final expected = (previousSequence + 1) & 0xffffffff;
      final gap = (firstSequence - expected) & 0xffffffff;
      if (gap > 0 && gap < 0x80000000) {
        _snoreMelDroppedSliceCount += gap;
      }
    }
    _lastSnoreMelFrameSequence =
        (firstSequence + packet.slices.length - 1) & 0xffffffff;
    _snoreMelPacketCount++;
    _snoreMelSliceCount += packet.slices.length;
    if (packet.modelAvailable) {
      _latestSnoreMelModelScorePercent = packet.modelScorePercent;
      _latestSnoreMelModelActive = packet.modelActive;
      _latestSnoreMelModelTrusted = packet.boardDomainTrusted;
    }

    final mappedFirstFrameUs = _snoreAutomaticTeacherMode
        ? _snoreTeacherSynchronizer.frameMonotonicUs(firstSequence)
        : null;
    final firstFrameAt = mappedFirstFrameUs == null
        ? packet.receivedAt.subtract(
            Duration(
              microseconds:
                  math.max(0, packet.slices.length - 1) * packet.framePeriodUs,
            ),
          )
        : AppMonotonicClock.wallTime(mappedFirstFrameUs);
    final row = List<String>.filled(
      17 + _snoreMelSlicesPerPacket * _snoreMelBandsPerSlice,
      '',
    );
    row[0] = packet.receivedAt.toIso8601String();
    row[1] = firstFrameAt.toIso8601String();
    row[2] = label.replaceAll(',', '_');
    row[3] = _snoreTrainingWindowActive ? '1' : '0';
    row[4] =
        _snoreTrainingWindowId == 0 ? '' : _snoreTrainingWindowId.toString();
    row[5] = packet.packetSequence.toString();
    row[6] = firstSequence.toString();
    row[7] = packet.framePeriodUs.toString();
    row[8] = packet.slices.length.toString();
    row[9] = packet.modelAvailable ? packet.modelScorePercent.toString() : '';
    row[10] = !packet.modelAvailable
        ? 'unavailable'
        : packet.boardDomainTrusted
            ? (packet.modelActive ? 'trusted_active' : 'trusted_inactive')
            : (packet.modelActive ? 'shadow_active' : 'shadow_inactive');
    row[11] = packet.modelAvailable ? packet.modelFrameSequence.toString() : '';
    row[12] = mappedFirstFrameUs?.toString() ?? '';
    row[15] = _snoreAutomaticTeacherMode
        ? _snoreTeacherSynchronizer.estimate.method
        : '';
    row[16] = _snoreAutomaticTeacherMode
        ? _snoreTeacherSynchronizer.estimate.errorMs?.toStringAsFixed(1) ?? ''
        : '';
    for (var slice = 0; slice < packet.slices.length; slice++) {
      final features = packet.slices[slice];
      for (var band = 0;
          band < math.min(features.length, _snoreMelBandsPerSlice);
          band++) {
        row[17 + slice * _snoreMelBandsPerSlice + band] =
            features[band].toString();
      }
    }
    sink.writeln(row.join(','));
  }

  void _addAutomaticTeacherWindow(YamnetRawSnoreWindow window) {
    var startUs = AppMonotonicClock.monotonicUs(window.startAt);
    var endUs = AppMonotonicClock.monotonicUs(window.endAt);
    final recordingStartUs = _snoreAutomaticTrainingStartedUs;
    final recordingStopUs = _snoreAutomaticTrainingStoppedUs;
    if (recordingStartUs != null) startUs = math.max(startUs, recordingStartUs);
    if (recordingStopUs != null) endUs = math.min(endUs, recordingStopUs);
    if (endUs <= startUs) return;
    for (final existing in _snoreAutomaticTeacherWindows) {
      if ((existing.startUs - startUs).abs() <= 20000 &&
          (existing.endUs - endUs).abs() <= 20000) {
        return;
      }
    }
    _snoreAutomaticTeacherWindows.add(
      _AutomaticTeacherWindow(
        id: _snoreAutomaticTeacherWindows.length + 1,
        startUs: startUs,
        endUs: endUs,
      ),
    );
  }

  void _captureActiveAutomaticTeacherWindow() {
    final teacher = _yamnetRawSnoreTracker.snapshot;
    final startAt = teacher.activeStartAt;
    final endAt = teacher.activeEndAt;
    if (startAt == null || endAt == null || !endAt.isAfter(startAt)) return;
    _addAutomaticTeacherWindow(
      YamnetRawSnoreWindow(startAt: startAt, endAt: endAt),
    );
  }

  Future<void> _finalizeAutomaticTeacherMelFile(File file) async {
    if (!await file.exists()) return;
    final windows = List<_AutomaticTeacherWindow>.of(
      _snoreAutomaticTeacherWindows,
    )..sort((a, b) => a.startUs.compareTo(b.startUs));
    final temporary = File('${file.path}.teacher.tmp');
    final output = temporary.openWrite();
    var headerWritten = false;
    List<String> header = const [];
    try {
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!headerWritten) {
          header = line.split(',');
          output.writeln(line);
          headerWritten = true;
          continue;
        }
        if (line.trim().isEmpty) continue;
        final row = line.split(',');
        if (row.length != header.length) {
          output.writeln(line);
          continue;
        }
        int index(String name) => header.indexOf(name);
        final firstSequenceIndex = index('first_frame_sequence');
        final countIndex = index('slice_count');
        final firstSequence = int.tryParse(row[firstSequenceIndex]);
        final sliceCount = int.tryParse(row[countIndex]);
        if (firstSequence == null || sliceCount == null || sliceCount <= 0) {
          output.writeln(line);
          continue;
        }

        var teacherMask = 0;
        final windowIds = <int>{};
        int? firstFrameUs;
        for (var slice = 0; slice < sliceCount; slice++) {
          final frameUs = _snoreTeacherSynchronizer.frameMonotonicUs(
            firstSequence + slice,
          );
          firstFrameUs ??= frameUs;
          if (frameUs == null) continue;
          for (final window in windows) {
            if (frameUs >= window.startUs && frameUs < window.endUs) {
              teacherMask |= 1 << slice;
              windowIds.add(window.id);
              break;
            }
          }
        }

        row[index('label')] = 'schnarchen';
        row[index('manual_window')] = teacherMask == 0 ? '0' : '1';
        row[index('manual_window_id')] = windowIds.join(';');
        row[index('first_frame_monotonic_us')] = firstFrameUs?.toString() ?? '';
        row[index('teacher_slice_mask')] = teacherMask.toString();
        row[index('teacher_window_ids')] = windowIds.join(';');
        row[index('teacher_sync_method')] =
            _snoreTeacherSynchronizer.estimate.method;
        row[index('teacher_sync_error_ms')] =
            _snoreTeacherSynchronizer.estimate.errorMs?.toStringAsFixed(1) ??
                '';
        if (firstFrameUs != null) {
          row[index('estimated_first_frame_at')] =
              AppMonotonicClock.wallTime(firstFrameUs).toIso8601String();
        }
        output.writeln(row.join(','));
      }
      await output.flush();
      await output.close();
      await temporary.openRead().pipe(file.openWrite());
      await temporary.delete();
    } catch (_) {
      await output.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  bool _hasCompleteSnoreTrainingFeatures(Mg24SensorSample sample) {
    final numericFeatures = [
      sample.snoreScore,
      sample.snoreRmsDb,
      sample.snoreLevelRatioPercent,
      sample.snoreLowRatioPercent,
      sample.snoreCrossingRatePercent,
      sample.snoreRawSwing,
      sample.snoreAudioBand0To150Percent,
      sample.snoreAudioBand150To300Percent,
      sample.snoreAudioBand300To600Percent,
      sample.snoreAudioBand600To1200Percent,
      sample.snoreAudioBand1200To3000Percent,
      sample.snoreEnvelopeLift,
      sample.snoreCrestFactor,
      sample.snoreModulationPercent,
      sample.snoreBlockScorePercent,
      sample.snoreContinuationScorePercent,
    ];
    return numericFeatures.every((value) => value?.isFinite == true) &&
        sample.snoreAudioContactArtifact != null &&
        sample.snoreMotionArtifact != null;
  }

  void _writeSnoreFeatureTrainingSample({
    required IOSink sink,
    required String label,
    required bool manualWindow,
    required String manualWindowId,
    required double? manualWindowElapsedS,
    required Mg24SensorSample sample,
  }) {
    String number(double? value, [int digits = 3]) =>
        value == null || !value.isFinite ? '' : value.toStringAsFixed(digits);
    final yamnet = _snoreDetector;
    final yamnetSnapshot = yamnet?.snapshot ?? const SnoreState.empty();
    final yamnetWindowCenterAt = yamnet?.rawWindowCenterAt;
    final yamnetWindowAgeMs = yamnetWindowCenterAt == null
        ? null
        : sample.receivedAt.difference(yamnetWindowCenterAt).inMilliseconds;
    final mg24AppSnore = _mg24AudioSnoreDetector.snapshot;
    final mg24AppWindowEndAt =
        mg24AppSnore.completedWindow?.endAt ?? mg24AppSnore.activeEndAt;
    final mg24AppWindowAgeMs = mg24AppWindowEndAt == null
        ? null
        : math.max(
            0,
            sample.receivedAt.difference(mg24AppWindowEndAt).inMilliseconds,
          );
    final yamnetTeacher = _yamnetRawSnoreTracker.snapshot;
    final yamnetTeacherWindowEndAt = yamnetTeacher.currentWindowEndAt;
    final yamnetTeacherWindowAgeMs = yamnetTeacherWindowEndAt == null
        ? null
        : math.max(
            0,
            sample.receivedAt
                .difference(yamnetTeacherWindowEndAt)
                .inMilliseconds,
          );
    final volume = snoreVolumePercent(
      SnoreState(
        isSnoring: sample.snoring ?? false,
        detectedNow: false,
        score: ((sample.snoreScore ?? 0) / 100).clamp(0.0, 1.0),
        rmsDb: sample.snoreRmsDb ?? -120,
        snoreCount: _snore.snoreCount,
        backend: 'mg24',
      ),
    );
    final trainingValues = [
      sample.receivedAt.toIso8601String(),
      'sample',
      label,
      manualWindow ? '1' : '0',
      manualWindowId,
      number(manualWindowElapsedS),
      number(sample.sensorTimeS),
      sample.snoring == true ? '1' : '0',
      number(sample.snoreScore, 0),
      number(volume, 0),
      number(sample.snoreLevelRatioPercent, 0),
      number(sample.snoreLowRatioPercent, 0),
      number(sample.snoreCrossingRatePercent, 0),
      number(sample.snoreRawSwing, 0),
      number(sample.snorePatternQualityPercent, 0),
      number(sample.snoreRatePerMin, 1),
      number(sample.snoreBreathWidthMs, 0),
      sample.snoreBurstCounter?.toString() ?? '',
      sample.snoreBurstActive == null
          ? ''
          : sample.snoreBurstActive!
              ? '1'
              : '0',
      sample.snoreBurstAgeMs?.toString() ?? '',
      number(sample.snoreActiveWidthMs, 0),
      number(sample.snoreRmsDb, 2),
      number(sample.snoreAudioBand0To150Percent, 2),
      number(sample.snoreAudioBand150To300Percent, 2),
      number(sample.snoreAudioBand300To600Percent, 2),
      number(sample.snoreAudioBand600To1200Percent, 2),
      number(sample.snoreAudioBand1200To3000Percent, 2),
      number(sample.snoreEnvelopeLift, 3),
      number(sample.snoreCrestFactor, 2),
      number(sample.snoreModulationPercent, 0),
      number(sample.snoreBlockScorePercent, 0),
      number(sample.snoreContinuationScorePercent, 0),
      sample.snoreAudioContactArtifact == null
          ? ''
          : sample.snoreAudioContactArtifact!
              ? '1'
              : '0',
      sample.snoreMotionArtifact == null
          ? ''
          : sample.snoreMotionArtifact!
              ? '1'
              : '0',
      mg24AppSnore.updatedAt == null
          ? ''
          : number(mg24AppSnore.rawProbability * 100.0, 2),
      !mg24AppSnore.available
          ? ''
          : number(mg24AppSnore.smoothedProbability * 100.0, 2),
      mg24AppSnore.updatedAt == null
          ? ''
          : mg24AppSnore.active
              ? '1'
              : '0',
      mg24AppSnore.updatedAt == null
          ? ''
          : mg24AppSnore.burstCounter.toString(),
      !mg24AppSnore.available
          ? ''
          : mg24AppSnore.active
              ? '1'
              : '0',
      mg24AppWindowAgeMs?.toString() ?? '',
      number(mg24AppSnore.activeWidthMs ?? mg24AppSnore.completedWidthMs, 0),
      number(mg24AppSnore.snoreRatePerMin, 1),
      number(yamnet == null ? null : yamnet.rawScore * 100.0, 2),
      number(
          yamnetSnapshot.backend == 'none'
              ? null
              : yamnetSnapshot.score * 100.0,
          2),
      yamnet == null
          ? ''
          : yamnet.rawCandidate
              ? '1'
              : '0',
      yamnetSnapshot.backend == 'none'
          ? ''
          : yamnetSnapshot.isSnoring
              ? '1'
              : '0',
      yamnet == null ? '' : yamnet.rawInferenceId.toString(),
      yamnetWindowAgeMs?.toString() ?? '',
      number(yamnet?.rmsDb, 2),
      yamnetTeacher.available
          ? yamnetTeacher.active
              ? '1'
              : '0'
          : '',
      yamnetTeacher.windowId == 0 ? '' : yamnetTeacher.windowId.toString(),
      yamnetTeacherWindowAgeMs?.toString() ?? '',
      number(yamnetTeacher.activeWidthMs ?? yamnetTeacher.completedWidthMs, 0),
      number(yamnetTeacher.snoreRatePerMin, 1),
    ];
    assert(trainingValues.length == _snoreTrainingColumns.length);
    sink.writeln(trainingValues.join(','));
  }

  double? _snoreTrainingWindowElapsed(DateTime at) {
    final startedAt = _snoreTrainingWindowStartedAt;
    if (!_snoreTrainingWindowActive || startedAt == null) return null;
    final elapsed = at.difference(startedAt).inMilliseconds / 1000.0;
    return elapsed >= 0 ? elapsed : 0.0;
  }

  void _processMg24Waveform(Mg24WaveformPacket packet) {
    if (packet.role != Mg24SensorRole.belly || packet.samples.isEmpty) {
      return;
    }
    if (packet.stream == Mg24WaveformPacket.respirationPeakStream) {
      _processMg24RespirationPeakEvent(packet);
      return;
    }
    if (packet.stream == Mg24WaveformPacket.respirationPreviewStream) {
      return;
    }
    if (packet.stream != Mg24WaveformPacket.respirationStream) return;
    final decodedPeriodSeconds = packet.samplePeriodUs / 1000000.0;
    final previousPeriod = _mg24BellyPlotSamplePeriodS;
    final measuredPeriodSeconds = decodedPeriodSeconds.isFinite &&
            decodedPeriodSeconds >= 0.020 &&
            decodedPeriodSeconds <= 0.080
        ? decodedPeriodSeconds
        : previousPeriod ?? 1.0 / mg24SamplingRate;
    final periodSeconds = previousPeriod == null ||
            (measuredPeriodSeconds - previousPeriod).abs() > 0.012
        ? measuredPeriodSeconds
        : previousPeriod + 0.035 * (measuredPeriodSeconds - previousPeriod);
    _mg24BellyPlotSamplePeriodS = periodSeconds;
    final fallbackNow = running ? _elapsedSeconds() : _mg24LiveSeconds();
    final receivedTime = _timeForTimestamp(packet.receivedAt, fallbackNow);
    final signalDelaySeconds = packet.trailingSampleCount * periodSeconds;
    final sensorFirstTimeS = _mg24TimelineTimeForSensorTime(
      packet.role,
      packet.firstSampleSensorTimeS,
    );
    final measuredNewestTime = sensorFirstTimeS == null
        ? math.max(0.0, receivedTime - signalDelaySeconds)
        : math.max(
            0.0,
            sensorFirstTimeS + periodSeconds * (packet.samples.length - 1),
          );
    var newestAnchorAt = sensorFirstTimeS == null
        ? packet.receivedAt.subtract(
            Duration(microseconds: (signalDelaySeconds * 1000000).round()),
          )
        : (_timestampForTimelineTime(measuredNewestTime) ?? packet.receivedAt);
    final newestSequence =
        packet.firstSampleSequence + packet.samples.length - 1;
    var newestTime = measuredNewestTime;
    final previousSequence = _mg24BellyPlotAnchorSequence;
    final previousTime = _mg24BellyPlotAnchorTimeS;
    final previousAnchorAt = _mg24BellyPlotAnchorAt;
    if (sensorFirstTimeS == null &&
        previousSequence != null &&
        previousTime != null &&
        previousTime.isFinite &&
        newestSequence > previousSequence) {
      final sequenceDelta = newestSequence - previousSequence;
      if (sequenceDelta < mg24SamplingRate * 20) {
        // Keep the visible plot continuous even if BLE drops or delays a
        // waveform packet. Packet/sample loss is reported separately; drawing
        // the missing time as an x-axis gap makes the live breathing trace jump.
        final visibleDeltaSeconds = packet.samples.length * periodSeconds;
        newestTime = previousTime + visibleDeltaSeconds;
        if (previousAnchorAt != null) {
          final predictedAnchorAt = previousAnchorAt.add(
            Duration(microseconds: (visibleDeltaSeconds * 1000000).round()),
          );
          final anchorErrorSeconds =
              newestAnchorAt.difference(predictedAnchorAt).inMicroseconds /
                  Duration.microsecondsPerSecond;
          if (anchorErrorSeconds.isFinite && anchorErrorSeconds.abs() <= 2.5) {
            newestAnchorAt = predictedAnchorAt.add(
              Duration(
                microseconds: (anchorErrorSeconds * 0.08 * 1000000).round(),
              ),
            );
          }
        }
      }
    }
    final firstTime = newestTime - periodSeconds * (packet.samples.length - 1);
    _mg24BellyPlotAnchorTimeS = newestTime;
    _mg24BellyPlotAnchorSequence = newestSequence;
    _mg24BellyPlotAnchorAt = newestAnchorAt;
    _flushScheduledSnoreBreathPlotWindows();
    final foreheadAngle = _finiteNullableOr(_mg24.forehead.rollDeg, 0);
    final bellyAngle = _finiteNullableOr(_mg24.belly.rollDeg, 0);
    for (var index = 0; index < packet.samples.length; index++) {
      final value = packet.samples[index];
      final timeS = firstTime + index * periodSeconds;
      final sampleSequence = packet.firstSampleSequence + index;
      _pushSignalSampleWindow(
        _samples,
        SignalSample(
          timeS: timeS,
          ecg: _heartRate ?? 0,
          resp: value,
          a3: foreheadAngle,
          a4: bellyAngle,
        ),
        mg24BreathingPlotSeconds.toDouble(),
        mg24BreathingPlotSeconds * mg24SamplingRate,
      );
      _rememberMg24BreathingSample(sampleSequence, timeS, value);
      if (index < packet.peaks.length && packet.peaks[index]) {
        _addMg24BreathPeak(sampleSequence, value);
      }
    }
    _flushPendingMg24BreathPeaks();
    if (_pendingMg24SnoreTimingWindows.isNotEmpty) {
      _recordConfirmedMg24SnoreTimingWindows();
    }
    _mg24BreathingSignal = packet.samples.last;
    _mg24 = _mergeMg24BreathingState(_mg24);
    snapshot = snapshot.copyWith(
      mg24: _mg24,
      snore: _snore,
      samples: _breathingPlotSamplesSnapshot(),
      snoreBreathWindows: _snoreBreathWindowSnapshot(),
      inhaleBreathWindows: _liveMg24InhaleWindowSnapshot(),
      recentSnoreBreathWindows: _recentSnoreBreathWindowSnapshot(),
      recentSnoreAssessments: _recentSnoreAssessmentSnapshot(),
      breathingPlotLatencySeconds: _breathingPlotLatencySeconds(),
      breathPeaks: _breathPeaks.toList(growable: false),
      breathCount: _breathCount,
    );
    _publishIfNeeded();
  }

  void _processMg24RespirationPeakEvent(Mg24WaveformPacket packet) {
    for (var index = 0; index < packet.samples.length; index++) {
      if (index >= packet.peaks.length || !packet.peaks[index]) continue;
      _addMg24BreathPeak(
        packet.firstSampleSequence + index,
        packet.samples[index],
      );
    }
    _flushPendingMg24BreathPeaks();
    snapshot = snapshot.copyWith(
      snore: _snore,
      breathPeaks: _breathPeaks.toList(growable: false),
      breathCount: _breathCount,
      inhaleBreathWindows: _liveMg24InhaleWindowSnapshot(),
      recentSnoreAssessments: _recentSnoreAssessmentSnapshot(),
    );
    _publishIfNeeded();
  }

  void _rememberMg24BreathingSample(
    int sequence,
    double timeS,
    double value,
  ) {
    _mg24BreathSignalBySequence[sequence] = PlotPoint(timeS, value);
    _mg24BreathSignalSequences.add(sequence);
    final periodS = _mg24BellyPlotSamplePeriodS;
    final maxSequences = periodS == null || !periodS.isFinite || periodS <= 0
        ? mg24BreathingPlotSeconds * mg24SamplingRate * 2
        : math.max(1, (mg24BreathingPlotSeconds * 2 / periodS).round());
    while (_mg24BreathSignalSequences.length > maxSequences) {
      final removed = _mg24BreathSignalSequences.removeFirst();
      _mg24BreathSignalBySequence.remove(removed);
    }
    final pendingPeak = _mg24PendingBreathPeaks.remove(sequence);
    if (pendingPeak != null) {
      _addMg24BreathPeak(sequence, pendingPeak);
    }
  }

  List<SignalSample> _breathingPlotSamplesSnapshot() {
    final samples = _samples.toList(growable: true);
    samples.sort((a, b) => a.timeS.compareTo(b.timeS));
    return List<SignalSample>.unmodifiable(samples);
  }

  void _addMg24BreathPeak(int sequence, double value) {
    if (!_mg24BreathPeakSequenceSet.add(sequence)) return;
    final resolvedPoint = _mg24BreathSignalBySequence[sequence];
    if (resolvedPoint == null) {
      _mg24BreathPeakSequenceSet.remove(sequence);
      _rememberPendingMg24BreathPeak(sequence, value);
      return;
    }
    _pushLimited(
      _breathPeaks,
      PlotPoint(resolvedPoint.x, resolvedPoint.y),
      100,
    );
    _recordLiveMg24BreathPeak(resolvedPoint.x);
    _breathCount++;
    _mg24BreathPeakSequences.add(sequence);
    while (_mg24BreathPeakSequences.length > 120) {
      final removed = _mg24BreathPeakSequences.removeFirst();
      _mg24BreathPeakSequenceSet.remove(removed);
    }
  }

  void _rememberPendingMg24BreathPeak(int sequence, double value) {
    if (_mg24PendingBreathPeaks.containsKey(sequence)) {
      _mg24PendingBreathPeaks[sequence] = value;
      return;
    }
    _mg24PendingBreathPeaks[sequence] = value;
    _mg24PendingBreathPeakSequences.add(sequence);
    while (_mg24PendingBreathPeakSequences.length > 64) {
      final removed = _mg24PendingBreathPeakSequences.removeFirst();
      _mg24PendingBreathPeaks.remove(removed);
    }
  }

  void _flushPendingMg24BreathPeaks() {
    if (_mg24PendingBreathPeaks.isEmpty) return;
    final pendingSequences = _mg24PendingBreathPeakSequences.toList(
      growable: false,
    );
    for (final sequence in pendingSequences) {
      final value = _mg24PendingBreathPeaks[sequence];
      if (value == null) continue;
      final point = _mg24BreathSignalBySequence[sequence];
      if (point == null) continue;
      _mg24PendingBreathPeaks.remove(sequence);
      _mg24PendingBreathPeakSequences.remove(sequence);
      _addMg24BreathPeak(sequence, point.y);
    }
  }

  void _processAnalog(
    List<num> analog, {
    required bool includeVitals,
    required bool includePosition,
  }) {
    if (!running || analog.length < 2) return;
    if (includePosition && analog.length < 4) return;

    final heartDetector = _heartDetector!;
    final breathingDetector = _breathingDetector!;
    final orientationEstimator = _orientationEstimator!;
    final csvAggregator = _csvAggregator!;

    final respRaw = analog[0];
    final rawEcg = analog[1];
    final accRawValues =
        includePosition ? [analog[2], analog[3]] : const <num>[];
    final a3Raw = includePosition ? analog[2].toDouble() : 0.0;
    final a4Raw = includePosition ? analog[3].toDouble() : 0.0;

    final heart =
        includeVitals ? heartDetector.update(adcToEcgMv(rawEcg)) : null;
    final breathing = includeVitals ? breathingDetector.update(respRaw) : null;
    final orientation = includePosition
        ? orientationEstimator.update(accRawValues)
        : _orientation;
    final csvOrientation =
        includePosition ? orientation : _inactiveOrientationState;
    final now = DateTime.now();
    final timeS =
        includeVitals ? _sampleNumber / samplingRate : _elapsedSeconds();
    final snore = _snoreStateAt(timeS);
    _sampleNumber++;

    if (includeVitals) {
      _heartRate = heart!.heartRate;
      _breathingRate = breathing!.breathingRate;
    } else {
      _heartRate = _radar.heartRateBpm;
      _breathingRate = _radar.breathingRatePerMin;
    }
    _orientation = orientation;
    _updateSnoreTimeline(snore, now);
    _snore = snore;
    if (includeVitals) {
      _sleepStats.add(
        heartRate: heart!.heartRate,
        breathingRate: breathing!.breathingRate,
        relativeAngleDeg:
            includePosition ? orientation.relativeAngleDeg : double.nan,
        isSnoring: _snoreActiveForSleepStats(snore, now),
        sampledAt: now,
        hasSnoreData: snore.backend != 'none',
      );
    }

    _pushLimited(
      _samples,
      SignalSample(
        timeS: timeS,
        ecg: includeVitals ? heart!.filteredEcg : _radar.heartRateBpm ?? 0,
        resp: includeVitals
            ? breathing!.filteredResp
            : _radar.breathingRatePerMin ?? 0,
        a3: includeVitals ? a3Raw : orientation.foreheadAngleDeg,
        a4: includeVitals ? a4Raw : orientation.chestAngleDeg,
      ),
      plotSeconds * samplingRate,
    );

    if (includeVitals && heart!.isPeak) {
      _rPeakCount++;
      _pushLimited(
        _rPeaks,
        PlotPoint(math.max(0, timeS - 1 / samplingRate),
            heart.peakValue ?? heart.filteredEcg),
        100,
      );
    }

    if (includeVitals &&
        breathing!.isBreath &&
        breathing.breathPeakTime != null) {
      _breathCount++;
      _pushLimited(
        _breathPeaks,
        PlotPoint(breathing.breathPeakTime!,
            breathing.breathPeakValue ?? breathing.filteredResp),
        100,
      );
    }

    if (includeVitals) {
      final rows = csvAggregator.update(
        timeS,
        heart!.heartRate,
        breathing!.breathingRate,
        null,
        snore,
        csvOrientation,
        _radar,
        _mg24,
      );
      for (final row in rows) {
        _csvSink?.writeln(row.join(','));
      }
    }

    _publishIfNeeded();
  }

  void _publishIfNeeded({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify) < _streamingPublishInterval) {
      return;
    }
    _lastNotify = now;
    snapshot = MeasurementSnapshot(
      running: snapshot.running,
      status: snapshot.status,
      fileLabel: snapshot.fileLabel,
      csvPath: snapshot.csvPath,
      csvDirectoryPath: snapshot.csvDirectoryPath,
      measurementStartedAt: _measurementStartedAt ??
          _mg24LiveStartedAt ??
          snapshot.measurementStartedAt,
      heartRate: _heartRate,
      breathingRate: _breathingRate,
      oxygenSaturation: _oxygenSaturation,
      radar: _radar,
      mg24: _mg24,
      orientation: _orientation,
      snore: _snore,
      snoreTimeline: _snoreTimelineSnapshot(),
      snoreBreathWindows: _snoreBreathWindowSnapshot(),
      inhaleBreathWindows: _liveMg24InhaleWindowSnapshot(),
      recentSnoreBreathWindows: _recentSnoreBreathWindowSnapshot(),
      recentSnoreAssessments: _recentSnoreAssessmentSnapshot(),
      breathingPlotLatencySeconds: _breathingPlotLatencySeconds(),
      samples: _breathingPlotSamplesSnapshot(),
      rPeaks: _rPeaks.toList(growable: false),
      breathPeaks: _breathPeaks.toList(growable: false),
      rPeakCount: _rPeakCount,
      breathCount: _breathCount,
    );
    notifyListeners();
  }

  SnoreState _snoreStateAt(double timeS) {
    final detector = _snoreDetector;
    final raw = detector == null
        ? const SnoreState.empty()
        : _measurementYamnetCaptureActive
            ? _snoreStateFromYamnet(detector, _yamnetRawSnoreTracker.snapshot)
            : detector.snapshot;
    return _snoreStateWithSource(raw, timeS);
  }

  SnoreState _snoreStateWithSource(SnoreState raw, double timeS) {
    final now = DateTime.now();
    if (raw.backend == 'none') {
      _resetSnoreSourceTracking();
      return raw;
    }
    final active = raw.isSnoring || raw.detectedNow || raw.snoreBurstActive;
    if (active) {
      _lastSnoreSourceActivityAt = now;
    } else {
      final lastActivity = _lastSnoreSourceActivityAt;
      if (lastActivity == null ||
          now.difference(lastActivity) > const Duration(seconds: 10)) {
        _resetSnoreSourceTracking();
        return raw.copyWith(source: 'unknown', sourceConfidence: 0);
      }
    }
    if (raw.backend != 'yamnet' &&
        raw.detectedNow &&
        raw.inferenceId != _lastSnoreSourceInferenceId) {
      _lastSnoreSourceInferenceId = raw.inferenceId;
      _updateSnoreSourceEvidence(raw, timeS);
    }
    final confirmedAt = _confirmedSnoreSourceAt;
    if (confirmedAt != null &&
        now.difference(confirmedAt) <= const Duration(seconds: 10)) {
      return raw.copyWith(
        source: _confirmedSnoreSource,
        sourceConfidence: _confirmedSnoreSourceConfidence,
      );
    }
    return raw.copyWith(
      source: _snoreSource,
      sourceConfidence: _snoreSourceConfidence,
    );
  }

  void _resetSnoreSourceTracking() {
    _snoreBreathEvidence.clear();
    _lastSnoreSourceInferenceId = null;
    _lastSnoreSourceActivityAt = null;
    _snoreSource = 'unknown';
    _snoreSourceConfidence = 0;
    _confirmedSnoreSource = 'unknown';
    _confirmedSnoreSourceConfidence = 0;
    _confirmedSnoreSourceAt = null;
  }

  List<TimeWindow> _snoreBreathWindowSnapshot() {
    if (_measurementYamnetWasRecorded) {
      return _measurementYamnetPlotWindowSnapshot();
    }
    _flushScheduledSnoreBreathPlotWindows();
    _pruneSnoreBreathPlotWindows();
    final windows = _snoreBreathWindows.toList(growable: true);
    return List<TimeWindow>.unmodifiable(
      _deduplicateSnoreBreathPlotWindows(windows),
    );
  }

  List<TimeWindow> _measurementYamnetPlotWindowSnapshot() {
    final startedAt = _measurementStartedAt ?? _sleepCycleStartedAt;
    if (startedAt == null) return const [];
    final windows = <YamnetRawSnoreWindow>[
      ..._measurementYamnetWindows,
      if (_measurementYamnetCaptureActive)
        if (_yamnetRawSnoreTracker.snapshot.activeStartAt != null &&
            _yamnetRawSnoreTracker.snapshot.activeEndAt != null)
          YamnetRawSnoreWindow(
            startAt: _yamnetRawSnoreTracker.snapshot.activeStartAt!,
            endAt: _yamnetRawSnoreTracker.snapshot.activeEndAt!,
          ),
    ];
    final latestPlotTime =
        _samples.isEmpty ? _elapsedSeconds() : _samples.last.timeS;
    final earliestPlotTime =
        math.max(0.0, latestPlotTime - mg24BreathingPlotSeconds - 2.0);
    final result = <TimeWindow>[];
    for (final window in windows) {
      final mapped = yamnetWindowOnTimeline(
        window,
        fallbackStartedAt: startedAt,
        timelineAnchorAt: _mg24BellyPlotAnchorAt,
        timelineAnchorS: _mg24BellyPlotAnchorTimeS,
      );
      if (mapped == null) continue;
      final startS = mapped.startS;
      final endS = mapped.endS;
      if (endS < earliestPlotTime || startS > latestPlotTime + 2.0) continue;
      result.add(mapped);
    }
    result.sort((a, b) => a.startS.compareTo(b.startS));
    return List<TimeWindow>.unmodifiable(result);
  }

  List<TimeWindow> _recentSnoreBreathWindowSnapshot() {
    final windows = _deduplicateSnoreBreathPlotWindows(
      _recentConfirmedSnoreBreathWindows,
    );
    final start = math.max(0, windows.length - 3);
    return List<TimeWindow>.unmodifiable(windows.sublist(start));
  }

  bool get _usingConfirmedYamnetWindows =>
      (_measurementYamnetWasRecorded && _measurementYamnetWindows.isNotEmpty) ||
      _liveYamnetWindows.isNotEmpty;

  List<TimeWindow> _confirmedSnoreWindowsForInhale() {
    final yamnetWindows = _measurementYamnetWasRecorded
        ? _measurementYamnetWindows
        : _liveYamnetWindows.toList(growable: false);
    if (yamnetWindows.isNotEmpty) {
      final startedAt =
          _measurementStartedAt ?? _sleepCycleStartedAt ?? _mg24LiveStartedAt;
      if (startedAt != null) {
        final result = <TimeWindow>[];
        for (final window in yamnetWindows) {
          final mapped = yamnetWindowOnTimeline(
            window,
            fallbackStartedAt: startedAt,
            timelineAnchorAt: _mg24BellyPlotAnchorAt,
            timelineAnchorS: _mg24BellyPlotAnchorTimeS,
          );
          if (mapped != null) result.add(mapped);
        }
        if (result.isNotEmpty) {
          result.sort((a, b) => a.startS.compareTo(b.startS));
          return List<TimeWindow>.unmodifiable(result);
        }
      }
    }
    return _snoreBreathWindowSnapshot();
  }

  List<SnoreWindowAssessment> _confirmedLiveSnoreAssessments() {
    final usingYamnet = _usingConfirmedYamnetWindows;
    var windows = usingYamnet
        ? _confirmedSnoreWindowsForInhale()
        : _recentSnoreBreathWindowSnapshot();
    if (windows.isEmpty || _liveMg24BreathEvents.isEmpty) return const [];
    if (windows.length > 24) {
      windows = windows.sublist(windows.length - 24);
    }

    final events = <Mg24EventRecord>[
      for (final window in windows)
        _liveMg24EventRecord(
          window.startS,
          window.endS - window.startS,
          qualityPercent: 100,
        ),
    ];
    final breaths = _liveMg24BreathEvents.toList(growable: false);
    final sourceBySnore = _classifyOfflineSnoreSources(
      events,
      breaths,
      snoreBoundaryUncertaintyS:
          usingYamnet ? yamnetBoundaryUncertaintySeconds : 0,
    );
    return List<SnoreWindowAssessment>.unmodifiable([
      for (var i = 0; i < events.length; i++)
        SnoreWindowAssessment(
          window: windows[i],
          source: sourceBySnore[events[i]]?.source ?? 'unknown',
          sourceConfidence: sourceBySnore[events[i]]?.confidence ?? 0,
          overlapRatio: sourceBySnore[events[i]]?.overlapRatio ?? 0,
          inhaleWindow: sourceBySnore[events[i]]?.breathStartS == null ||
                  sourceBySnore[events[i]]?.breathEndS == null
              ? null
              : TimeWindow(
                  sourceBySnore[events[i]]!.breathStartS!,
                  sourceBySnore[events[i]]!.breathEndS!,
                ),
        ),
    ]);
  }

  void _refreshLiveConfirmedSnoreSource() {
    if (!_usingConfirmedYamnetWindows) return;
    final assessments = _confirmedLiveSnoreAssessments();
    if (assessments.isEmpty) return;
    final latest = assessments.last;
    final now = DateTime.now();
    final sourceAt = _timestampForTimelineTime(latest.window.endS) ?? now;
    final sourceAge = now.difference(sourceAt);
    if (!sourceAge.isNegative && sourceAge > const Duration(seconds: 10)) {
      return;
    }
    _confirmedSnoreSource = latest.source;
    _confirmedSnoreSourceConfidence = latest.sourceConfidence;
    _confirmedSnoreSourceAt = sourceAt.isAfter(now) ? now : sourceAt;
    _lastSnoreSourceActivityAt = _confirmedSnoreSourceAt;
    if (_snore.backend == 'yamnet') {
      _snore = _snore.copyWith(
        source: latest.source,
        sourceConfidence: latest.sourceConfidence,
      );
    }
  }

  List<TimeWindow> _liveMg24InhaleWindowSnapshot() {
    if (_liveMg24BreathEvents.isEmpty) {
      return const [];
    }
    // Use confirmed classifier windows on the breathing plot's timebase.
    // YAMNet is currently the primary classifier, so relying only on older
    // board-window assessments left the inhale overlay empty.
    final snores = _confirmedSnoreWindowsForInhale()
        .where((window) => window.endS > window.startS)
        .map(
          (window) => _liveMg24EventRecord(
            window.startS,
            window.endS - window.startS,
            qualityPercent: 100,
          ),
        )
        .toList(growable: false);
    if (snores.isEmpty) return const [];
    final breaths = _liveMg24BreathEvents.toList(growable: false);
    final plotEndS = _latestBreathingPlotTimeS();
    final minTimeS = plotEndS == null
        ? 0.0
        : math.max(0.0, plotEndS - mg24BreathingPlotSeconds - 2.0);
    return _inhaleWindowsForEvents(
      snores: snores,
      breaths: breaths,
      minTimeS: minTimeS,
      snoreBoundaryUncertaintyS:
          _usingConfirmedYamnetWindows ? yamnetBoundaryUncertaintySeconds : 0,
    );
  }

  List<TimeWindow> _inhaleWindowsForEvents({
    required List<Mg24EventRecord> snores,
    required List<Mg24EventRecord> breaths,
    required double minTimeS,
    double snoreBoundaryUncertaintyS = 0,
  }) {
    final phase = _offlineBreathPhasePreference(
      snores,
      breaths,
      snoreBoundaryUncertaintyS: snoreBoundaryUncertaintyS,
    ).phase;
    if (phase == 0) return const [];
    final windows = <TimeWindow>[];
    for (final breath in breaths) {
      if (breath.endSeconds < minTimeS) continue;
      final half = breath.durationSeconds * 0.5;
      windows.add(
        phase == 1
            ? TimeWindow(breath.startSeconds, breath.startSeconds + half)
            : TimeWindow(breath.startSeconds + half, breath.endSeconds),
      );
    }
    return List<TimeWindow>.unmodifiable(windows);
  }

  @visibleForTesting
  List<TimeWindow> inhaleWindowsForTest({
    required List<Mg24EventRecord> snores,
    required List<Mg24EventRecord> breaths,
    double minTimeS = 0,
  }) =>
      _inhaleWindowsForEvents(
        snores: snores,
        breaths: breaths,
        minTimeS: minTimeS,
      );

  List<SnoreWindowAssessment> _recentSnoreAssessmentSnapshot() {
    return _confirmedLiveSnoreAssessments();
  }

  double? _recentBreathingPeriodSeconds() {
    final peakTimes = _breathPeaks
        .map((point) => point.x)
        .where((time) => time.isFinite)
        .toList()
      ..sort();
    final intervals = <double>[];
    final recentPeaks = peakTimes.length > 8
        ? peakTimes.sublist(peakTimes.length - 8)
        : peakTimes;
    for (var i = 1; i < recentPeaks.length; i++) {
      final interval = recentPeaks[i] - recentPeaks[i - 1];
      if (interval >= 1.8 && interval <= 10.0) {
        intervals.add(interval);
      }
    }
    if (intervals.length >= 2) {
      final period = median(intervals);
      if (period.isFinite && period >= 1.8 && period <= 10.0) {
        return period;
      }
    }
    final rate = _mg24BreathingRate;
    if (rate != null && rate.isFinite && rate >= 6.0 && rate <= 34.0) {
      final period = 60.0 / rate;
      if (period >= 1.8 && period <= 10.0) return period;
    }
    return null;
  }

  void _updateSnoreSourceEvidence(SnoreState snore, double fallbackTimeS) {
    final timeS = _snoreWindowTimeS(snore, fallbackTimeS);
    if (!timeS.isFinite) return;

    final alignment = _snoreBreathingAlignment(timeS);
    final vibration = _imuSnoreVibrationDetector.evidenceAt(timeS);
    if (alignment == null && !vibration.hasData) return;
    final audioDurationS =
        ((snore.snoreBreathWidthMs ?? 0) / 1000.0).clamp(0.0, 4.0).toDouble();
    final inhaleDurationS = _estimatedInhaleDurationSeconds(timeS);
    final durationMatch = _snoreInhaleDurationMatch(
      audioDurationS,
      inhaleDurationS,
    );
    final frequencyMatch = _snoreBreathingFrequencyMatch(
      snore.snoreRatePerMin,
      _mg24BreathingRate,
    );

    final volume = snoreVolumePercent(snore);
    final volumeWeight = volume == null
        ? 0.55
        : (0.35 + 0.65 * (volume / 100).clamp(0.0, 1.0)).toDouble();
    final scoreWeight =
        (0.55 + 0.45 * (snore.score / 0.35).clamp(0.0, 1.0)).toDouble();
    _snoreBreathEvidence.addLast(
      _SnoreBreathEvidence(
        phase: alignment?.phase,
        normalizedSlope: alignment?.bestInhaleSlope,
        centerSlope: alignment?.centerSlope,
        bestOffsetS: alignment?.bestOffsetS ?? 0,
        imuVibrationScore: vibration.vibrationScore,
        imuQuietScore: vibration.quietScore,
        imuArtifactScore: vibration.artifactScore,
        imuVibrationSamples: vibration.sampleCount,
        audioDurationS: audioDurationS > 0 ? audioDurationS : null,
        inhaleDurationS: inhaleDurationS,
        durationMatchScore: durationMatch,
        frequencyMatchScore: frequencyMatch,
        audioWeight: volumeWeight * scoreWeight,
      ),
    );
    while (_snoreBreathEvidence.length > 24) {
      _snoreBreathEvidence.removeFirst();
    }
    _refreshSnoreSourceFromEvidence();
  }

  double? _breathPhaseAt(double timeS) {
    final peaks = _breathPeaks
        .map((point) => point.x)
        .where((peak) =>
            peak.isFinite && peak <= timeS + 0.35 && timeS - peak <= 90)
        .toList()
      ..sort();
    if (peaks.length < 3) return null;
    final recentPeaks =
        peaks.length > 10 ? peaks.sublist(peaks.length - 10) : peaks;
    final intervals = <double>[];
    for (var i = 1; i < recentPeaks.length; i++) {
      final interval = recentPeaks[i] - recentPeaks[i - 1];
      if (interval >= 1.8 && interval <= 10.0) {
        intervals.add(interval);
      }
    }
    if (intervals.length < 2) return null;
    final period = median(intervals);
    if (!period.isFinite || period < 1.8 || period > 10.0) return null;

    final lastPeak = recentPeaks.lastWhere(
      (peak) => peak <= timeS + 0.35,
      orElse: () => recentPeaks.last,
    );
    var phase = ((timeS - lastPeak) / period) % 1.0;
    if (phase < 0) phase += 1.0;
    return phase;
  }

  double? _estimatedInhaleDurationSeconds(double timeS) {
    final period = _recentBreathingPeriodSeconds();
    if (period == null) return null;
    final samplesAround = _samples
        .where((sample) =>
            sample.timeS.isFinite &&
            sample.resp.isFinite &&
            sample.timeS >= timeS - period &&
            sample.timeS <= timeS + period)
        .toList(growable: false);
    if (samplesAround.length < mg24SamplingRate) {
      return (period * 0.5).clamp(0.75, 3.4).toDouble();
    }
    final span = _breathingDisplaySpan(timeS);
    if (span == null || span <= 1e-6) {
      return (period * 0.5).clamp(0.75, 3.4).toDouble();
    }
    final slopes = <double>[];
    for (var i = 1; i < samplesAround.length; i++) {
      final previous = samplesAround[i - 1];
      final current = samplesAround[i];
      final dt = current.timeS - previous.timeS;
      if (dt <= 0 || dt > 0.2) continue;
      slopes.add((current.resp - previous.resp) / dt / span);
    }
    if (slopes.length < 6) {
      return (period * 0.5).clamp(0.75, 3.4).toDouble();
    }
    final positiveThreshold = math.max(0.035, percentile(slopes, 72) * 0.42);
    var positiveRunS = 0.0;
    var bestRunS = 0.0;
    for (var i = 1; i < samplesAround.length; i++) {
      final previous = samplesAround[i - 1];
      final current = samplesAround[i];
      final dt = current.timeS - previous.timeS;
      if (dt <= 0 || dt > 0.2) {
        positiveRunS = 0;
        continue;
      }
      final slope = (current.resp - previous.resp) / dt / span;
      if (slope >= positiveThreshold) {
        positiveRunS += dt;
        if (positiveRunS > bestRunS) bestRunS = positiveRunS;
      } else if (slope >= -positiveThreshold * 0.35) {
        positiveRunS += dt * 0.45;
        if (positiveRunS > bestRunS) bestRunS = positiveRunS;
      } else {
        positiveRunS = 0;
      }
    }
    if (bestRunS >= 0.45 && bestRunS <= period * 0.8) {
      return bestRunS.clamp(0.55, 3.4).toDouble();
    }
    return (period * 0.5).clamp(0.75, 3.4).toDouble();
  }

  double? _snoreInhaleDurationMatch(
    double audioDurationS,
    double? inhaleDurationS,
  ) {
    if (!audioDurationS.isFinite ||
        audioDurationS <= 0 ||
        inhaleDurationS == null ||
        !inhaleDurationS.isFinite ||
        inhaleDurationS <= 0) {
      return null;
    }
    final ratio = audioDurationS / inhaleDurationS;
    if (ratio <= 0) return null;
    final logError = (math.log(ratio) / math.ln2).abs();
    final broadMatch = (1.0 - logError / 1.05).clamp(0.0, 1.0).toDouble();
    final tooShortPenalty = ratio < 0.28 ? ((0.28 - ratio) / 0.28) : 0.0;
    return (broadMatch * (1.0 - tooShortPenalty * 0.65))
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double? _snoreBreathingFrequencyMatch(
    double? snoreRatePerMin,
    double? breathingRatePerMin,
  ) {
    if (snoreRatePerMin == null ||
        breathingRatePerMin == null ||
        !snoreRatePerMin.isFinite ||
        !breathingRatePerMin.isFinite ||
        snoreRatePerMin < 4.0 ||
        snoreRatePerMin > 45.0 ||
        breathingRatePerMin < 4.0 ||
        breathingRatePerMin > 45.0) {
      return null;
    }
    final ratio = snoreRatePerMin / breathingRatePerMin;
    if (ratio <= 0) return null;
    final logError = (math.log(ratio) / math.ln2).abs();
    return (1.0 - logError / 0.75).clamp(0.0, 1.0).toDouble();
  }

  double _snoreWindowTimeS(SnoreState snore, double fallbackTimeS) {
    final windowCenterAt = snore.windowCenterAt;
    if (windowCenterAt == null) return fallbackTimeS;
    return _plotTimeForTimestamp(windowCenterAt, fallbackTimeS) +
        _mg24SnoreToBreathingPlotOffsetSeconds;
  }

  double _plotTimeForTimestamp(DateTime timestamp, double fallbackTimeS) {
    return _breathingPlotTimeForTimestamp(timestamp) ??
        _timeForTimestamp(timestamp, fallbackTimeS);
  }

  _Mg24SensorClockMapper _mg24SensorClock(Mg24SensorRole role) =>
      _mg24SensorClocks[role]!;

  void _resetMg24SensorClocks() {
    for (final clock in _mg24SensorClocks.values) {
      clock.reset();
    }
  }

  double? _syncMg24SensorClock(
    Mg24SensorRole role,
    double? sensorTimeS,
    DateTime receivedAt,
    double fallbackTimeS,
  ) {
    if (sensorTimeS == null || !sensorTimeS.isFinite || sensorTimeS < 0) {
      return null;
    }
    final receivedTimelineS = _timeForTimestamp(receivedAt, fallbackTimeS);
    return _mg24SensorClock(role).update(
      sensorTimeS: sensorTimeS,
      receivedTimelineS: receivedTimelineS,
    );
  }

  double? _mg24TimelineTimeForSensorTime(
    Mg24SensorRole role,
    double? sensorTimeS,
  ) {
    if (sensorTimeS == null || !sensorTimeS.isFinite || sensorTimeS < 0) {
      return null;
    }
    return _mg24SensorClock(role).timelineTimeForSensorTime(sensorTimeS);
  }

  DateTime? _timestampForTimelineTime(double timeS) {
    final startedAt = _measurementStartedAt ?? _mg24LiveStartedAt;
    if (startedAt == null || !timeS.isFinite || timeS < 0) return null;
    return startedAt.add(
      Duration(microseconds: (timeS * 1000000).round()),
    );
  }

  double _timeForTimestamp(DateTime timestamp, double fallbackTimeS) {
    final startedAt = _measurementStartedAt ?? _mg24LiveStartedAt;
    if (startedAt == null) return fallbackTimeS;
    final timeS = timestamp.difference(startedAt).inMicroseconds /
        Duration.microsecondsPerSecond;
    return timeS.isFinite ? timeS : fallbackTimeS;
  }

  _SnoreBreathingAlignment? _snoreBreathingAlignment(double timeS) {
    final centerSlope = _breathingSlopeAt(timeS);
    const offsets = <double>[
      -0.55,
      -0.35,
      -0.18,
      0.0,
      0.18,
      0.35,
      0.55,
      0.85,
      1.15,
      1.45,
      1.75,
    ];
    double? bestSlope;
    double bestOffset = 0;
    for (final offset in offsets) {
      final slope = _breathingSlopeAt(timeS + offset);
      if (slope == null || !slope.isFinite) continue;
      final offsetPenalty = offset.abs() * 0.055;
      final score = slope - offsetPenalty;
      final bestScore = bestSlope == null
          ? double.negativeInfinity
          : bestSlope - bestOffset.abs() * 0.055;
      if (score > bestScore) {
        bestSlope = slope;
        bestOffset = offset;
      }
    }
    if (bestSlope == null && centerSlope == null) return null;
    final alignedTimeS = timeS + bestOffset;
    return _SnoreBreathingAlignment(
      phase: _breathPhaseAt(alignedTimeS),
      bestInhaleSlope: bestSlope ?? centerSlope,
      centerSlope: centerSlope,
      bestOffsetS: bestOffset,
    );
  }

  double? _breathingSlopeAt(double timeS) {
    final points = _samples
        .where((sample) =>
            sample.timeS.isFinite &&
            sample.resp.isFinite &&
            (sample.timeS - timeS).abs() <= 0.55)
        .toList(growable: false);
    if (points.length < 5) return null;

    final span = _breathingDisplaySpan(timeS);
    if (span == null || span <= 1e-6) return null;

    var meanT = 0.0;
    var meanY = 0.0;
    for (final point in points) {
      meanT += point.timeS;
      meanY += point.resp;
    }
    meanT /= points.length;
    meanY /= points.length;

    var numerator = 0.0;
    var denominator = 0.0;
    for (final point in points) {
      final dt = point.timeS - meanT;
      numerator += dt * (point.resp - meanY);
      denominator += dt * dt;
    }
    if (denominator <= 1e-9) return null;
    return numerator / denominator / span;
  }

  double? _breathingDisplaySpan(double timeS) {
    final values = _samples
        .where((sample) =>
            sample.timeS.isFinite &&
            sample.resp.isFinite &&
            sample.timeS <= timeS + 0.8 &&
            timeS - sample.timeS <= 12)
        .map((sample) => sample.resp)
        .toList(growable: false);
    if (values.length < mg24SamplingRate * 4) return null;
    final span = percentile(values, 90) - percentile(values, 10);
    return span.isFinite && span > 0 ? span : null;
  }

  void _refreshSnoreSourceFromEvidence() {
    final count = _snoreBreathEvidence.length;
    if (count < 3) {
      _snoreSource = 'unknown';
      _snoreSourceConfidence = 0;
      return;
    }

    var sumCos = 0.0;
    var sumSin = 0.0;
    var phaseWeightTotal = 0.0;
    var positiveSlopeTotal = 0.0;
    var centeredAbsTotal = 0.0;
    var positiveHitWeight = 0.0;
    var negativeHitWeight = 0.0;
    var closeAlignmentWeight = 0.0;
    var slopeWeightTotal = 0.0;
    var vibrationTotal = 0.0;
    var vibrationHitWeight = 0.0;
    var vibrationQuietTotal = 0.0;
    var vibrationQuietWeight = 0.0;
    var vibrationArtifactTotal = 0.0;
    var vibrationWeightTotal = 0.0;
    var durationMatchTotal = 0.0;
    var durationHitWeight = 0.0;
    var durationMismatchWeight = 0.0;
    var durationWeightTotal = 0.0;
    var frequencyMatchTotal = 0.0;
    var frequencyHitWeight = 0.0;
    var frequencyMismatchWeight = 0.0;
    var frequencyWeightTotal = 0.0;
    for (final evidence in _snoreBreathEvidence) {
      final weight = evidence.audioWeight;
      if (evidence.imuVibrationSamples >= 4) {
        vibrationTotal += weight * evidence.imuVibrationScore;
        vibrationQuietTotal += weight * evidence.imuQuietScore;
        vibrationArtifactTotal += weight * evidence.imuArtifactScore;
        vibrationWeightTotal += weight;
        if (evidence.imuVibrationScore >= 0.36) {
          vibrationHitWeight += weight;
        }
        if (evidence.imuQuietScore >= 0.45) {
          vibrationQuietWeight += weight;
        }
      }
      final durationMatch = evidence.durationMatchScore;
      if (durationMatch != null) {
        durationMatchTotal += weight * durationMatch;
        durationWeightTotal += weight;
        if (durationMatch >= 0.58) {
          durationHitWeight += weight;
        }
        if (durationMatch <= 0.24) {
          durationMismatchWeight += weight;
        }
      }
      final frequencyMatch = evidence.frequencyMatchScore;
      if (frequencyMatch != null) {
        frequencyMatchTotal += weight * frequencyMatch;
        frequencyWeightTotal += weight;
        if (frequencyMatch >= 0.60) {
          frequencyHitWeight += weight;
        }
        if (frequencyMatch <= 0.22) {
          frequencyMismatchWeight += weight;
        }
      }
      final phase = evidence.phase;
      if (phase != null) {
        final theta = phase * 2 * math.pi;
        sumCos += weight * math.cos(theta);
        sumSin += weight * math.sin(theta);
        phaseWeightTotal += weight;
      }
      final slope = evidence.normalizedSlope;
      if (slope != null) {
        positiveSlopeTotal += weight * math.max(0.0, slope);
        if (slope > 0.10) positiveHitWeight += weight;
        if (slope < -0.08) negativeHitWeight += weight;
        if (evidence.bestOffsetS.abs() <= 0.35) {
          closeAlignmentWeight += weight;
        }
        final centerSlope = evidence.centerSlope;
        if (centerSlope != null) {
          centeredAbsTotal += weight * centerSlope.abs();
        }
        slopeWeightTotal += weight;
      }
    }
    final phaseConcentration = phaseWeightTotal <= 0
        ? 0.0
        : math.sqrt(sumCos * sumCos + sumSin * sumSin) / phaseWeightTotal;
    final meanPositiveSlope =
        slopeWeightTotal <= 0 ? 0.0 : positiveSlopeTotal / slopeWeightTotal;
    final positiveHitRate =
        slopeWeightTotal <= 0 ? 0.0 : positiveHitWeight / slopeWeightTotal;
    final negativeHitRate =
        slopeWeightTotal <= 0 ? 0.0 : negativeHitWeight / slopeWeightTotal;
    final closeAlignmentRate =
        slopeWeightTotal <= 0 ? 0.0 : closeAlignmentWeight / slopeWeightTotal;
    final meanCenteredAbsSlope =
        slopeWeightTotal <= 0 ? 0.0 : centeredAbsTotal / slopeWeightTotal;
    final meanVibration =
        vibrationWeightTotal <= 0 ? 0.0 : vibrationTotal / vibrationWeightTotal;
    final vibrationHitRate = vibrationWeightTotal <= 0
        ? 0.0
        : vibrationHitWeight / vibrationWeightTotal;
    final meanQuiet = vibrationWeightTotal <= 0
        ? 0.0
        : vibrationQuietTotal / vibrationWeightTotal;
    final quietHitRate = vibrationWeightTotal <= 0
        ? 0.0
        : vibrationQuietWeight / vibrationWeightTotal;
    final meanArtifact = vibrationWeightTotal <= 0
        ? 0.0
        : vibrationArtifactTotal / vibrationWeightTotal;
    final meanDurationMatch = durationWeightTotal <= 0
        ? 0.0
        : durationMatchTotal / durationWeightTotal;
    final durationHitRate = durationWeightTotal <= 0
        ? 0.0
        : durationHitWeight / durationWeightTotal;
    final durationMismatchRate = durationWeightTotal <= 0
        ? 0.0
        : durationMismatchWeight / durationWeightTotal;
    final meanFrequencyMatch = frequencyWeightTotal <= 0
        ? 0.0
        : frequencyMatchTotal / frequencyWeightTotal;
    final frequencyHitRate = frequencyWeightTotal <= 0
        ? 0.0
        : frequencyHitWeight / frequencyWeightTotal;
    final frequencyMismatchRate = frequencyWeightTotal <= 0
        ? 0.0
        : frequencyMismatchWeight / frequencyWeightTotal;
    final sampleConfidence = (count / 7).clamp(0.0, 1.0).toDouble();
    final phaseScore =
        ((phaseConcentration - 0.42) / 0.38).clamp(0.0, 1.0).toDouble() *
            positiveHitRate.clamp(0.0, 1.0);
    final slopeScore =
        ((meanPositiveSlope - 0.055) / 0.22).clamp(0.0, 1.0).toDouble() *
            ((positiveHitRate - 0.34) / 0.42).clamp(0.0, 1.0).toDouble();
    final timingScore =
        ((closeAlignmentRate - 0.28) / 0.45).clamp(0.0, 1.0).toDouble();
    final durationScore =
        ((meanDurationMatch - 0.42) / 0.40).clamp(0.0, 1.0).toDouble() *
            ((durationHitRate - 0.24) / 0.48).clamp(0.0, 1.0).toDouble();
    final frequencyScore =
        ((meanFrequencyMatch - 0.45) / 0.38).clamp(0.0, 1.0).toDouble() *
            ((frequencyHitRate - 0.24) / 0.48).clamp(0.0, 1.0).toDouble();
    final vibrationWearerScore =
        ((meanVibration - 0.24) / 0.48).clamp(0.0, 1.0).toDouble() *
            ((vibrationHitRate - 0.22) / 0.48).clamp(0.0, 1.0).toDouble();
    final breathingWearerScore = math
        .max(
            slopeScore,
            math.max(
                durationScore * math.max(phaseScore, timingScore),
                math.max(
                    frequencyScore * math.max(durationScore, timingScore),
                    math.max(
                        phaseScore * 0.55, timingScore * slopeScore * 0.75))))
        .toDouble();
    final quietPenalty = (1.0 - math.max(meanQuiet, quietHitRate) * 0.85)
        .clamp(0.0, 1.0)
        .toDouble();
    final artifactPenalty =
        (1.0 - meanArtifact * 0.75).clamp(0.0, 1.0).toDouble();
    final wearerConfidence = math
            .max(vibrationWearerScore, breathingWearerScore * quietPenalty)
            .toDouble() *
        sampleConfidence *
        artifactPenalty;
    final externalSampleConfidence =
        ((count - 3) / 7).clamp(0.0, 1.0).toDouble();
    final weakInhaleCoupling =
        ((0.42 - positiveHitRate) / 0.42).clamp(0.0, 1.0).toDouble();
    final weakSlopeCoupling =
        ((0.075 - meanPositiveSlope) / 0.075).clamp(0.0, 1.0).toDouble();
    final randomPhaseScore =
        ((0.52 - phaseConcentration) / 0.52).clamp(0.0, 1.0).toDouble();
    final negativeOrUncoupledScore = math.max(
        weakInhaleCoupling, math.max(weakSlopeCoupling, negativeHitRate));
    final centeredWeakScore =
        ((0.065 - meanCenteredAbsSlope) / 0.065).clamp(0.0, 1.0).toDouble();
    final durationMismatchScore =
        ((durationMismatchRate - 0.18) / 0.52).clamp(0.0, 1.0).toDouble();
    final frequencyMismatchScore =
        ((frequencyMismatchRate - 0.18) / 0.52).clamp(0.0, 1.0).toDouble();
    final vibrationQuietScore =
        (0.62 * meanQuiet + 0.38 * quietHitRate).clamp(0.0, 1.0).toDouble();
    final vibrationMissingScore =
        ((0.25 - meanVibration) / 0.25).clamp(0.0, 1.0).toDouble();
    final externalConfidence = externalSampleConfidence *
        (0.42 * vibrationQuietScore +
            0.22 * vibrationMissingScore +
            0.14 * randomPhaseScore +
            0.08 * negativeOrUncoupledScore +
            0.06 * durationMismatchScore +
            0.04 * frequencyMismatchScore +
            0.04 * centeredWeakScore) *
        (1.0 - wearerConfidence * 0.65).clamp(0.0, 1.0).toDouble();

    if (wearerConfidence >= 0.26) {
      _snoreSource = 'wearer';
      _snoreSourceConfidence = wearerConfidence;
    } else if (externalConfidence >= 0.18) {
      _snoreSource = 'external';
      _snoreSourceConfidence = externalConfidence;
    } else {
      _snoreSource = 'unknown';
      _snoreSourceConfidence = math.max(wearerConfidence, externalConfidence);
    }
  }

  void _updateSnoreTimeline(SnoreState snore, DateTime now) {
    if (snore.backend == 'none') return;
    if (snore.isSnoring) {
      if (_activeSnoreStartedAt == null) {
        _activeSnoreStartedAt = now;
        _activeSnoreSource = 'unknown';
        _activeSnoreSourceConfidence = 0;
      }
      _mergeActiveSnoreSource(snore);
      return;
    }
    _closeActiveSnoreSegment(now);
  }

  void _mergeActiveSnoreSource(SnoreState snore) {
    if (snore.source == 'unknown') return;
    if (_activeSnoreSource == 'unknown' ||
        snore.sourceConfidence >= _activeSnoreSourceConfidence) {
      _activeSnoreSource = snore.source;
      _activeSnoreSourceConfidence = snore.sourceConfidence;
    }
  }

  void _closeActiveSnoreSegment(DateTime endedAt) {
    final startedAt = _activeSnoreStartedAt;
    if (startedAt == null) return;
    final source = _activeSnoreSource;
    final sourceConfidence = _activeSnoreSourceConfidence;
    _activeSnoreStartedAt = null;
    _activeSnoreSource = 'unknown';
    _activeSnoreSourceConfidence = 0;
    final duration = endedAt.difference(startedAt);
    if (duration.inMilliseconds < 250) return;
    _snoreTimeline.add(
      SnoreTimelineSegment(
        startedAt: startedAt,
        endedAt: endedAt,
        source: source,
        sourceConfidence: sourceConfidence,
      ),
    );
  }

  List<SnoreTimelineSegment> _snoreTimelineSnapshot() {
    final items = List<SnoreTimelineSegment>.of(_snoreTimeline);
    final startedAt = _activeSnoreStartedAt;
    if (startedAt != null) {
      items.add(
        SnoreTimelineSegment(
          startedAt: startedAt,
          endedAt: null,
          source: _activeSnoreSource,
          sourceConfidence: _activeSnoreSourceConfidence,
        ),
      );
    }
    return items;
  }

  double _elapsedSeconds() {
    final startedAt = _measurementStartedAt;
    if (startedAt == null) return _sampleNumber / samplingRate;
    return math.max(
      0.0,
      DateTime.now().difference(startedAt).inMicroseconds /
          Duration.microsecondsPerSecond,
    );
  }

  double _mg24LiveSeconds() {
    final now = DateTime.now();
    final startedAt = _mg24LiveStartedAt ??= now;
    return now.difference(startedAt).inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  String _timestamp() {
    return _fileTimestamp(DateTime.now());
  }

  String _fileTimestamp(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  String _clockLabel(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  Future<Directory> _csvDirectory({required bool create}) async {
    final documents = await getApplicationDocumentsDirectory();
    final dir =
        Directory('${documents.path}${Platform.pathSeparator}messungen');
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _sleepSessionsCsvFile({required bool create}) async {
    final dir = await _csvDirectory(create: create);
    return File('${dir.path}${Platform.pathSeparator}schlafzyklen.csv');
  }

  Future<File> _sleepHistoryJsonFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}sleep_sessions.json',
    );
  }

  Future<File> _correlationNightSelectionFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}sleep_correlation_selection.json',
    );
  }

  Future<File> _measurementSettingsFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}measurement_settings.json',
    );
  }

  Future<void> _loadMeasurementSettings() async {
    try {
      final file = await _measurementSettingsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      yamnetMeasurementEnabled =
          version >= 3 ? decoded['yamnet_measurement_enabled'] != false : true;
      measurementStartSignalEnabled =
          decoded['measurement_start_signal_enabled'] != false;
    } catch (_) {
      // Invalid optional settings fall back to the conservative defaults.
    }
  }

  Future<void> _saveMeasurementSettings() async {
    final file = await _measurementSettingsFile();
    await file.writeAsString(
      jsonEncode({
        'version': 3,
        'yamnet_measurement_enabled': yamnetMeasurementEnabled,
        'measurement_start_signal_enabled': measurementStartSignalEnabled,
      }),
      flush: true,
    );
  }

  Future<File> _activeMeasurementSessionFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}active_measurement.json',
    );
  }

  Future<File> _deferredBoardStopsFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}deferred_board_stops.json',
    );
  }

  Future<void> _loadDeferredBoardStops() async {
    try {
      final file = await _deferredBoardStopsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final roleNames = (decoded['roles'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet();
      final roles = Mg24SensorRole.values
          .where((role) => roleNames.contains(role.name))
          .toSet();
      final remoteIds = <Mg24SensorRole, String>{};
      final rawRemoteIds = decoded['remote_ids'];
      if (rawRemoteIds is Map<String, dynamic>) {
        for (final role in roles) {
          final value = rawRemoteIds[role.name];
          if (value is String && value.trim().isNotEmpty) {
            remoteIds[role] = value;
          }
        }
      }
      final sessionIds = <Mg24SensorRole, int>{};
      final rawSessionIds = decoded['session_ids'];
      if (rawSessionIds is Map<String, dynamic>) {
        for (final role in roles) {
          final value = rawSessionIds[role.name];
          if (value is num) sessionIds[role] = value.toInt() & 0xffff;
        }
      }
      // Version-1 entries cannot distinguish their old recording from a new
      // one on the same board. Drop those unsafe legacy requests instead of
      // allowing them to stop an unrelated future measurement.
      final scopedRoles = roles.where(sessionIds.containsKey).toSet();
      _deferredBoardStopRoles = Set.unmodifiable(scopedRoles);
      _deferredBoardStopRemoteIds = Map.unmodifiable({
        for (final entry in remoteIds.entries)
          if (scopedRoles.contains(entry.key)) entry.key: entry.value,
      });
      _deferredBoardStopSessionIds = Map.unmodifiable({
        for (final entry in sessionIds.entries)
          if (scopedRoles.contains(entry.key)) entry.key: entry.value,
      });
      if (scopedRoles.length != roles.length) await _saveDeferredBoardStops();
    } catch (_) {
      // A stale cleanup request must not prevent the app from opening.
    }
  }

  Future<void> _saveDeferredBoardStops() async {
    final file = await _deferredBoardStopsFile();
    if (_deferredBoardStopRoles.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(
      jsonEncode({
        'version': 2,
        'roles': _deferredBoardStopRoles.map((role) => role.name).toList(),
        'remote_ids': {
          for (final entry in _deferredBoardStopRemoteIds.entries)
            entry.key.name: entry.value,
        },
        'session_ids': {
          for (final entry in _deferredBoardStopSessionIds.entries)
            entry.key.name: entry.value,
        },
      }),
      flush: true,
    );
  }

  Future<void> _queueDeferredBoardStops(Set<Mg24SensorRole> roles) async {
    if (roles.isEmpty) return;
    final remoteIds = <Mg24SensorRole, String>{
      ..._deferredBoardStopRemoteIds,
    };
    final sessionIds = <Mg24SensorRole, int>{
      ..._deferredBoardStopSessionIds,
    };
    final knownIds = _knownMg24RemoteIds();
    for (final role in roles) {
      final remoteId = knownIds[role];
      if (remoteId != null && remoteId.trim().isNotEmpty) {
        remoteIds[role] = remoteId;
      }
      final sessionId = _activeBoardSessionId;
      if (sessionId != null) sessionIds[role] = sessionId & 0xffff;
    }
    _deferredBoardStopRoles = Set.unmodifiable({
      ..._deferredBoardStopRoles,
      ...roles,
    });
    _deferredBoardStopRemoteIds = Map.unmodifiable(remoteIds);
    _deferredBoardStopSessionIds = Map.unmodifiable(sessionIds);
    await _saveDeferredBoardStops();
  }

  Future<void> _clearDeferredBoardStops(Set<Mg24SensorRole> roles) async {
    if (roles.isEmpty || _deferredBoardStopRoles.isEmpty) return;
    final remaining = _deferredBoardStopRoles.difference(roles);
    _deferredBoardStopRoles = Set.unmodifiable(remaining);
    _deferredBoardStopRemoteIds = Map.unmodifiable({
      for (final entry in _deferredBoardStopRemoteIds.entries)
        if (remaining.contains(entry.key)) entry.key: entry.value,
    });
    _deferredBoardStopSessionIds = Map.unmodifiable({
      for (final entry in _deferredBoardStopSessionIds.entries)
        if (remaining.contains(entry.key)) entry.key: entry.value,
    });
    await _saveDeferredBoardStops();
  }

  Future<void> _applyDeferredBoardStops() async {
    if (_deferredBoardStopRoles.isEmpty || _deferredBoardStopInProgress) return;
    final client = _mg24Client;
    if (client == null) return;
    _deferredBoardStopInProgress = true;
    final pending = <Mg24SensorRole>{..._deferredBoardStopRoles};
    try {
      for (final role in List<Mg24SensorRole>.of(pending)) {
        final sensor = switch (role) {
          Mg24SensorRole.forehead => _mg24.forehead,
          Mg24SensorRole.belly => _mg24.belly,
        };
        if (!sensor.connected) continue;
        final targetSessionId = _deferredBoardStopSessionIds[role];
        final boardSessionId = sensor.sessionId;

        // A deferred stop belongs to one specific recording. If that session
        // is no longer active, the request is complete/stale and must never
        // stop a newer recording that happens to use the same physical board.
        if (targetSessionId != null) {
          final targetIsActive = sensor.recording == true &&
              boardSessionId == (targetSessionId & 0xffff);
          if (!targetIsActive) {
            pending.remove(role);
            continue;
          }
        } else if (sensor.recording != true) {
          // Legacy cleanup entries had no session id. They are safe to discard
          // once the board already reports that it is stopped.
          pending.remove(role);
          continue;
        }
        if (kDebugMode && targetSessionId != null) {
          try {
            await _debugBackupDeferredBoardArchive(
              client,
              role,
              targetSessionId,
            );
          } catch (error) {
            snapshot = snapshot.copyWith(
              status: '${role.label}-Archiv konnte vor dem Stopp nicht '
                  'gesichert werden: ${_friendlyError(error)}',
            );
            notifyListeners();
            continue;
          }
        }
        try {
          await client.stopBoardRecording(roles: {role});
          pending.remove(role);
        } catch (_) {
          // Keep the command until this role can acknowledge REC:STOP.
        }
      }
      _deferredBoardStopRoles = Set.unmodifiable(pending);
      _deferredBoardStopRemoteIds = Map.unmodifiable({
        for (final entry in _deferredBoardStopRemoteIds.entries)
          if (pending.contains(entry.key)) entry.key: entry.value,
      });
      _deferredBoardStopSessionIds = Map.unmodifiable({
        for (final entry in _deferredBoardStopSessionIds.entries)
          if (pending.contains(entry.key)) entry.key: entry.value,
      });
      await _saveDeferredBoardStops();
      if (pending.isEmpty) {
        snapshot = snapshot.copyWith(
          status: 'Vorgemerkter Board-Stopp wurde ausgefuehrt.',
        );
      } else {
        final labels = pending.map((role) => role.label).join(' + ');
        snapshot = snapshot.copyWith(
          status: '$labels muss zum automatischen Stopp noch verbunden werden.',
        );
      }
      notifyListeners();
    } finally {
      _deferredBoardStopInProgress = false;
    }
  }

  Future<void> _debugBackupDeferredBoardArchive(
    Mg24SensorClient client,
    Mg24SensorRole role,
    int sessionId,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final file = File(
      '${documents.path}${Platform.pathSeparator}'
      'debug_recovery_${role.name}_${sessionId & 0xffff}.json',
    );
    Map<String, Object?>? payload;
    if (await file.exists() && await file.length() > 256) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic> &&
            decoded['session_id'] == (sessionId & 0xffff) &&
            decoded['role'] == role.name) {
          payload = Map<String, Object?>.from(decoded);
          if (payload['event_complete'] == true) {
            // Keep high-rate summaries paused until the deferred REC:STOP has
            // been acknowledged. The control notification remains enabled.
            await client.setArchiveTransferMode(role, true);
            return;
          }
        }
      } catch (_) {
        payload = null;
      }
    }

    void showProgress(
      Mg24SensorRole progressRole,
      int received,
      int total,
    ) {
      if (progressRole != role) return;
      snapshot = snapshot.copyWith(
        status: '${role.label}-Archiv sichern: $received/$total',
      );
      notifyListeners();
    }

    await client.setArchiveTransferMode(role, true);
    try {
      if (payload == null) {
        final minutes = await client.downloadMinuteArchives(
          roles: {role},
          onProgress: showProgress,
          maximumDurationPerSensor: const Duration(minutes: 3),
        );
        final minuteArchive = minutes[role];
        if (minuteArchive == null ||
            minuteArchive.status.sessionId != (sessionId & 0xffff)) {
          throw StateError(
            '${role.label}: Minutenarchiv fehlt oder ist veraltet.',
          );
        }
        payload = <String, Object?>{
          'version': 1,
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'role': role.name,
          'session_id': sessionId & 0xffff,
          'event_complete': false,
          'minute_status': {
            'unix_start_minute': minuteArchive.status.unixStartMinute,
            'record_count': minuteArchive.status.recordCount,
            'capacity': minuteArchive.status.capacity,
            'recording': minuteArchive.status.recording,
          },
          'minutes': [
            for (final record in minuteArchive.records)
              {
                'minute_index': record.minuteIndex,
                'partial': record.partial,
                'heart_rate_bpm': record.heartRateBpm,
                'spo2_percent': record.spo2Percent,
                'respiration_rate_per_min': record.respirationRatePerMin,
                'snore_seconds': record.snoreSeconds,
                'snore_volume_percent': record.snoreVolumePercent,
                'temperature_c': record.temperatureC,
                'roll_deg': record.rollDeg,
                'pitch_deg': record.pitchDeg,
                'yaw_deg': record.yawDeg,
                'ppg_quality': record.ppgQuality,
                'respiration_quality': record.respirationQuality,
                'battery_percent': record.batteryPercent,
              },
          ],
          'event_status': null,
          'events': const <Object>[],
        };
        await file.writeAsString(jsonEncode(payload), flush: true);
        debugPrint('[MG24-RECOVERY] minute archive saved: ${file.path}');
      }

      final savedEvents = <Object?>[
        ...((payload['events'] as List<dynamic>?) ?? const <dynamic>[]),
      ];
      final events = await client.downloadEventArchives(
        roles: {role},
        onProgress: showProgress,
        startIndices: {role: savedEvents.length},
        onChunk: (chunkRole, firstRecord, records) async {
          if (chunkRole != role || firstRecord != savedEvents.length) {
            throw StateError(
              '${role.label}: Ereignisarchiv ist nicht fortlaufend.',
            );
          }
          savedEvents.addAll([
            for (final record in records)
              {
                'start_tick': record.startTick,
                'duration_ticks': record.durationTicks,
                'quality_percent': record.qualityPercent,
              },
          ]);
          payload!['events'] = savedEvents;
          await file.writeAsString(jsonEncode(payload), flush: true);
        },
        maximumDurationPerSensor: const Duration(minutes: 3),
      );
      final eventArchive = events[role];
      if (eventArchive == null ||
          eventArchive.status.sessionId != (sessionId & 0xffff)) {
        throw StateError(
          '${role.label}: Ereignisarchiv fehlt oder ist veraltet.',
        );
      }
      payload['saved_at'] = DateTime.now().toUtc().toIso8601String();
      payload['event_complete'] = true;
      payload['event_status'] = {
        'kind': eventArchive.status.kind.name,
        'unix_start_minute': eventArchive.status.unixStartMinute,
        'record_count': eventArchive.status.recordCount,
        'capacity': eventArchive.status.capacity,
        'recording': eventArchive.status.recording,
      };
      payload['events'] = savedEvents;
      await file.writeAsString(jsonEncode(payload), flush: true);
      debugPrint('[MG24-RECOVERY] complete archive saved: ${file.path}');
    } finally {
      try {
        await client.setArchiveTransferMode(role, false);
      } catch (_) {}
    }
  }

  Future<void> _persistActiveMeasurementSession({
    required bool recording,
  }) async {
    final startedAt = _sleepCycleStartedAt ?? _measurementStartedAt;
    if (startedAt == null || _mg24MeasurementRoles.isEmpty) return;
    final file = await _activeMeasurementSessionFile();
    final data = <String, Object?>{
      'version': 2,
      'recording': recording,
      'armed': _measurementArmed,
      'scheduled_start_at':
          _measurementScheduledStartAt?.toUtc().toIso8601String(),
      'cancel_pending': _scheduledMeasurementCancelPending,
      'pending_stop_roles':
          _pendingBoardStopRoles.map((role) => role.name).toList(),
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': _sleepCycleEndedAt?.toUtc().toIso8601String(),
      'session_id': _activeBoardSessionId,
      'roles': _mg24MeasurementRoles.map((role) => role.name).toList(),
      'remote_ids': {
        for (final entry in _persistedMg24RemoteIds.entries)
          entry.key.name: entry.value,
      },
      'evening_answers': _pendingEveningAnswers ?? const <String, int>{},
    };
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  Future<void> _clearActiveMeasurementSession() async {
    final file = await _activeMeasurementSessionFile();
    if (await file.exists()) await file.delete();
  }

  Future<void> _restoreActiveMeasurementSession() async {
    try {
      final file = await _activeMeasurementSessionFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final startedAtRaw = decoded['started_at'] as String?;
      final startedAt = DateTime.tryParse(startedAtRaw ?? '')?.toLocal();
      final roleNames = (decoded['roles'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet();
      final roles = Mg24SensorRole.values
          .where((role) => roleNames.contains(role.name))
          .toSet();
      if (startedAt == null || roles.isEmpty) return;
      final alreadySaved = sleepHistory.any(
        (record) =>
            record.metrics.startedAt.difference(startedAt).abs() <=
            const Duration(minutes: 1),
      );
      if (alreadySaved) {
        await _clearActiveMeasurementSession();
        return;
      }

      final remoteIds = <Mg24SensorRole, String>{};
      final rawRemoteIds = decoded['remote_ids'];
      if (rawRemoteIds is Map<String, dynamic>) {
        for (final role in roles) {
          final remoteId = rawRemoteIds[role.name];
          if (remoteId is String && remoteId.trim().isNotEmpty) {
            remoteIds[role] = remoteId;
          }
        }
      }
      final answers = <String, int>{};
      final rawAnswers = decoded['evening_answers'];
      if (rawAnswers is Map<String, dynamic>) {
        for (final entry in rawAnswers.entries) {
          final value = entry.value;
          if (value is num) answers[entry.key] = value.round();
        }
      }

      final recording = decoded['recording'] != false;
      final armed = decoded['armed'] == true;
      final scheduledStartAt = DateTime.tryParse(
        decoded['scheduled_start_at'] as String? ?? '',
      )?.toLocal();
      final cancelPending = decoded['cancel_pending'] == true;
      final pendingStopRoleNames =
          (decoded['pending_stop_roles'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toSet();
      final pendingStopRoles = Mg24SensorRole.values
          .where((role) => pendingStopRoleNames.contains(role.name))
          .toSet();
      final endedAtRaw = decoded['ended_at'] as String?;
      _sleepCycleStartedAt = startedAt;
      _sleepCycleEndedAt =
          recording ? null : DateTime.tryParse(endedAtRaw ?? '')?.toLocal();
      _pendingEveningAnswers = answers;
      _mg24MeasurementRoles = Set.unmodifiable(roles);
      _persistedMg24RemoteIds = Map.unmodifiable(remoteIds);
      _activeBoardSessionId = (decoded['session_id'] as num?)?.toInt();
      useMg24Data = true;
      usePositionData = true;

      final roleText = roles.map((role) => role.label).join(' + ');
      if (armed) {
        final effectiveStartAt = scheduledStartAt ?? startedAt;
        _measurementScheduledStartAt = effectiveStartAt;
        _measurementStartedAt = effectiveStartAt;
        _measurementArmed = true;
        _scheduledMeasurementCancelPending = cancelPending;
        _pendingBoardStopRoles = Set.unmodifiable(
          pendingStopRoles.isEmpty && cancelPending ? roles : pendingStopRoles,
        );
        if (cancelPending) {
          final pendingText =
              _pendingBoardStopRoles.map((role) => role.label).join(' + ');
          snapshot = snapshot.copyWith(
            running: false,
            measurementStartedAt: effectiveStartAt,
            status: 'Abbruch vorgemerkt. $pendingText wird bei der naechsten '
                'Verbindung automatisch gestoppt.',
          );
        } else if (!DateTime.now().isBefore(effectiveStartAt)) {
          _activateRestoredArmedMeasurement();
        } else {
          snapshot = snapshot.copyWith(
            running: false,
            measurementStartedAt: effectiveStartAt,
            status: 'Messung auf $roleText vorbereitet. Sie startet auch '
                'ohne Bluetooth-Verbindung automatisch.',
          );
          _scheduleRestoredArmedMeasurementStart(effectiveStartAt);
        }
        return;
      }
      if (recording) {
        _measurementStartedAt = startedAt;
        snapshot = snapshot.copyWith(
          running: true,
          measurementStartedAt: startedAt,
          status:
              'Messung laeuft auf $roleText. Zum Beenden diese Sensoren wieder verbinden.',
        );
        unawaited(_resumePhoneSnoreCaptureForRestoredMeasurement());
      } else {
        _measurementStartedAt = null;
        snapshot = snapshot.copyWith(
          running: false,
          clearMeasurementStartedAt: true,
          status:
              'Gestoppte Board-Messung wartet noch auf die Journal-Uebernahme.',
        );
      }
    } catch (_) {
      // A malformed recovery file must never prevent the app from starting.
    }
  }

  Future<void> _resumePhoneSnoreCaptureForRestoredMeasurement() async {
    if (!running || !snoreEnabled || !yamnetMeasurementEnabled) return;
    final microphonePermissionGranted = await _ensureMicrophonePermission();
    if (!running) return;

    _measurementForegroundOwner = true;
    _measurementForegroundUsesMicrophone = microphonePermissionGranted;
    _measurementForegroundUsesConnectedDevice = useMg24Data;
    await _refreshForegroundService();
    if (!microphonePermissionGranted) {
      snapshot = snapshot.copyWith(
        status: 'Messung laeuft weiter, YAMNet ist ohne Mikrofonzugriff aus.',
      );
      notifyListeners();
      return;
    }

    await _startSnoreDetector();
    if (!running || _snoreDetector == null) return;
    _measurementYamnetCaptureActive = true;
    _measurementYamnetWasRecorded = true;
    notifyListeners();
  }

  void _scheduleRestoredArmedMeasurementStart(DateTime scheduledAt) {
    _restoredArmedStartTimer?.cancel();
    final delay = scheduledAt.difference(DateTime.now());
    if (delay <= Duration.zero) {
      _activateRestoredArmedMeasurement();
      return;
    }
    _restoredArmedStartTimer = Timer(delay, _activateRestoredArmedMeasurement);
  }

  void _activateRestoredArmedMeasurement() {
    if (!_measurementArmed || _scheduledMeasurementCancelPending) return;
    _restoredArmedStartTimer?.cancel();
    _restoredArmedStartTimer = null;
    final startedAt = _measurementScheduledStartAt ?? _measurementStartedAt;
    _measurementArmed = false;
    _measurementScheduledStartAt = null;
    _measurementStartedAt = startedAt;
    snapshot = snapshot.copyWith(
      running: true,
      measurementStartedAt: startedAt,
      status: 'Messung laeuft auf den Sensoren. Bluetooth darf getrennt sein.',
    );
    unawaited(_persistActiveMeasurementSession(recording: true));
    notifyListeners();
  }

  Future<File> _customSleepQuestionsFile() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(
      '${documents.path}${Platform.pathSeparator}sleep_custom_questions.json',
    );
  }

  Future<List<SleepQuestion>> _loadCustomSleepQuestions() async {
    try {
      final file = await _customSleepQuestionsFile();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return decoded
          .map((entry) => SleepQuestion.fromJson(entry as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SleepSessionRecord>> _loadSleepHistory() async {
    try {
      final file = await _sleepHistoryJsonFile();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final records = decoded
          .map(
            (entry) =>
                SleepSessionRecord.fromJson(entry as Map<String, dynamic>),
          )
          .toList(growable: false);
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    } catch (_) {
      return const [];
    }
  }

  List<SleepSessionRecord> _deduplicateSleepHistory(
    List<SleepSessionRecord> records,
  ) {
    final unique = <SleepSessionRecord>[];
    for (final record in records) {
      final duplicate = unique.any((existing) {
        final samePath = record.dataCsvPath != null &&
            record.dataCsvPath!.isNotEmpty &&
            record.dataCsvPath == existing.dataCsvPath;
        final sameStart = record.metrics.startedAt
                .difference(existing.metrics.startedAt)
                .abs() <
            const Duration(minutes: 1);
        final sameEnd =
            record.metrics.endedAt.difference(existing.metrics.endedAt).abs() <
                const Duration(minutes: 2);
        return samePath || (sameStart && sameEnd);
      });
      if (!duplicate) unique.add(record);
    }
    return List.unmodifiable(unique);
  }

  Future<({List<SleepSessionRecord> records, bool changed})>
      _repairBoardArchiveTimeBounds(List<SleepSessionRecord> records) async {
    var changed = false;
    final repaired = <SleepSessionRecord>[];
    for (final record in records) {
      final path = record.dataCsvPath;
      if (path == null || !_fileName(path).startsWith('mg24_minuten_')) {
        repaired.add(record);
        continue;
      }

      try {
        final file = File(path);
        if (!await file.exists()) {
          repaired.add(record);
          continue;
        }
        final lines = await file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.trim().isNotEmpty)
            .toList();
        if (lines.length < 2) {
          repaired.add(record);
          continue;
        }
        final header = _splitCsvLine(lines.first);
        final timeIndex = header.indexOf('Uhrzeit');
        if (timeIndex < 0) {
          repaired.add(record);
          continue;
        }
        DateTime? timestampAt(int lineIndex) {
          final values = _splitCsvLine(lines[lineIndex]);
          if (timeIndex >= values.length) return null;
          return DateTime.tryParse(values[timeIndex].trim());
        }

        final archiveStartedAt = timestampAt(1);
        final lastMinuteAt = timestampAt(lines.length - 1);
        if (archiveStartedAt == null || lastMinuteAt == null) {
          repaired.add(record);
          continue;
        }
        final archiveEndedAt = lastMinuteAt.add(const Duration(minutes: 1));
        final startMismatch =
            record.metrics.startedAt.difference(archiveStartedAt).abs() >
                const Duration(minutes: 2);
        final endMismatch =
            record.metrics.endedAt.difference(archiveEndedAt).abs() >
                const Duration(minutes: 2);
        if (!startMismatch && !endMismatch) {
          repaired.add(record);
          continue;
        }

        final metrics = SleepMeasurementSummary(
          startedAt: archiveStartedAt,
          endedAt: archiveEndedAt,
          durationSeconds: math.max(
            1.0,
            archiveEndedAt.difference(archiveStartedAt).inMilliseconds / 1000.0,
          ),
          meanHeartRateBpm: record.metrics.meanHeartRateBpm,
          meanBreathingRatePerMin: record.metrics.meanBreathingRatePerMin,
          meanEarTemperatureC: record.metrics.meanEarTemperatureC,
          meanRelativeAngleDeg: record.metrics.meanRelativeAngleDeg,
          snoreTimeFraction: record.metrics.snoreTimeFraction,
          relativeAngleSnore: record.metrics.relativeAngleSnore,
          poseSnore: record.metrics.poseSnore,
        );
        repaired.add(
          SleepSessionRecord(
            id: record.id,
            createdAt: record.createdAt,
            metrics: metrics,
            answers: record.answers,
            score: computeSleepScore(record.answers, metrics),
            tips: record.tips,
            dataCsvPath: record.dataCsvPath,
          ),
        );
        changed = true;
      } catch (_) {
        repaired.add(record);
      }
    }
    return (
      records: List<SleepSessionRecord>.unmodifiable(repaired),
      changed: changed,
    );
  }

  Future<void> _loadCorrelationNightSelection() async {
    final available = sleepHistory.map((record) => record.id).toSet();
    var selected = <String>{};
    var known = <String>{};
    try {
      final file = await _correlationNightSelectionFile();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          selected = (decoded['selected_record_ids'] as List<dynamic>? ??
                  const <dynamic>[])
              .whereType<String>()
              .toSet();
          known = (decoded['known_record_ids'] as List<dynamic>? ??
                  const <dynamic>[])
              .whereType<String>()
              .toSet();
        }
      } else {
        selected.addAll(available);
      }
    } catch (_) {
      selected.addAll(available);
    }
    selected
      ..removeWhere((id) => !available.contains(id))
      ..addAll(available.difference(known));
    _selectedCorrelationRecordIds = Set<String>.unmodifiable(selected);
    _knownCorrelationRecordIds = Set<String>.unmodifiable(available);
    await _saveCorrelationNightSelection();
  }

  Future<void> _syncCorrelationNightSelectionWithHistory() async {
    final available = sleepHistory.map((record) => record.id).toSet();
    final selected = _selectedCorrelationRecordIds
        .where(available.contains)
        .toSet()
      ..addAll(available.difference(_knownCorrelationRecordIds));
    _selectedCorrelationRecordIds = Set<String>.unmodifiable(selected);
    _knownCorrelationRecordIds = Set<String>.unmodifiable(available);
    await _saveCorrelationNightSelection();
  }

  Future<void> _saveCorrelationNightSelection() async {
    final file = await _correlationNightSelectionFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert({
        'version': 1,
        'selected_record_ids': _selectedCorrelationRecordIds.toList()..sort(),
        'known_record_ids': _knownCorrelationRecordIds.toList()..sort(),
      }),
      flush: true,
    );
  }

  Future<void> _saveCustomSleepQuestions() async {
    final file = await _customSleepQuestionsFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(customSleepQuestions.map((q) => q.toJson()).toList()),
    );
  }

  Future<void> _saveSleepHistory() async {
    final file = await _sleepHistoryJsonFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(sleepHistory.map((record) => record.toJson()).toList()),
    );
  }

  Future<void> _appendSleepSessionCsv(SleepSessionRecord record) async {
    final file = await _sleepSessionsCsvFile(create: true);
    if (!await file.exists()) {
      await file.writeAsString('${sleepSessionCsvColumns.join(',')}\n');
    }
    final sink = file.openWrite(mode: FileMode.append);
    sink.writeln(sleepSessionToCsvRow(record, sleepQuestions).join(','));
    await sink.flush();
    await sink.close();
  }

  Future<void> _rewriteSleepSessionsCsv() async {
    final file = await _sleepSessionsCsvFile(create: true);
    final buffer = StringBuffer('${sleepSessionCsvColumns.join(',')}\n');
    for (final record in sleepHistory) {
      buffer.writeln(sleepSessionToCsvRow(record, sleepQuestions).join(','));
    }
    await file.writeAsString(buffer.toString(), flush: true);
  }

  Future<int> _deleteSleepSessionDataFiles(
    SleepSessionRecord record,
    List<SleepSessionRecord> remaining,
  ) async {
    final sharesMeasurement = remaining.any(
      (entry) =>
          entry.metrics.startedAt.difference(record.metrics.startedAt).abs() <=
          const Duration(minutes: 5),
    );
    if (sharesMeasurement) return 0;

    final dir = await _csvDirectory(create: false);
    if (!await dir.exists()) return 0;
    final normalizedDir = dir.path.replaceAll('\\', '/').toLowerCase();
    final protectedPaths = <String>{
      for (final entry in remaining)
        if (entry.dataCsvPath case final path?)
          path.replaceAll('\\', '/').toLowerCase(),
      if (measurementActive)
        if (_csvFile?.path case final path?)
          path.replaceAll('\\', '/').toLowerCase(),
      if (measurementActive)
        if (snapshot.csvPath case final path?)
          path.replaceAll('\\', '/').toLowerCase(),
    };
    final explicitPath =
        record.dataCsvPath?.replaceAll('\\', '/').toLowerCase();
    final candidates = await dir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.csv'))
        .cast<File>()
        .toList();
    var deleted = 0;
    for (final file in candidates) {
      final normalizedPath = file.path.replaceAll('\\', '/').toLowerCase();
      if (!normalizedPath.startsWith('$normalizedDir/')) continue;
      if (protectedPaths.contains(normalizedPath)) continue;

      final isExplicit = explicitPath == normalizedPath;
      final timestamp = _fileTimestampFromName(file.path, 'mg24_minuten_') ??
          _fileTimestampFromName(file.path, 'mg24_events_') ??
          _fileTimestampFromName(file.path, 'messung_');
      final isMeasurementFamily = timestamp != null &&
          timestamp.difference(record.metrics.startedAt).abs() <=
              const Duration(minutes: 5);
      if (!isExplicit && !isMeasurementFamily) continue;
      try {
        await file.delete();
        deleted++;
      } catch (_) {
        // The journal entry remains deleted even if Android holds a CSV open.
      }
    }
    return deleted;
  }

  void _refreshSleepAnalysis() {
    latestSleepSession = sleepHistory.isEmpty ? null : sleepHistory.first;
    sleepSummary = summarizeSleepHistory(sleepHistory);
    sleepCorrelations = computeSleepCorrelations(sleepHistory, sleepQuestions);
    sleepQuestionPhysiologyCorrelations =
        computeSleepQuestionPhysiologyCorrelations(
      sleepHistory,
      sleepQuestions,
    );
    personalizedSleepTips =
        buildSleepTips(latestSleepSession, sleepCorrelations);
  }

  Future<List<SleepSessionSeriesPoint>> loadSleepSessionSeries(
    SleepSessionRecord record,
  ) async {
    final file = await _sleepSessionSeriesFile(record);
    if (file == null || !await file.exists()) return const [];
    final points = await _readSleepSessionSeriesFile(record, file);
    if (points.isEmpty) return const [];
    var aggregated = _aggregateSleepSessionSeriesByMinute(points);
    final snoreFile = await _sleepSessionSnoreDetailsFile(
      record,
      excludePath: file.path,
    );
    if (snoreFile != null) {
      final snorePoints = await _readSleepSessionSeriesFile(record, snoreFile);
      if (snorePoints.isNotEmpty) {
        final snoreAggregated =
            _aggregateSleepSessionSeriesByMinute(snorePoints);
        aggregated = _mergeSleepSnoreDetails(aggregated, snoreAggregated);
      }
    }
    final eventFile = await _sleepSessionEventDetailsFile(record);
    if (eventFile != null) {
      final eventSnorePoints =
          await _readSleepSessionEventSnoreSeriesFile(record, eventFile);
      if (eventSnorePoints.isNotEmpty) {
        final eventAggregated =
            _aggregateSleepSessionSeriesByMinute(eventSnorePoints);
        aggregated = _mergeSleepSnoreSources(aggregated, eventAggregated);
      }
    }
    aggregated = _preferYamnetSnoreSeries(aggregated);
    final cleaned = _sanitizeSleepSnoreSeries(
      record,
      _cleanSleepSessionSeries(
        aggregated,
        fillSmallGaps: true,
      ),
    );
    return _smoothSleepSnoreVolumes(cleaned);
  }

  List<SleepSessionSeriesPoint> _preferYamnetSnoreSeries(
    List<SleepSessionSeriesPoint> points,
  ) {
    final hasYamnet = points.any(
      (point) =>
          point.yamnetSnoreSeconds != null ||
          point.yamnetSnoreWindowCount != null,
    );
    if (!hasYamnet) return points;

    return [
      for (final point in points)
        () {
          final yamnetSeconds = point.yamnetSnoreSeconds;
          final yamnetCount = point.yamnetSnoreWindowCount;
          if (yamnetSeconds == null && yamnetCount == null) return point;

          final hasYamnetSnore = (yamnetSeconds ?? 0) > 0;
          final boardDetected = (point.snoreSeconds ?? 0) > 0 ||
              (point.snoreWindowCount ?? 0) > 0;
          final source = !hasYamnetSnore
              ? null
              : boardDetected
                  ? point.snoreSource ?? 'unknown'
                  : 'external';
          return point.copyWith(
            snoreSeconds: hasYamnetSnore ? 60.0 : 0.0,
            snoreWindowCount: (yamnetCount ?? 0).clamp(0.0, 60.0).toDouble(),
            snoreSource: source,
            clearSnoreSource: source == null,
            clearSnoreVolumePercent: !boardDetected,
          );
        }(),
    ];
  }

  List<SleepSessionSeriesPoint> _sanitizeSleepSnoreSeries(
    SleepSessionRecord record,
    List<SleepSessionSeriesPoint> points,
  ) {
    if (points.isEmpty) return points;
    final clamped = [
      for (final point in points)
        () {
          final seconds = point.snoreSeconds;
          if (seconds == null || !seconds.isFinite) return point;
          final limited = seconds > 0 ? 60.0 : 0.0;
          return limited == seconds
              ? point
              : point.copyWith(snoreSeconds: limited);
        }(),
    ];

    var snoreSeconds = 0.0;
    var snoreRows = 0;
    var nearlyFullRows = 0;
    var rowsWithSnoreValue = 0;
    var hasSnoreDetailEvidence = false;
    for (final point in clamped) {
      final seconds = point.snoreSeconds;
      if (point.snoreVolumePercent != null ||
          (point.snoreSource != null && point.snoreSource!.isNotEmpty)) {
        hasSnoreDetailEvidence = true;
      }
      if (seconds == null || !seconds.isFinite) continue;
      rowsWithSnoreValue++;
      snoreSeconds += seconds;
      if (seconds > 0) snoreRows++;
      if (seconds >= 55.0) nearlyFullRows++;
    }
    if (rowsWithSnoreValue == 0 || hasSnoreDetailEvidence) return clamped;

    final durationSeconds = _seriesObservedDurationSeconds(record, clamped);
    final rowCoverage = snoreRows / rowsWithSnoreValue;
    final fullRowCoverage = nearlyFullRows / rowsWithSnoreValue;
    final durationCoverage = durationSeconds <= 0
        ? 0.0
        : (snoreSeconds / durationSeconds).clamp(0.0, 2.0).toDouble();
    final looksLikeStuckSnoreFlag = rowsWithSnoreValue >= 2 &&
        rowCoverage >= 0.85 &&
        fullRowCoverage >= 0.65 &&
        durationCoverage >= 0.90;
    if (!looksLikeStuckSnoreFlag) return clamped;

    return [
      for (final point in clamped)
        point.copyWith(
          snoreSeconds: 0,
          clearSnoreVolumePercent: true,
          clearSnoreSource: true,
        ),
    ];
  }

  double _seriesObservedDurationSeconds(
    SleepSessionRecord record,
    List<SleepSessionSeriesPoint> points,
  ) {
    final metricDuration = record.metrics.durationSeconds;
    if (metricDuration.isFinite && metricDuration > 0) return metricDuration;
    if (points.length < 2) return 60.0;
    final first = points.first.time;
    final last = points.last.time;
    final spanSeconds = last.difference(first).inSeconds.toDouble();
    return math.max(60.0, spanSeconds + 60.0);
  }

  List<SleepSessionSeriesPoint> _smoothSleepSnoreVolumes(
    List<SleepSessionSeriesPoint> points,
  ) {
    if (points.length < 2) return points;
    return [
      for (var i = 0; i < points.length; i++)
        () {
          final point = points[i];
          final value = point.snoreVolumePercent;
          if ((point.snoreSeconds ?? 0) <= 0 || value == null) return point;
          var weightedSum = value * 2.0;
          var weightSum = 2.0;
          for (final neighborIndex in [i - 1, i + 1]) {
            if (neighborIndex < 0 || neighborIndex >= points.length) continue;
            final neighbor = points[neighborIndex];
            final neighborValue = neighbor.snoreVolumePercent;
            final minuteDistance =
                neighbor.time.difference(point.time).inSeconds.abs();
            if ((neighbor.snoreSeconds ?? 0) <= 0 ||
                neighborValue == null ||
                minuteDistance > 90) {
              continue;
            }
            weightedSum += neighborValue;
            weightSum += 1.0;
          }
          return point.copyWith(
            snoreVolumePercent: weightedSum / weightSum,
          );
        }(),
    ];
  }

  Future<List<SleepSessionSeriesPoint>> _readSleepSessionSeriesFile(
    SleepSessionRecord record,
    File file,
  ) async {
    final lines = await file.readAsLines();
    if (lines.length < 2) return const [];
    final header = _splitCsvLine(lines.first);
    final index = <String, int>{
      for (var i = 0; i < header.length; i++) header[i]: i,
    };
    final points = <SleepSessionSeriesPoint>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final values = _splitCsvLine(line);
      final point = _seriesPointFromCsv(record, index, values);
      if (point != null) points.add(point);
    }
    points.sort((a, b) => a.time.compareTo(b.time));
    return points;
  }

  Future<List<SleepSessionSeriesPoint>> _readSleepSessionEventSnoreSeriesFile(
    SleepSessionRecord record,
    File file,
  ) async {
    final lines = await file.readAsLines();
    if (lines.length < 2) return const [];
    final header = _splitCsvLine(lines.first);
    final index = <String, int>{
      for (var i = 0; i < header.length; i++) header[i]: i,
    };
    final events = <({
      String type,
      String detector,
      DateTime time,
      Mg24EventRecord record,
    })>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final values = _splitCsvLine(line);
      final type = _csvString(index, values, 'Event_Typ');
      if (type != 'Schnarchfenster' && type != 'Atemzyklus') continue;
      final detector = _csvString(index, values, 'Detektor') ?? 'MG24';
      final time = _csvDateTime(index, values, record);
      final startSeconds = _csvDouble(index, values, 'Start_s');
      final duration = _csvDouble(index, values, 'Dauer_s');
      if (time == null ||
          startSeconds == null ||
          !startSeconds.isFinite ||
          startSeconds < 0 ||
          duration == null ||
          !duration.isFinite ||
          duration <= 0) {
        continue;
      }
      events.add((
        type: type!,
        detector: detector,
        time: time,
        record: Mg24EventRecord(
          startTick: (startSeconds / Mg24EventRecord.tickSeconds)
              .round()
              .clamp(0, 0xFFFFFFFF),
          durationTicks:
              (duration / Mg24EventRecord.tickSeconds).round().clamp(1, 255),
          qualityPercent: (_csvDouble(index, values, 'Qualitaet_Prozent') ?? 0)
              .clamp(0.0, 100.0),
        ),
      ));
    }
    final breaths = [
      for (final event in events)
        if (event.type == 'Atemzyklus') event.record,
    ]..sort((a, b) => a.startTick.compareTo(b.startTick));
    final boardSnores = [
      for (final event in events)
        if (event.type == 'Schnarchfenster' &&
            event.detector.toUpperCase() != 'YAMNET')
          event.record,
    ]..sort((a, b) => a.startTick.compareTo(b.startTick));
    final yamnetSnores = [
      for (final event in events)
        if (event.type == 'Schnarchfenster' &&
            event.detector.toUpperCase() == 'YAMNET')
          event.record,
    ]..sort((a, b) => a.startTick.compareTo(b.startTick));
    final sourceBySnore =
        Map<Mg24EventRecord, _Mg24OfflineSnoreSource>.identity()
          ..addAll(_classifyOfflineSnoreSources(boardSnores, breaths))
          ..addAll(
            _classifyOfflineSnoreSources(
              yamnetSnores,
              breaths,
              snoreBoundaryUncertaintyS: yamnetBoundaryUncertaintySeconds,
            ),
          );
    final points = <SleepSessionSeriesPoint>[];
    for (final event in events) {
      if (event.type != 'Schnarchfenster') continue;
      final source = sourceBySnore[event.record] ??
          const _Mg24OfflineSnoreSource(
            source: 'unknown',
            confidence: 0,
            overlapRatio: 0,
          );
      points.add(
        SleepSessionSeriesPoint(
          time: event.time,
          minute: event.time.difference(record.metrics.startedAt).inMinutes,
          snoreSeconds:
              event.record.durationSeconds.clamp(0.0, 60.0).toDouble(),
          snoreWindowCount: 1.0,
          snoreSource: _normalizeSnoreSource(source.source),
        ),
      );
    }
    points.sort((a, b) => a.time.compareTo(b.time));
    return points;
  }

  List<SleepSessionSeriesPoint> _cleanSleepSessionSeries(
    List<SleepSessionSeriesPoint> points, {
    bool fillSmallGaps = false,
  }) {
    if (points.isEmpty) return points;
    final heartRate = _cleanSleepMetric(
      points,
      valueFor: (point) => point.heartRateBpm,
      qualityFor: (point) => point.ppgQualityPercent,
      minValue: 35,
      maxValue: 125,
      minQualityPercent: 22,
      outlierThreshold: 14,
      motionSensitive: true,
      maxFillGapMinutes: fillSmallGaps ? 5.0 : 0.0,
      medianWindow: fillSmallGaps ? 5 : 1,
      smoothingWindow: fillSmallGaps ? 7 : 1,
    );
    final breathingRate = _cleanSleepMetric(
      points,
      valueFor: (point) => point.breathingRatePerMin,
      qualityFor: (point) => point.breathingQualityPercent,
      minValue: 4,
      maxValue: 36,
      minQualityPercent: 18,
      outlierThreshold: 5,
      motionSensitive: true,
      maxFillGapMinutes: fillSmallGaps ? 5.0 : 0.0,
      medianWindow: fillSmallGaps ? 5 : 1,
      smoothingWindow: fillSmallGaps ? 7 : 1,
    );
    return [
      for (var i = 0; i < points.length; i++)
        points[i].copyWith(
          heartRateBpm: heartRate[i],
          clearHeartRateBpm: heartRate[i] == null,
          breathingRatePerMin: breathingRate[i],
          clearBreathingRatePerMin: breathingRate[i] == null,
        ),
    ];
  }

  List<double?> _cleanSleepMetric(
    List<SleepSessionSeriesPoint> points, {
    required double? Function(SleepSessionSeriesPoint point) valueFor,
    required double? Function(SleepSessionSeriesPoint point) qualityFor,
    required double minValue,
    required double maxValue,
    required double minQualityPercent,
    required double outlierThreshold,
    required bool motionSensitive,
    required double maxFillGapMinutes,
    required int medianWindow,
    required int smoothingWindow,
  }) {
    final values = <double?>[
      for (var i = 0; i < points.length; i++)
        _isSleepMetricUsable(
          points,
          i,
          valueFor: valueFor,
          qualityFor: qualityFor,
          minValue: minValue,
          maxValue: maxValue,
          minQualityPercent: minQualityPercent,
          motionSensitive: motionSensitive,
        )
            ? valueFor(points[i])
            : null,
    ];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) continue;
      final allValues = [
        for (final candidate in values)
          if (candidate != null && candidate.isFinite) candidate,
      ];
      if (allValues.length >= 5) {
        final globalMedian = _medianValue(allValues);
        final globalMad = _medianValue([
          for (final candidate in allValues) (candidate - globalMedian).abs(),
        ]);
        final globalLimit =
            math.max(outlierThreshold, 4.5 * 1.4826 * globalMad);
        if ((value - globalMedian).abs() > globalLimit) {
          values[i] = null;
          continue;
        }
      }
      final neighbors = <double>[];
      final start = math.max(0, i - 3);
      final end = math.min(values.length - 1, i + 3);
      for (var j = start; j <= end; j++) {
        if (j == i) continue;
        final neighbor = values[j];
        if (neighbor != null && neighbor.isFinite) {
          neighbors.add(neighbor);
        }
      }
      if (neighbors.length < 2) continue;
      final localMedian = _medianValue(neighbors);
      final deviations = [
        for (final neighbor in neighbors) (neighbor - localMedian).abs(),
      ];
      final mad = _medianValue(deviations);
      final robustLimit = math.max(outlierThreshold, 4.0 * 1.4826 * mad);
      if ((value - localMedian).abs() > robustLimit) {
        values[i] = null;
      }
    }
    final filled = _fillShortSleepMetricGaps(
      points,
      values,
      maxMissingMinutes: maxFillGapMinutes,
    );
    final medianFiltered = _medianFilterSleepMetricValues(
      filled,
      windowSize: medianWindow,
    );
    return _smoothSleepMetricValues(
      medianFiltered,
      windowSize: smoothingWindow,
    );
  }

  List<double?> _medianFilterSleepMetricValues(
    List<double?> values, {
    required int windowSize,
  }) {
    if (windowSize <= 1 || values.length < 3) return values;
    final radius = math.max(1, windowSize ~/ 2);
    return [
      for (var i = 0; i < values.length; i++)
        () {
          final value = values[i];
          if (value == null) return null;
          final neighbors = <double>[];
          for (var j = math.max(0, i - radius);
              j <= math.min(values.length - 1, i + radius);
              j++) {
            final candidate = values[j];
            if (candidate != null && candidate.isFinite) {
              neighbors.add(candidate);
            }
          }
          return neighbors.length < 3 ? value : _medianValue(neighbors);
        }(),
    ];
  }

  List<double?> _fillShortSleepMetricGaps(
    List<SleepSessionSeriesPoint> points,
    List<double?> values, {
    required double maxMissingMinutes,
  }) {
    if (maxMissingMinutes <= 0 || values.length < 3) return values;
    final result = List<double?>.of(values);
    var index = 0;
    while (index < result.length) {
      if (result[index] != null) {
        index++;
        continue;
      }

      final gapStart = index;
      while (index < result.length && result[index] == null) {
        index++;
      }
      final gapEnd = index - 1;
      final beforeIndex = gapStart - 1;
      final afterIndex = index;
      if (beforeIndex < 0 || afterIndex >= result.length) continue;

      final before = result[beforeIndex];
      final after = result[afterIndex];
      if (before == null || after == null) continue;

      final missingMinutes = math.max(
        1.0,
        points[gapEnd].time.difference(points[gapStart].time).inSeconds / 60.0 +
            1.0,
      );
      if (missingMinutes > maxMissingMinutes) continue;

      final totalSteps = afterIndex - beforeIndex;
      for (var fillIndex = gapStart; fillIndex <= gapEnd; fillIndex++) {
        final fraction = (fillIndex - beforeIndex) / totalSteps;
        result[fillIndex] = before + (after - before) * fraction;
      }
    }
    return result;
  }

  List<double?> _smoothSleepMetricValues(
    List<double?> values, {
    required int windowSize,
  }) {
    if (windowSize <= 1 || values.length < 3) return values;
    final radius = math.max(1, windowSize ~/ 2);
    return [
      for (var i = 0; i < values.length; i++)
        () {
          final value = values[i];
          if (value == null) return null;
          var sum = 0.0;
          var weightSum = 0.0;
          for (var j = math.max(0, i - radius);
              j <= math.min(values.length - 1, i + radius);
              j++) {
            final candidate = values[j];
            if (candidate == null) continue;
            final distance = (j - i).abs();
            final weight = (radius + 1 - distance).toDouble();
            sum += candidate * weight;
            weightSum += weight;
          }
          return weightSum <= 0 ? value : sum / weightSum;
        }(),
    ];
  }

  List<SleepSessionSeriesPoint> _aggregateSleepSessionSeriesByMinute(
    List<SleepSessionSeriesPoint> points,
  ) {
    if (points.length < 2) return points;
    final buckets = <DateTime, List<SleepSessionSeriesPoint>>{};
    for (final point in points) {
      final key = DateTime(
        point.time.year,
        point.time.month,
        point.time.day,
        point.time.hour,
        point.time.minute,
      );
      buckets.putIfAbsent(key, () => []).add(point);
    }
    return [
      for (final entry in buckets.entries)
        _aggregateSleepSessionMinute(entry.key, entry.value),
    ]..sort((a, b) => a.time.compareTo(b.time));
  }

  SleepSessionSeriesPoint _aggregateSleepSessionMinute(
    DateTime minuteTime,
    List<SleepSessionSeriesPoint> points,
  ) {
    points.sort((a, b) => a.time.compareTo(b.time));
    final first = points.first;
    final snorePoints = points
        .where((point) => (point.snoreSeconds ?? 0) > 0)
        .toList(growable: false);
    final snoreSeconds = snorePhaseSecondsForMinute(
      points.map((point) => point.snoreSeconds),
    );
    final snoreWindowCounts = points
        .map((point) => point.snoreWindowCount)
        .whereType<double>()
        .toList(growable: false);
    final yamnetSnoreSeconds = points
        .map((point) => point.yamnetSnoreSeconds)
        .whereType<double>()
        .toList(growable: false);
    final yamnetSnoreWindowCounts = points
        .map((point) => point.yamnetSnoreWindowCount)
        .whereType<double>()
        .toList(growable: false);
    return SleepSessionSeriesPoint(
      time: minuteTime,
      minute: first.minute,
      heartRateBpm: _robustMeanSeriesValue(
        points.map((point) => point.heartRateBpm),
        rejectDistance: 12,
      ),
      breathingRatePerMin: _robustMeanSeriesValue(
        points.map((point) => point.breathingRatePerMin),
        rejectDistance: 4,
      ),
      snoreSeconds: snoreSeconds,
      snoreWindowCount: snoreWindowCounts.isEmpty
          ? null
          : snoreWindowCounts.fold<double>(
              0.0,
              (sum, count) => sum + count,
            ),
      yamnetSnoreSeconds: yamnetSnoreSeconds.isEmpty
          ? null
          : yamnetSnoreSeconds.fold<double>(
              0.0,
              (sum, seconds) => sum + seconds,
            ),
      yamnetSnoreWindowCount: yamnetSnoreWindowCounts.isEmpty
          ? null
          : yamnetSnoreWindowCounts.fold<double>(
              0.0,
              (sum, count) => sum + count,
            ),
      snoreVolumePercent: maximumSnoreVolumePercent(
        snorePoints.map((point) => point.snoreVolumePercent),
      ),
      snoreSource: _dominantSnoreSource(snorePoints),
      earTemperatureC: _meanSeriesValue(
        points.map((point) => point.earTemperatureC),
      ),
      ppgQualityPercent: _meanSeriesValue(
        points.map((point) => point.ppgQualityPercent),
      ),
      breathingQualityPercent: _meanSeriesValue(
        points.map((point) => point.breathingQualityPercent),
      ),
      foreheadRollDeg: _circularMeanSeriesValue(
        points.map((point) => point.foreheadRollDeg),
      ),
      foreheadPitchDeg: _circularMeanSeriesValue(
        points.map((point) => point.foreheadPitchDeg),
      ),
      foreheadYawDeg: _circularMeanSeriesValue(
        points.map((point) => point.foreheadYawDeg),
      ),
      bellyRollDeg: _circularMeanSeriesValue(
        points.map((point) => point.bellyRollDeg),
      ),
      bellyPitchDeg: _circularMeanSeriesValue(
        points.map((point) => point.bellyPitchDeg),
      ),
      bellyYawDeg: _circularMeanSeriesValue(
        points.map((point) => point.bellyYawDeg),
      ),
    );
  }

  String? _dominantSnoreSource(List<SleepSessionSeriesPoint> points) {
    final weights = <String, double>{};
    for (final point in points) {
      final source = _normalizeSnoreSource(point.snoreSource);
      if (source == null || source.isEmpty) continue;
      final weight = math.max(
        1.0,
        point.snoreVolumePercent ?? point.snoreSeconds ?? 1.0,
      );
      weights[source] = (weights[source] ?? 0) + weight;
    }
    if (weights.isEmpty) return null;
    final entries = weights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.key;
  }

  String? _normalizeSnoreSource(String? source) {
    if (source == null || source.isEmpty) return null;
    final normalized = source.toLowerCase();
    if (normalized == 'traeger' || normalized == 'träger') return 'wearer';
    if (normalized == 'andere' || normalized == 'external') return 'external';
    if (normalized == 'gemischt' || normalized == 'mixed') return 'unknown';
    if (normalized == 'unbekannt' || normalized == 'unknown') return 'unknown';
    return source;
  }

  List<SleepSessionSeriesPoint> _mergeSleepSnoreDetails(
    List<SleepSessionSeriesPoint> base,
    List<SleepSessionSeriesPoint> details,
  ) {
    if (base.isEmpty || details.isEmpty) return base;
    final detailsByMinute = {
      for (final point in details) _sleepMinuteKey(point.time): point,
    };
    return [
      for (final point in base)
        () {
          final detail = detailsByMinute[_sleepMinuteKey(point.time)];
          if (detail == null) return point;
          return point.copyWith(
            snoreSeconds: detail.snoreSeconds ?? point.snoreSeconds,
            snoreVolumePercent:
                detail.snoreVolumePercent ?? point.snoreVolumePercent,
            snoreSource: detail.snoreSource ?? point.snoreSource,
          );
        }(),
    ];
  }

  List<SleepSessionSeriesPoint> _mergeSleepSnoreSources(
    List<SleepSessionSeriesPoint> base,
    List<SleepSessionSeriesPoint> details,
  ) {
    if (base.isEmpty || details.isEmpty) return base;
    final detailsByMinute = {
      for (final point in details) _sleepMinuteKey(point.time): point,
    };
    return [
      for (final point in base)
        () {
          final detail = detailsByMinute[_sleepMinuteKey(point.time)];
          if (detail == null) return point;
          return point.copyWith(
            snoreWindowCount: detail.snoreWindowCount,
            clearSnoreWindowCount: detail.snoreWindowCount == null,
            snoreSource: detail.snoreSource,
            clearSnoreSource: detail.snoreSource == null,
          );
        }(),
    ];
  }

  DateTime _sleepMinuteKey(DateTime time) {
    return DateTime(time.year, time.month, time.day, time.hour, time.minute);
  }

  double? _robustMeanSeriesValue(
    Iterable<double?> rawValues, {
    required double rejectDistance,
  }) {
    final values = [
      for (final value in rawValues)
        if (value != null && value.isFinite) value,
    ];
    if (values.isEmpty) return null;
    if (values.length == 1) return values.first;
    final median = _medianValue(values);
    final mad = _medianValue([
      for (final value in values) (value - median).abs(),
    ]);
    final limit = math.max(rejectDistance, 3.5 * 1.4826 * mad);
    final filtered = values
        .where((value) => (value - median).abs() <= limit)
        .toList(growable: false);
    final usable = filtered.isEmpty ? values : filtered;
    return usable.reduce((a, b) => a + b) / usable.length;
  }

  double? _meanSeriesValue(Iterable<double?> rawValues) {
    final values = [
      for (final value in rawValues)
        if (value != null && value.isFinite) value,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double? _circularMeanSeriesValue(Iterable<double?> rawValues) {
    var sinSum = 0.0;
    var cosSum = 0.0;
    var count = 0;
    for (final value in rawValues) {
      if (value == null || !value.isFinite) continue;
      final radians = value * math.pi / 180.0;
      sinSum += math.sin(radians);
      cosSum += math.cos(radians);
      count++;
    }
    if (count == 0) return null;
    if (sinSum.abs() < 1e-12 && cosSum.abs() < 1e-12) return 0;
    return math.atan2(sinSum, cosSum) * 180.0 / math.pi;
  }

  bool _isSleepMetricUsable(
    List<SleepSessionSeriesPoint> points,
    int index, {
    required double? Function(SleepSessionSeriesPoint point) valueFor,
    required double? Function(SleepSessionSeriesPoint point) qualityFor,
    required double minValue,
    required double maxValue,
    required double minQualityPercent,
    required bool motionSensitive,
  }) {
    final point = points[index];
    final value = valueFor(point);
    if (value == null || !value.isFinite) return false;
    if (value < minValue || value > maxValue) return false;
    final quality = qualityFor(point);
    if (quality != null && quality.isFinite && quality < minQualityPercent) {
      return false;
    }
    if (motionSensitive && _hasSleepPoseMotionArtifact(points, index)) {
      // A position change alone must not erase an otherwise high-quality
      // minute. The board's signal quality and robust minute estimator are the
      // primary evidence; motion only vetoes weak or missing quality evidence.
      if (quality == null ||
          !quality.isFinite ||
          quality < minQualityPercent + 15.0) {
        return false;
      }
    }
    return true;
  }

  bool _hasSleepPoseMotionArtifact(
    List<SleepSessionSeriesPoint> points,
    int index,
  ) {
    return _poseStepArtifact(points, index, index - 1) ||
        _poseStepArtifact(points, index, index + 1);
  }

  bool _poseStepArtifact(
    List<SleepSessionSeriesPoint> points,
    int index,
    int otherIndex,
  ) {
    if (otherIndex < 0 || otherIndex >= points.length) return false;
    final current = points[index];
    final other = points[otherIndex];
    final seconds =
        current.time.difference(other.time).inMilliseconds.abs() / 1000.0;
    if (seconds <= 0 || seconds > 150) return false;
    final deltas = <double?>[
      _angleDelta(current.foreheadRollDeg, other.foreheadRollDeg),
      _angleDelta(current.foreheadPitchDeg, other.foreheadPitchDeg),
      _angleDelta(current.bellyRollDeg, other.bellyRollDeg),
      _angleDelta(current.bellyPitchDeg, other.bellyPitchDeg),
    ].whereType<double>().toList(growable: false);
    if (deltas.isEmpty) return false;
    final maxDelta = deltas.reduce(math.max);
    final deltaPerMinute = maxDelta * 60.0 / math.max(1.0, seconds);
    return maxDelta >= 24 || deltaPerMinute >= 45;
  }

  double? _angleDelta(double? a, double? b) {
    if (a == null || b == null || !a.isFinite || !b.isFinite) return null;
    var delta = (a - b).abs() % 360.0;
    if (delta > 180) delta = 360.0 - delta;
    return delta;
  }

  double _medianValue(List<double> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2.0;
  }

  Future<File?> _sleepSessionSeriesFile(SleepSessionRecord record) async {
    final path = record.dataCsvPath;
    if (path != null && _isMeasurementDataCsvPath(path)) {
      final file = File(path);
      if (await file.exists()) return file;
    }
    final dir = await _csvDirectory(create: false);
    if (!await dir.exists()) return null;
    final candidates = await dir
        .list()
        .where((entity) =>
            entity is File &&
            entity.path.endsWith('.csv') &&
            _isMeasurementDataCsvPath(entity.path))
        .cast<File>()
        .toList();
    if (candidates.isEmpty) return null;
    File? best;
    var bestDistance = Duration(days: 9999);
    for (final candidate in candidates) {
      final firstTime =
          _fileTimestampFromName(candidate.path, 'mg24_events_') ??
              await _firstCsvTimestamp(candidate, record);
      if (firstTime == null) continue;
      final distance = firstTime.difference(record.metrics.startedAt).abs();
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    if (best != null && bestDistance <= const Duration(hours: 6)) {
      return best;
    }
    candidates
        .sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return candidates.first;
  }

  Future<File?> _sleepSessionSnoreDetailsFile(
    SleepSessionRecord record, {
    required String excludePath,
  }) async {
    final dir = await _csvDirectory(create: false);
    if (!await dir.exists()) return null;
    final candidates = await dir
        .list()
        .where((entity) =>
            entity is File &&
            entity.path != excludePath &&
            entity.path.endsWith('.csv') &&
            _isMeasurementDataCsvPath(entity.path))
        .cast<File>()
        .toList();
    File? best;
    var bestDistance = Duration(days: 9999);
    for (final candidate in candidates) {
      if (!await _csvHasAnyColumn(candidate, const [
        'snore_volume_percent',
        'snore_source',
      ])) {
        continue;
      }
      final firstTime = await _firstCsvTimestamp(candidate, record);
      if (firstTime == null) continue;
      final distance = firstTime.difference(record.metrics.startedAt).abs();
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    if (best != null && bestDistance <= const Duration(hours: 6)) return best;
    return null;
  }

  Future<File?> _sleepSessionEventDetailsFile(
    SleepSessionRecord record,
  ) async {
    final dir = await _csvDirectory(create: false);
    if (!await dir.exists()) return null;
    final candidates = await dir
        .list()
        .where((entity) =>
            entity is File &&
            entity.path.endsWith('.csv') &&
            _fileName(entity.path).startsWith('mg24_events_'))
        .cast<File>()
        .toList();
    File? best;
    var bestDistance = Duration(days: 9999);
    for (final candidate in candidates) {
      final firstTime = await _firstCsvTimestamp(candidate, record);
      if (firstTime == null) continue;
      final distance = firstTime.difference(record.metrics.startedAt).abs();
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    if (best != null && bestDistance <= const Duration(hours: 6)) return best;
    return null;
  }

  Future<bool> _csvHasAnyColumn(File file, List<String> columns) async {
    final lines = await file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .take(1)
        .toList();
    if (lines.isEmpty) return false;
    final header = _splitCsvLine(lines.first).toSet();
    return columns.any(header.contains);
  }

  Future<DateTime?> _firstCsvTimestamp(
    File file,
    SleepSessionRecord record,
  ) async {
    final lines = await file
        .openRead()
        .transform(utf8.decoder)
        .transform(
          const LineSplitter(),
        )
        .take(2)
        .toList();
    if (lines.length < 2) return null;
    final header = _splitCsvLine(lines.first);
    final values = _splitCsvLine(lines[1]);
    final index = <String, int>{
      for (var i = 0; i < header.length; i++) header[i]: i,
    };
    return _csvDateTime(index, values, record);
  }

  SleepSessionSeriesPoint? _seriesPointFromCsv(
    SleepSessionRecord record,
    Map<String, int> index,
    List<String> values,
  ) {
    final time = _csvDateTime(index, values, record);
    if (time == null) return null;
    final minute = _csvInt(index, values, 'Minute') ??
        time.difference(record.metrics.startedAt).inMinutes;
    final liveSnore = _csvDouble(index, values, 'snore');
    final snoreSeconds = _csvSnoreSeconds(index, values, liveSnore);
    return SleepSessionSeriesPoint(
      time: time,
      minute: minute,
      heartRateBpm: _csvDouble(index, values, 'Herzfrequenz_bpm') ??
          _csvDouble(index, values, 'heart_rate_bpm'),
      breathingRatePerMin: _csvDouble(index, values, 'Atemfrequenz_pro_min') ??
          _csvDouble(index, values, 'breathing_rate_per_min'),
      snoreSeconds: snoreSeconds,
      yamnetSnoreSeconds:
          _csvDouble(index, values, 'YAMNet_Geschnarcht_Sekunden') ??
              _csvDouble(index, values, 'yamnet_snore_seconds'),
      yamnetSnoreWindowCount:
          _csvDouble(index, values, 'YAMNet_Schnarchzuege') ??
              _csvDouble(index, values, 'yamnet_snore_window_count'),
      snoreVolumePercent:
          _csvDouble(index, values, 'Schnarchlautstaerke_Prozent') ??
              _csvDouble(index, values, 'snore_volume_percent'),
      snoreSource: _normalizeSnoreSource(
        _csvString(index, values, 'snore_source'),
      ),
      earTemperatureC: _csvDouble(index, values, 'Ohrtemperatur_C') ??
          _csvDouble(index, values, 'mg24_forehead_ear_temperature_c'),
      ppgQualityPercent: _csvDouble(index, values, 'MAX_Qualitaet_Prozent') ??
          _csvDouble(index, values, 'ppg_quality_percent'),
      breathingQualityPercent:
          _csvDouble(index, values, 'Atmung_Qualitaet_Prozent') ??
              _csvDouble(index, values, 'breathing_quality_percent') ??
              _csvDouble(index, values, 'respiration_quality_percent'),
      foreheadRollDeg: _csvDouble(index, values, 'Stirn_Roll_Grad') ??
          _csvDouble(index, values, 'mg24_forehead_roll_deg'),
      foreheadPitchDeg: _csvDouble(index, values, 'Stirn_Pitch_Grad') ??
          _csvDouble(index, values, 'mg24_forehead_pitch_deg'),
      foreheadYawDeg: _csvDouble(index, values, 'Stirn_Yaw_Grad') ??
          _csvDouble(index, values, 'mg24_forehead_yaw_deg'),
      bellyRollDeg: _csvDouble(index, values, 'Bauch_Roll_Grad') ??
          _csvDouble(index, values, 'mg24_belly_roll_deg'),
      bellyPitchDeg: _csvDouble(index, values, 'Bauch_Pitch_Grad') ??
          _csvDouble(index, values, 'mg24_belly_pitch_deg'),
      bellyYawDeg: _csvDouble(index, values, 'Bauch_Yaw_Grad') ??
          _csvDouble(index, values, 'mg24_belly_yaw_deg'),
    );
  }

  double? _csvSnoreSeconds(
    Map<String, int> index,
    List<String> values,
    double? liveSnore,
  ) {
    final boardSeconds = _csvDouble(index, values, 'Geschnarcht_Sekunden');
    if (boardSeconds != null && boardSeconds.isFinite) {
      return boardSeconds.clamp(0.0, 60.0).toDouble();
    }

    final liveSeconds = _csvDouble(index, values, 'snore_seconds');
    if (liveSeconds != null && liveSeconds.isFinite) {
      return liveSeconds.clamp(0.0, csvWriteIntervalSeconds).toDouble();
    }

    final hasLiveSnoreSeconds = index.containsKey('snore_seconds');
    if (hasLiveSnoreSeconds) {
      return liveSnore == null ? null : 0.0;
    }

    return _legacyLiveSnoreSeconds(index, values, liveSnore);
  }

  double? _legacyLiveSnoreSeconds(
    Map<String, int> index,
    List<String> values,
    double? liveSnore,
  ) {
    if (liveSnore == null) return null;
    if (liveSnore < 0.5) return 0.0;
    final volume = _csvDouble(index, values, 'snore_volume_percent');
    final confidence =
        _csvDouble(index, values, 'snore_source_confidence_percent');
    final source = _csvString(index, values, 'snore_source');
    var estimate = csvWriteIntervalSeconds * 0.20;
    if (volume != null && volume.isFinite) {
      estimate *= (0.60 + (volume / 100.0).clamp(0.0, 1.0) * 0.55);
    }
    if (confidence != null && confidence.isFinite) {
      estimate *= (0.75 + (confidence / 100.0).clamp(0.0, 1.0) * 0.35);
    }
    if (source == null || source.isEmpty) {
      estimate *= 0.70;
    }
    return estimate.clamp(0.0, csvWriteIntervalSeconds * 0.35).toDouble();
  }

  DateTime? _csvDateTime(
    Map<String, int> index,
    List<String> values,
    SleepSessionRecord record,
  ) {
    final raw = _csvString(index, values, 'Uhrzeit') ??
        _csvString(index, values, 'uhrzeit');
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;
    final parts = raw.split(':');
    if (parts.length >= 2) {
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      final second = parts.length >= 3 ? int.tryParse(parts[2]) ?? 0 : 0;
      if (hour != null && minute != null) {
        var date = DateTime(
          record.metrics.startedAt.year,
          record.metrics.startedAt.month,
          record.metrics.startedAt.day,
          hour,
          minute,
          second,
        );
        if (date.isBefore(
            record.metrics.startedAt.subtract(const Duration(hours: 8)))) {
          date = date.add(const Duration(days: 1));
        }
        return date;
      }
    }
    return null;
  }

  List<String> _splitCsvLine(String line) => line.split(',');

  String? _csvString(Map<String, int> index, List<String> values, String key) {
    final i = index[key];
    if (i == null || i < 0 || i >= values.length) return null;
    final value = values[i].trim();
    return value.isEmpty ? null : value;
  }

  double? _csvDouble(Map<String, int> index, List<String> values, String key) {
    final value = _csvString(index, values, key);
    if (value == null) return null;
    return double.tryParse(value.replaceAll(',', '.'));
  }

  int? _csvInt(Map<String, int> index, List<String> values, String key) {
    final value = _csvString(index, values, key);
    if (value == null) return null;
    return int.tryParse(value);
  }

  Future<File?> _currentCsvFile() async {
    final current = _csvFile;
    if (current != null && await current.exists()) return current;

    final path = snapshot.csvPath;
    if (path != null && _isMeasurementDataCsvPath(path)) {
      final file = File(path);
      if (await file.exists()) {
        _csvFile = file;
        return file;
      }
    }

    final latest = await _latestCsvFile();
    if (latest != null && !running) {
      _csvFile = latest;
    }
    return latest;
  }

  Future<File?> _latestCsvFile() async {
    final dir = await _csvDirectory(create: false);
    if (!await dir.exists()) return null;

    final files = await dir
        .list()
        .where((entity) =>
            entity is File &&
            entity.path.endsWith('.csv') &&
            _isMeasurementDataCsvPath(entity.path))
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;

    files.sort((a, b) {
      final aTime = a.lastModifiedSync();
      final bTime = b.lastModifiedSync();
      return bTime.compareTo(aTime);
    });
    return files.first;
  }

  bool _isMeasurementDataCsvPath(String path) {
    final name = _fileName(path);
    return name.startsWith('messung_') ||
        name.startsWith('mg24_minuten_') ||
        name.startsWith('mg24_minute_archive_');
  }

  Future<File?> _requireCsvFile() async {
    final file = await _currentCsvFile();
    final dir = await _csvDirectory(create: true);
    if (file == null) {
      snapshot = snapshot.copyWith(
        status:
            'Noch keine CSV-Datei vorhanden. Bitte zuerst eine Messung starten.',
        fileLabel: 'Noch keine CSV-Datei',
        csvDirectoryPath: dir.path,
        clearCsvPath: true,
      );
      notifyListeners();
      return null;
    }

    snapshot = snapshot.copyWith(
      fileLabel: 'CSV: ${_fileName(file.path)}',
      csvPath: file.path,
      csvDirectoryPath: file.parent.path,
    );
    return file;
  }

  Future<void> _flushCsv() async {
    final sink = _csvSink;
    if (sink != null) {
      await sink.flush();
    }
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index == -1 ? normalized : normalized.substring(index + 1);
  }

  DateTime? _fileTimestampFromName(String path, String prefix) {
    final name = _fileName(path);
    if (!name.startsWith(prefix)) return null;
    final stamp = name.substring(prefix.length).replaceAll('.csv', '');
    if (stamp.length < 15 || stamp[8] != '_') return null;
    final year = int.tryParse(stamp.substring(0, 4));
    final month = int.tryParse(stamp.substring(4, 6));
    final day = int.tryParse(stamp.substring(6, 8));
    final hour = int.tryParse(stamp.substring(9, 11));
    final minute = int.tryParse(stamp.substring(11, 13));
    final second = int.tryParse(stamp.substring(13, 15));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return DateTime(year, month, day, hour, minute, second);
  }

  Future<void> _ensureSelectedDevice() async {
    if (!supportsBitalinoHardware) {
      throw StateError(
          'BITalino-Messung ist auf diesem Ziel nicht verfuegbar.');
    }

    if (selectedDevice == null) {
      await _scanForDevices(allowWhileRunning: true);
    }

    if (selectedDevice == null) {
      if (availableDevices.isEmpty) {
        throw StateError(
          'Kein gekoppelter BITalino gefunden. Bitte den BITalino in Android-Bluetooth koppeln.',
        );
      }
      throw StateError('Bitte einen BITalino auswaehlen.');
    }
  }

  Future<bool> _ensureBluetoothPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();
      return statuses.values.every((status) => status.isGranted);
    }

    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted;
    }

    return true;
  }

  Future<bool> _ensureMicrophonePermission() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final status = await Permission.microphone.request();
      return status.isGranted;
    }

    return true;
  }

  Future<void> _refreshForegroundService() async {
    if (!Platform.isAndroid) return;

    final shouldRun = _measurementForegroundOwner ||
        _trainingForegroundOwner ||
        _yamnetMonitorForegroundOwner;
    if (!shouldRun) {
      await _stopForegroundService();
      return;
    }

    final usesMicrophone = _measurementForegroundUsesMicrophone ||
        _trainingForegroundOwner ||
        _yamnetMonitorForegroundOwner;
    final usesConnectedDevice = _measurementForegroundUsesConnectedDevice ||
        _trainingForegroundOwner ||
        _yamnetMonitorForegroundOwner;
    await Permission.notification.request();
    await MeasurementForegroundService.start(
      usesMicrophone: usesMicrophone,
      usesConnectedDevice: usesConnectedDevice,
      trainingActive: _trainingForegroundOwner,
    );
  }

  Future<void> _ensureBackgroundMeasurementAllowed({
    required bool usesMicrophone,
    required bool usesConnectedDevice,
  }) async {
    if (!Platform.isAndroid || (!usesMicrophone && !usesConnectedDevice)) {
      return;
    }

    bool alreadyAllowed;
    try {
      alreadyAllowed =
          await MeasurementForegroundService.isIgnoringBatteryOptimizations();
    } catch (_) {
      return;
    }
    if (alreadyAllowed) return;

    snapshot = snapshot.copyWith(
      status:
          'Android-Akkuoptimierung kann die Nachtmessung beenden. Bitte LASLI als "Nicht optimieren" zulassen.',
    );
    notifyListeners();

    if (_batteryOptimizationPromptShown) return;
    _batteryOptimizationPromptShown = true;
    try {
      await MeasurementForegroundService.requestIgnoreBatteryOptimizations();
    } catch (_) {}
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await MeasurementForegroundService.stop();
    } catch (_) {}
  }

  String _deviceLabel(BITalinoDevice device) {
    return '${device.name} (${device.address})';
  }

  String _friendlyError(Object error) {
    final text = error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('BITalinoException: ', '')
        .replaceFirst('Bad state: ', '');

    if (text.contains('CONTROLLER_FAILED_INITIALIZE')) {
      return 'BITalino konnte nicht initialisiert werden. Bitte Bluetooth einschalten, Berechtigungen erlauben und den BITalino gekoppelt lassen.';
    }
    if (text.contains('BT_DEVICE_FAILED_CONNECT') ||
        text.contains('BT_DEVICE_NOT_CONNECTED')) {
      return 'BITalino konnte nicht verbunden werden. Bitte pruefen, ob er eingeschaltet und in Android gekoppelt ist.';
    }
    final lowerText = text.toLowerCase();
    if (text.contains('FlutterBluePlusException') ||
        lowerText.contains('gatt') ||
        lowerText.contains('android code 133') ||
        lowerText.contains('android-code: 133')) {
      return 'Android hat die MG24-BLE-Verbindung abgebrochen. Bitte Sensoren nah ans Handy legen und erneut verbinden.';
    }
    if ((text.contains('MG24') || text.contains('XIAO')) &&
        lowerText.contains('timeout')) {
      return 'Zeitueberschreitung bei der MG24-Verbindung. Bitte Sensoren nah ans Handy legen und erneut verbinden.';
    }
    if (text.contains('TIMEOUT')) {
      return 'Zeitueberschreitung bei der Verbindung.';
    }
    if (text.contains('BluetoothPermission')) {
      return 'Bluetooth-Berechtigung fehlt. Bitte der App Bluetooth in Android erlauben.';
    }
    if (text.contains('Bluetooth ist nicht eingeschaltet')) {
      return 'Bluetooth ist nicht eingeschaltet oder wurde nicht erlaubt.';
    }
    if (text.contains('MG24') || text.contains('XIAO')) {
      return text;
    }
    if (text.contains('FOREGROUND_SERVICE') ||
        text.toLowerCase().contains('foreground service')) {
      return 'Hintergrunddienst konnte nicht gestartet werden. Bitte Bluetooth/Mikrofon-Berechtigungen erlauben und die App im Vordergrund starten.';
    }
    if (text.contains('ESPHome-Hello') &&
        text.contains('Sensor hat die Verbindung geschlossen')) {
      return 'Der Sensor schliesst die ESPHome-API schon beim Hello. Das Sensor-WLAN ist bei dieser Firmware nur fuer die Einrichtung; fuer Messdaten muss der Sensor im gleichen 2,4-GHz Home-/Handy-WLAN wie das Handy sein.';
    }
    if (text.contains('API-Verschluesselung') ||
        text.contains('Encryption-Key')) {
      return 'Der Sensor verlangt ESPHome-API-Encryption. Ohne den passenden Encryption-Key kann die App weder direkt noch im WLAN Radarwerte lesen.';
    }
    if (text.contains('Sensor hat die Verbindung geschlossen') ||
        text.contains('Radar-Socket wurde geschlossen') ||
        text.toLowerCase().contains('connection closed')) {
      return 'Der Sensor hat die Radar-API-Verbindung geschlossen. Wahrscheinlich passen ESPHome-API-Modus, Passwort oder Encryption nicht zur App.';
    }

    return text;
  }

  BITalinoDevice? _findDevice(String? address) {
    if (address == null) return null;
    for (final device in availableDevices) {
      if (device.address == address) return device;
    }
    return null;
  }
}

class _Mg24PoseCalibration {
  const _Mg24PoseCalibration({
    this.angleDeg,
    this.rollDeg,
    this.pitchDeg,
    this.yawDeg,
    this.quaternion,
  });

  final double? angleDeg;
  final double? rollDeg;
  final double? pitchDeg;
  final double? yawDeg;
  final _Mg24Quaternion? quaternion;
}

class _Mg24Quaternion {
  const _Mg24Quaternion(this.w, this.x, this.y, this.z);

  final double w;
  final double x;
  final double y;
  final double z;

  _Mg24Quaternion? normalized() {
    final length = math.sqrt(w * w + x * x + y * y + z * z);
    if (!length.isFinite || length <= 1e-9) return null;
    return _Mg24Quaternion(w / length, x / length, y / length, z / length);
  }

  _Mg24Quaternion inverse() {
    return _Mg24Quaternion(w, -x, -y, -z);
  }

  _Mg24Quaternion operator *(_Mg24Quaternion other) {
    return _Mg24Quaternion(
      w * other.w - x * other.x - y * other.y - z * other.z,
      w * other.x + x * other.w + y * other.z - z * other.y,
      w * other.y - x * other.z + y * other.w + z * other.x,
      w * other.z + x * other.y - y * other.x + z * other.w,
    );
  }
}

class _Mg24EulerAngles {
  const _Mg24EulerAngles({
    required this.rollDeg,
    required this.pitchDeg,
    required this.yawDeg,
  });

  final double rollDeg;
  final double pitchDeg;
  final double yawDeg;
}

class _Mg24SnoreTimingWindow {
  const _Mg24SnoreTimingWindow({
    required this.startAt,
    required this.endAt,
    required this.plotStartS,
    required this.plotEndS,
    this.counter,
  });

  final DateTime startAt;
  final DateTime endAt;
  final double plotStartS;
  final double plotEndS;
  final int? counter;

  DateTime get centerAt => startAt.add(
        Duration(
          microseconds: endAt.difference(startAt).inMicroseconds ~/ 2,
        ),
      );

  double get widthMs =>
      endAt.difference(startAt).inMicroseconds /
      Duration.microsecondsPerMillisecond;

  _Mg24SnoreTimingWindow withWidthMs(double widthMs) {
    final widthUs = (widthMs * Duration.microsecondsPerMillisecond)
        .round()
        .clamp(1, 65535000)
        .toInt();
    return _Mg24SnoreTimingWindow(
      startAt: startAt,
      endAt: startAt.add(Duration(microseconds: widthUs)),
      plotStartS: plotStartS,
      plotEndS: plotStartS + widthUs / Duration.microsecondsPerSecond,
      counter: counter,
    );
  }

  YamnetRawSnoreWindow get asYamnetWindow =>
      YamnetRawSnoreWindow(startAt: startAt, endAt: endAt);
}

class _Mg24ClockObservation {
  const _Mg24ClockObservation(this.timelineS, this.offsetS);

  final double timelineS;
  final double offsetS;
}

class _Mg24SensorClockMapper {
  static const _windowSeconds = 12.0;

  final Queue<_Mg24ClockObservation> _observations =
      Queue<_Mg24ClockObservation>();
  double? _offsetS;
  double? _lastSensorTimeS;

  void reset() {
    _observations.clear();
    _offsetS = null;
    _lastSensorTimeS = null;
  }

  double? update({
    required double sensorTimeS,
    required double receivedTimelineS,
  }) {
    if (!sensorTimeS.isFinite ||
        !receivedTimelineS.isFinite ||
        sensorTimeS < 0 ||
        receivedTimelineS < 0) {
      return timelineTimeForSensorTime(sensorTimeS);
    }
    final lastSensorTimeS = _lastSensorTimeS;
    if (lastSensorTimeS != null && sensorTimeS + 1.0 < lastSensorTimeS) {
      reset();
    }
    _lastSensorTimeS = sensorTimeS;

    final observedOffset = receivedTimelineS - sensorTimeS;
    if (!observedOffset.isFinite) return timelineTimeForSensorTime(sensorTimeS);
    _observations.addLast(_Mg24ClockObservation(
      receivedTimelineS,
      observedOffset,
    ));
    final cutoff = receivedTimelineS - _windowSeconds;
    while (_observations.isNotEmpty && _observations.first.timelineS < cutoff) {
      _observations.removeFirst();
    }

    var bestOffset = observedOffset;
    for (final observation in _observations) {
      if (observation.offsetS < bestOffset) {
        bestOffset = observation.offsetS;
      }
    }
    final previous = _offsetS;
    _offsetS = previous == null
        ? bestOffset
        : previous + (bestOffset - previous) * 0.18;
    return timelineTimeForSensorTime(sensorTimeS);
  }

  double? timelineTimeForSensorTime(double sensorTimeS) {
    final offset = _offsetS;
    if (offset == null || !sensorTimeS.isFinite) return null;
    final timeS = sensorTimeS + offset;
    return timeS.isFinite && timeS >= 0 ? timeS : null;
  }
}

class _Mg24RelativeYawEstimate {
  const _Mg24RelativeYawEstimate({
    this.yawDeg,
    this.qualityPercent,
    this.uncertaintyDeg,
  });

  const _Mg24RelativeYawEstimate.empty()
      : yawDeg = null,
        qualityPercent = null,
        uncertaintyDeg = null;

  final double? yawDeg;
  final double? qualityPercent;
  final double? uncertaintyDeg;
}

class _Mg24HeadingObservation {
  const _Mg24HeadingObservation({
    required this.yawDeg,
    required this.projection,
  });

  final double yawDeg;
  final double projection;
}

class _Mg24RelativeYawEstimator {
  double? _zeroDeg;
  double? _lastRawDeg;
  DateTime? _lastUpdate;
  double? _lastForeheadRollDeg;
  double? _lastForeheadPitchDeg;
  double? _lastBellyRollDeg;
  double? _lastBellyPitchDeg;
  ({double x, double y, double z})? _lastForeheadAccel;
  ({double x, double y, double z})? _lastBellyAccel;
  double? _lastForeheadHeadingDeg;
  double? _lastBellyHeadingDeg;
  double? _filteredYawDeg;
  double _biasRateDegPerSec = 0;
  double _biasOffsetDeg = 0;
  double _uncertaintyDeg = 4;
  int _stationarySamples = 0;
  double? _lastStationaryHoldDeg;

  void reset() {
    _zeroDeg = null;
    _lastRawDeg = null;
    _lastUpdate = null;
    _lastForeheadRollDeg = null;
    _lastForeheadPitchDeg = null;
    _lastBellyRollDeg = null;
    _lastBellyPitchDeg = null;
    _lastForeheadAccel = null;
    _lastBellyAccel = null;
    _lastForeheadHeadingDeg = null;
    _lastBellyHeadingDeg = null;
    _filteredYawDeg = null;
    _biasRateDegPerSec = 0;
    _biasOffsetDeg = 0;
    _uncertaintyDeg = 4;
    _stationarySamples = 0;
    _lastStationaryHoldDeg = null;
  }

  _Mg24RelativeYawEstimate update({
    required Mg24SensorSummary forehead,
    required Mg24SensorSummary belly,
    required DateTime now,
    required bool correctionEnabled,
  }) {
    final foreheadHeading = _sensorHeading(
      forehead,
      previousHeadingDeg: _lastForeheadHeadingDeg,
    );
    final bellyHeading = _sensorHeading(
      belly,
      previousHeadingDeg: _lastBellyHeadingDeg,
    );
    if (!forehead.connected ||
        !belly.connected ||
        foreheadHeading == null ||
        bellyHeading == null) {
      _lastUpdate = null;
      return const _Mg24RelativeYawEstimate.empty();
    }

    final rawRelativeYaw =
        _angleDeltaDeg(foreheadHeading.yawDeg, bellyHeading.yawDeg);
    final headingQuality =
        math.min(foreheadHeading.projection, bellyHeading.projection);
    if (_zeroDeg == null) {
      _zeroDeg = rawRelativeYaw;
      _lastRawDeg = rawRelativeYaw;
      _lastUpdate = now;
      _lastForeheadHeadingDeg = foreheadHeading.yawDeg;
      _lastBellyHeadingDeg = bellyHeading.yawDeg;
      _filteredYawDeg = 0;
      _rememberTilt(forehead, belly);
      return const _Mg24RelativeYawEstimate(
        yawDeg: 0,
        qualityPercent: 96,
        uncertaintyDeg: 4,
      );
    }

    final previousUpdate = _lastUpdate;
    var dt = previousUpdate == null
        ? 0.0
        : now.difference(previousUpdate).inMicroseconds /
            Duration.microsecondsPerSecond;
    if (!dt.isFinite || dt < 0) dt = 0;
    var stationary = false;
    final observedRate = _relativeYawObservedRate(rawRelativeYaw, dt);
    if (dt > 0 && dt <= 3.0) {
      _biasOffsetDeg =
          _normalizeAngleDeg(_biasOffsetDeg + _biasRateDegPerSec * dt);
      if (correctionEnabled) {
        stationary = _updateBiasEstimate(
          forehead: forehead,
          belly: belly,
          rawRelativeYaw: rawRelativeYaw,
          dt: dt,
          observedRate: observedRate,
        );
      } else {
        _stationarySamples = 0;
      }
    } else if (dt > 3.0) {
      _uncertaintyDeg = math.min(75.0, _uncertaintyDeg + dt * 0.12);
      _stationarySamples = 0;
    }

    if (headingQuality < 0.22 && dt > 0 && dt <= 3.0) {
      _uncertaintyDeg =
          math.min(75.0, _uncertaintyDeg + dt * (0.18 - headingQuality * 0.35));
    }

    final correctedYawDeg =
        _angleDeltaDeg(rawRelativeYaw, _zeroDeg! + _biasOffsetDeg);
    final yawDeg = _filterRelativeYawDeg(
      correctedYawDeg,
      dt: dt,
      stationary: stationary,
      headingQuality: headingQuality,
      observedRate: observedRate,
    );
    final quality = (100 -
            _uncertaintyDeg * 2.2 -
            _biasRateDegPerSec.abs() * 8.0 -
            (1 - headingQuality).clamp(0.0, 1.0) * 18.0)
        .clamp(0.0, 100.0)
        .toDouble();

    _lastRawDeg = rawRelativeYaw;
    _lastUpdate = now;
    _lastForeheadHeadingDeg = foreheadHeading.yawDeg;
    _lastBellyHeadingDeg = bellyHeading.yawDeg;
    _rememberTilt(forehead, belly);

    return _Mg24RelativeYawEstimate(
      yawDeg: yawDeg.abs() < 0.05 ? 0 : yawDeg,
      qualityPercent: quality,
      uncertaintyDeg: _uncertaintyDeg,
    );
  }

  bool _updateBiasEstimate({
    required Mg24SensorSummary forehead,
    required Mg24SensorSummary belly,
    required double rawRelativeYaw,
    required double dt,
    required double? observedRate,
  }) {
    final lastRawDeg = _lastRawDeg;
    if (lastRawDeg == null || dt <= 0 || observedRate == null) return false;

    final gyroStill = _gyroLooksStill(forehead) && _gyroLooksStill(belly);
    final tiltStill = _tiltLooksStill(forehead, belly, dt);
    final driftLikeYaw = observedRate.abs() <= 1.8;
    final stationary = driftLikeYaw && gyroStill && tiltStill;

    if (stationary) {
      _stationarySamples++;
      final targetRate = observedRate.clamp(-1.6, 1.6).toDouble();
      final alpha = _stationarySamples >= 5 ? 0.22 : 0.075;
      _biasRateDegPerSec += (targetRate - _biasRateDegPerSec) * alpha;
      final recovery = _stationarySamples >= 5 ? 0.55 : 0.16;
      _uncertaintyDeg = math.max(1.2, _uncertaintyDeg - dt * recovery);
      return true;
    }

    _stationarySamples = 0;
    _lastStationaryHoldDeg = null;
    _biasRateDegPerSec *= math.pow(0.96, dt).toDouble();
    final motionPenalty =
        (observedRate.abs() * 0.015).clamp(0.0, 0.3).toDouble();
    _uncertaintyDeg =
        math.min(75.0, _uncertaintyDeg + dt * (0.08 + motionPenalty));
    return false;
  }

  double? _relativeYawObservedRate(double rawRelativeYaw, double dt) {
    final lastRawDeg = _lastRawDeg;
    if (lastRawDeg == null || dt <= 0 || !dt.isFinite) return null;
    return _angleDeltaDeg(rawRelativeYaw, lastRawDeg) / dt;
  }

  double _filterRelativeYawDeg(
    double correctedYawDeg, {
    required double dt,
    required bool stationary,
    required double headingQuality,
    required double? observedRate,
  }) {
    final previous = _filteredYawDeg;
    if (previous == null || dt <= 0 || dt > 3.0) {
      _filteredYawDeg = correctedYawDeg;
      return correctedYawDeg;
    }

    final innovation = _angleDeltaDeg(correctedYawDeg, previous);
    final rate = observedRate?.abs() ?? 0.0;
    final likelyOutlier =
        headingQuality < 0.18 || (stationary && innovation.abs() > 8.0);
    if (likelyOutlier) {
      _uncertaintyDeg = math.min(75.0, _uncertaintyDeg + dt * 0.35);
      return previous;
    }

    if (stationary) {
      final warmup = _stationarySamples < 8;
      if (!warmup) {
        final hold = _lastStationaryHoldDeg ?? previous;
        final holdInnovation = _angleDeltaDeg(correctedYawDeg, hold);
        final offsetAlpha = headingQuality < 0.30 ? 0.46 : 0.34;
        _biasOffsetDeg = _normalizeAngleDeg(
          _biasOffsetDeg + holdInnovation * offsetAlpha,
        );
        _filteredYawDeg = hold.abs() < 0.08 ? 0 : hold;
        _lastStationaryHoldDeg = _filteredYawDeg;
        return _filteredYawDeg!;
      }

      final settleAlpha = innovation.abs() < 1.2 ? 0.012 : 0.075;
      final next = _normalizeAngleDeg(previous + innovation * settleAlpha);
      _filteredYawDeg = next.abs() < 0.08 ? 0 : next;
      _lastStationaryHoldDeg = _filteredYawDeg;
      return _filteredYawDeg!;
    }

    _lastStationaryHoldDeg = null;
    final alpha = rate > 20.0 ? 0.45 : 0.28;
    final next = _normalizeAngleDeg(previous + innovation * alpha);
    _filteredYawDeg = next.abs() < 0.04 ? 0 : next;
    return _filteredYawDeg!;
  }

  _Mg24HeadingObservation? _sensorHeading(
    Mg24SensorSummary sensor, {
    required double? previousHeadingDeg,
  }) {
    final quaternion = _mg24QuaternionFromSensor(sensor);
    if (quaternion != null) {
      final heading = _headingFromQuaternion(
        quaternion,
        previousHeadingDeg: previousHeadingDeg,
      );
      if (heading != null) return heading;
    }
    final yaw = sensor.yawDeg;
    if (!_isFinite(yaw)) return null;
    final continuousYaw = previousHeadingDeg == null
        ? _normalizeAngleDeg(yaw!)
        : _nearestEquivalentAngleDeg(yaw!, previousHeadingDeg);
    return _Mg24HeadingObservation(yawDeg: continuousYaw, projection: 0.55);
  }

  _Mg24HeadingObservation? _headingFromQuaternion(
    _Mg24Quaternion quaternion, {
    required double? previousHeadingDeg,
  }) {
    final q = quaternion.normalized();
    if (q == null) return null;

    final xAxis = _rotateMg24Vector(q, 1, 0, 0);
    final yAxis = _rotateMg24Vector(q, 0, 1, 0);
    final candidates = <_Mg24HeadingObservation>[];

    final xProjection = math.sqrt(xAxis.x * xAxis.x + xAxis.y * xAxis.y);
    if (xProjection > 1e-5) {
      candidates.add(
        _Mg24HeadingObservation(
          yawDeg: math.atan2(xAxis.y, xAxis.x) * 180 / math.pi,
          projection: xProjection.clamp(0.0, 1.0).toDouble(),
        ),
      );
    }

    final yProjection = math.sqrt(yAxis.x * yAxis.x + yAxis.y * yAxis.y);
    if (yProjection > 1e-5) {
      candidates.add(
        _Mg24HeadingObservation(
          yawDeg: (math.atan2(yAxis.y, yAxis.x) - math.pi / 2) * 180 / math.pi,
          projection: yProjection.clamp(0.0, 1.0).toDouble(),
        ),
      );
    }

    if (candidates.isEmpty) return null;
    if (previousHeadingDeg == null) {
      final best = candidates.reduce(
        (best, candidate) =>
            candidate.projection > best.projection ? candidate : best,
      );
      return _Mg24HeadingObservation(
        yawDeg: _normalizeAngleDeg(best.yawDeg),
        projection: best.projection,
      );
    }

    final selected = candidates.reduce((best, candidate) {
      final candidateYaw =
          _nearestEquivalentAngleDeg(candidate.yawDeg, previousHeadingDeg);
      final bestYaw =
          _nearestEquivalentAngleDeg(best.yawDeg, previousHeadingDeg);
      final candidateScore = math.pow(candidateYaw - previousHeadingDeg, 2) +
          math.pow(1 - candidate.projection, 2) * 32.0;
      final bestScore = math.pow(bestYaw - previousHeadingDeg, 2) +
          math.pow(1 - best.projection, 2) * 32.0;
      return candidateScore < bestScore ? candidate : best;
    });
    return _Mg24HeadingObservation(
      yawDeg: _nearestEquivalentAngleDeg(
        selected.yawDeg,
        previousHeadingDeg,
      ),
      projection: selected.projection,
    );
  }

  bool _gyroLooksStill(Mg24SensorSummary sensor) {
    final gyroMagnitude = _mg24GyroMagnitude(sensor);
    return gyroMagnitude == null || gyroMagnitude <= 3.2;
  }

  bool _tiltLooksStill(
    Mg24SensorSummary forehead,
    Mg24SensorSummary belly,
    double dt,
  ) {
    if (dt <= 0) return false;
    final foreheadAccelDelta = _accelDirectionDeltaDeg(
      _sensorAcceleration(forehead),
      _lastForeheadAccel,
    );
    final bellyAccelDelta = _accelDirectionDeltaDeg(
      _sensorAcceleration(belly),
      _lastBellyAccel,
    );
    if (foreheadAccelDelta != null && bellyAccelDelta != null) {
      return foreheadAccelDelta / dt <= 2.2 && bellyAccelDelta / dt <= 2.2;
    }

    final foreheadRoll = _sensorRollDeg(forehead);
    final foreheadPitch = _sensorPitchDeg(forehead);
    final bellyRoll = _sensorRollDeg(belly);
    final bellyPitch = _sensorPitchDeg(belly);
    if (!_isFinite(foreheadRoll) ||
        !_isFinite(foreheadPitch) ||
        !_isFinite(bellyRoll) ||
        !_isFinite(bellyPitch) ||
        !_isFinite(_lastForeheadRollDeg) ||
        !_isFinite(_lastForeheadPitchDeg) ||
        !_isFinite(_lastBellyRollDeg) ||
        !_isFinite(_lastBellyPitchDeg)) {
      return false;
    }

    final foreheadDeltaRoll =
        _angleDeltaDeg(foreheadRoll!, _lastForeheadRollDeg!);
    final foreheadDeltaPitch =
        _angleDeltaDeg(foreheadPitch!, _lastForeheadPitchDeg!);
    final bellyDeltaRoll = _angleDeltaDeg(bellyRoll!, _lastBellyRollDeg!);
    final bellyDeltaPitch = _angleDeltaDeg(bellyPitch!, _lastBellyPitchDeg!);
    final foreheadDelta = math.sqrt(
      foreheadDeltaRoll * foreheadDeltaRoll +
          foreheadDeltaPitch * foreheadDeltaPitch,
    );
    final bellyDelta = math.sqrt(
      bellyDeltaRoll * bellyDeltaRoll + bellyDeltaPitch * bellyDeltaPitch,
    );
    return foreheadDelta / dt <= 0.65 && bellyDelta / dt <= 0.65;
  }

  void _rememberTilt(Mg24SensorSummary forehead, Mg24SensorSummary belly) {
    _lastForeheadRollDeg = _sensorRollDeg(forehead);
    _lastForeheadPitchDeg = _sensorPitchDeg(forehead);
    _lastBellyRollDeg = _sensorRollDeg(belly);
    _lastBellyPitchDeg = _sensorPitchDeg(belly);
    _lastForeheadAccel = _sensorAcceleration(forehead);
    _lastBellyAccel = _sensorAcceleration(belly);
  }

  double? _sensorRollDeg(Mg24SensorSummary sensor) => sensor.rollDeg;

  double? _sensorPitchDeg(Mg24SensorSummary sensor) => sensor.pitchDeg;

  ({double x, double y, double z})? _sensorAcceleration(
    Mg24SensorSummary sensor,
  ) {
    final ax = sensor.ax;
    final ay = sensor.ay;
    final az = sensor.az;
    if (!_isFinite(ax) || !_isFinite(ay) || !_isFinite(az)) return null;
    final length = math.sqrt(ax! * ax + ay! * ay + az! * az);
    if (!length.isFinite || length < 0.05) return null;
    return (x: ax / length, y: ay / length, z: az / length);
  }

  double? _accelDirectionDeltaDeg(
    ({double x, double y, double z})? current,
    ({double x, double y, double z})? previous,
  ) {
    if (current == null || previous == null) return null;
    final dot = (current.x * previous.x +
            current.y * previous.y +
            current.z * previous.z)
        .clamp(-1.0, 1.0)
        .toDouble();
    final angle = math.acos(dot) * 180.0 / math.pi;
    return angle.isFinite ? angle : null;
  }
}

_Mg24PoseCalibration? _mg24PoseCalibrationFrom(Mg24SensorSummary sensor) {
  final quaternion = _mg24QuaternionFromSensor(sensor);
  final hasEuler = _isFinite(sensor.rollDeg) ||
      _isFinite(sensor.pitchDeg) ||
      _isFinite(sensor.yawDeg) ||
      _isFinite(sensor.angleDeg);
  if (quaternion == null && !hasEuler) return null;
  return _Mg24PoseCalibration(
    angleDeg: sensor.angleDeg,
    rollDeg: sensor.rollDeg,
    pitchDeg: sensor.pitchDeg,
    yawDeg: sensor.yawDeg,
    quaternion: quaternion,
  );
}

_Mg24Quaternion? _mg24QuaternionFromSensor(Mg24SensorSummary sensor) {
  final w = sensor.qw;
  final x = sensor.qx;
  final y = sensor.qy;
  final z = sensor.qz;
  if (w == null || x == null || y == null || z == null) return null;
  if (!w.isFinite || !x.isFinite || !y.isFinite || !z.isFinite) return null;
  return _Mg24Quaternion(w, x, y, z).normalized();
}

({double x, double y, double z}) _rotateMg24Vector(
  _Mg24Quaternion quaternion,
  double x,
  double y,
  double z,
) {
  final rotated =
      quaternion * _Mg24Quaternion(0, x, y, z) * quaternion.inverse();
  return (x: rotated.x, y: rotated.y, z: rotated.z);
}

double? _calibratedMg24Angle(double? value, double? baseline) {
  if (!_isFinite(value)) return null;
  if (!_isFinite(baseline)) return value;
  return _angleDeltaDeg(value!, baseline!);
}

_Mg24Quaternion? _relativeMg24Quaternion(
  Mg24SensorSummary sensor,
  _Mg24PoseCalibration calibration,
) {
  final current = _mg24QuaternionFromSensor(sensor);
  final baseline = calibration.quaternion;
  if (current == null || baseline == null) return null;
  return (baseline.inverse() * current).normalized();
}

_Mg24EulerAngles? _mg24EulerAnglesFromQuaternion(_Mg24Quaternion quaternion) {
  final q = quaternion.normalized();
  if (q == null) return null;

  final vectorLength = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
  if (vectorLength.isFinite && vectorLength < 1e-5) {
    return const _Mg24EulerAngles(rollDeg: 0, pitchDeg: 0, yawDeg: 0);
  }

  final sinRollCosPitch = 2 * (q.w * q.x + q.y * q.z);
  final cosRollCosPitch = 1 - 2 * (q.x * q.x + q.y * q.y);
  final roll = math.atan2(sinRollCosPitch, cosRollCosPitch);

  final sinPitch = 2 * (q.w * q.y - q.z * q.x);
  final pitch = sinPitch.abs() >= 1
      ? (sinPitch < 0 ? -math.pi / 2 : math.pi / 2)
      : math.asin(sinPitch);

  final sinYawCosPitch = 2 * (q.w * q.z + q.x * q.y);
  final cosYawCosPitch = 1 - 2 * (q.y * q.y + q.z * q.z);
  final yaw = math.atan2(sinYawCosPitch, cosYawCosPitch);

  return _Mg24EulerAngles(
    rollDeg: _normalizeAngleDeg(roll * 180 / math.pi),
    pitchDeg: _normalizeAngleDeg(pitch * 180 / math.pi),
    yawDeg: _normalizeAngleDeg(yaw * 180 / math.pi),
  );
}

class _SnoreBreathEvidence {
  const _SnoreBreathEvidence({
    required this.phase,
    required this.normalizedSlope,
    required this.centerSlope,
    required this.bestOffsetS,
    required this.imuVibrationScore,
    required this.imuQuietScore,
    required this.imuArtifactScore,
    required this.imuVibrationSamples,
    required this.audioDurationS,
    required this.inhaleDurationS,
    required this.durationMatchScore,
    required this.frequencyMatchScore,
    required this.audioWeight,
  });

  final double? phase;
  final double? normalizedSlope;
  final double? centerSlope;
  final double bestOffsetS;
  final double imuVibrationScore;
  final double imuQuietScore;
  final double imuArtifactScore;
  final int imuVibrationSamples;
  final double? audioDurationS;
  final double? inhaleDurationS;
  final double? durationMatchScore;
  final double? frequencyMatchScore;
  final double audioWeight;
}

class _SnoreBreathingAlignment {
  const _SnoreBreathingAlignment({
    required this.phase,
    required this.bestInhaleSlope,
    required this.centerSlope,
    required this.bestOffsetS,
  });

  final double? phase;
  final double? bestInhaleSlope;
  final double? centerSlope;
  final double bestOffsetS;
}

class _Mg24OfflineEventRow {
  const _Mg24OfflineEventRow({
    required this.role,
    required this.kind,
    required this.record,
    this.source,
    this.detector = 'MG24',
  });

  final Mg24SensorRole role;
  final Mg24EventKind kind;
  final Mg24EventRecord record;
  final _Mg24OfflineSnoreSource? source;
  final String detector;
}

class _LiveMg24SnoreAssessment {
  _LiveMg24SnoreAssessment({
    required this.window,
    required this.plotWindow,
    required this.event,
  });

  final _Mg24SnoreTimingWindow window;
  final TimeWindow plotWindow;
  final Mg24EventRecord event;
  _Mg24OfflineSnoreSource source = const _Mg24OfflineSnoreSource(
    source: 'unknown',
    confidence: 0,
    overlapRatio: 0,
  );
}

class _Mg24OfflineSnoreSource {
  const _Mg24OfflineSnoreSource({
    required this.source,
    required this.confidence,
    required this.overlapRatio,
    this.phase = 0,
    this.breathStartS,
    this.breathEndS,
  });

  final String source;
  final double confidence;
  final double overlapRatio;
  final int phase;
  final double? breathStartS;
  final double? breathEndS;

  String get phaseLabel => switch (phase) {
        1 => 'Phase 1',
        2 => 'Phase 2',
        _ => '',
      };

  double? get breathDurationS => breathStartS == null || breathEndS == null
      ? null
      : breathEndS! - breathStartS!;
}

class _Mg24OfflinePhasePreference {
  const _Mg24OfflinePhasePreference({
    required this.phase,
    required this.confidence,
  });

  final int phase;
  final double confidence;
}

class _Mg24OfflineHalfOverlap {
  const _Mg24OfflineHalfOverlap({
    this.overlapS = 0,
    this.phase = 0,
    this.startS,
    this.endS,
  });

  final double overlapS;
  final int phase;
  final double? startS;
  final double? endS;

  double get durationS =>
      startS == null || endS == null ? 0.0 : math.max(0.0, endS! - startS!);
}

class _Mg24SnorePhaseEvidence {
  const _Mg24SnorePhaseEvidence({
    required this.snore,
    required this.covered,
    required this.aligned,
    required this.best,
    required this.individual,
  });

  final Mg24EventRecord snore;
  final bool covered;
  final bool aligned;
  final _Mg24OfflineHalfOverlap best;
  final _Mg24OfflineSnoreSource individual;
}

class _AutomaticTeacherWindow {
  const _AutomaticTeacherWindow({
    required this.id,
    required this.startUs,
    required this.endUs,
  });

  final int id;
  final int startUs;
  final int endUs;
}

void _pushLimited<T>(Queue<T> queue, T value, int maxLength) {
  queue.addLast(value);
  while (queue.length > maxLength) {
    queue.removeFirst();
  }
}

void _pushSignalSampleWindow(
  Queue<SignalSample> queue,
  SignalSample value,
  double windowSeconds,
  int maxLength,
) {
  queue.addLast(value);
  final minTimeS = value.timeS - windowSeconds;
  while (queue.isNotEmpty &&
      (queue.first.timeS < minTimeS || queue.length > maxLength)) {
    queue.removeFirst();
  }
}

double _finiteNullableOr(double? value, double fallback) {
  return value != null && value.isFinite ? value : fallback;
}

bool _isFinite(double? value) {
  return value != null && value.isFinite;
}

double? _mg24GyroMagnitude(Mg24SensorSummary sensor) {
  final gx = sensor.gx;
  final gy = sensor.gy;
  final gz = sensor.gz;
  if (!_isFinite(gx) || !_isFinite(gy) || !_isFinite(gz)) return null;
  final magnitude = math.sqrt(gx! * gx + gy! * gy + gz! * gz);
  return magnitude.isFinite ? magnitude : null;
}

double _angleDeltaDeg(double a, double b) {
  return _normalizeAngleDeg(a - b);
}

double _nearestEquivalentAngleDeg(double angle, double reference) {
  return reference + _normalizeAngleDeg(angle - reference);
}

double _normalizeAngleDeg(double value) {
  var delta = value;
  while (delta > 180) {
    delta -= 360;
  }
  while (delta < -180) {
    delta += 360;
  }
  return delta;
}
