import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import 'measurement_controller.dart';
import 'mg24_protocol.dart';
import 'models.dart';
import 'processing.dart';
import 'radar_client.dart';
import 'sleep_journal.dart';

const _selectedChipColor = Color(0xFF173A5E);
const _measurementAudioChannel = MethodChannel('de.lasli.app/audio');
const _mg24HeadModelAsset = 'assets/body_models/head.glb';
const _mg24ChestModelAsset = 'assets/body_models/chest.glb';
const _mg24BodyModelAsset = 'assets/body_models/body.glb';
const _mg24HeadMeshAsset = 'assets/body_models/head_mesh.json';
const _mg24ChestMeshAsset = 'assets/body_models/chest_mesh.json';

enum _Mg24BodyAssetMode {
  none,
  mesh,
  split,
  body,
}

Future<_Mg24BodyAssetMode> _detectMg24BodyModelAssets() async {
  if (await _assetExists(_mg24HeadMeshAsset) &&
      await _assetExists(_mg24ChestMeshAsset)) {
    return _Mg24BodyAssetMode.mesh;
  }
  if (await _assetExists(_mg24BodyModelAsset)) {
    return _Mg24BodyAssetMode.body;
  }
  if (await _assetExists(_mg24HeadModelAsset) &&
      await _assetExists(_mg24ChestModelAsset)) {
    return _Mg24BodyAssetMode.split;
  }
  return _Mg24BodyAssetMode.none;
}

Future<bool> _assetExists(String asset) async {
  try {
    await rootBundle.load(asset);
    return true;
  } catch (_) {
    return false;
  }
}

class LasliDashboard extends StatefulWidget {
  const LasliDashboard({required this.controller, super.key});

  final MeasurementController controller;

  @override
  State<LasliDashboard> createState() => _LasliDashboardState();
}

class _LasliDashboardState extends State<LasliDashboard> {
  bool _measurementScrollLocked = false;

  void _setMeasurementScrollLocked(bool locked) {
    if (_measurementScrollLocked == locked) return;
    setState(() => _measurementScrollLocked = locked);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.initializeSleepJournal();
      widget.controller.refreshCsvInfo();
      widget.controller.refreshSnoreTrainingRecordings();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final colorScheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: const Text('LASLI'),
          centerTitle: false,
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.home_outlined), text: 'Home'),
              Tab(icon: Icon(Icons.menu_book_outlined), text: 'Schlafjournal'),
              Tab(icon: Icon(Icons.tune), text: 'Entwickler'),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _HomeTab(
              controller: controller,
              snapshot: snapshot,
              scrollLocked: _measurementScrollLocked,
              onViewportInteractionChanged: _setMeasurementScrollLocked,
            ),
            _JournalTab(controller: controller),
            _MeasurementTab(
              controller: controller,
              snapshot: snapshot,
              scrollLocked: _measurementScrollLocked,
              onViewportInteractionChanged: _setMeasurementScrollLocked,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.controller,
    required this.snapshot,
    required this.scrollLocked,
    required this.onViewportInteractionChanged,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;
  final bool scrollLocked;
  final ValueChanged<bool> onViewportInteractionChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: scrollLocked
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        _HomeConnectionCard(controller: controller, snapshot: snapshot),
        const SizedBox(height: 10),
        _HomeLiveValues(snapshot: snapshot),
        const SizedBox(height: 10),
        _SelectedNightsPoseOverview(
          controller: controller,
          mg24: snapshot.mg24,
          relativeYawDeg: snapshot.orientation.relativeYawDeg,
          onResetPose: controller.calibrateMg24PoseNow,
          onBodyInteractionChanged: onViewportInteractionChanged,
        ),
      ],
    );
  }
}

class _SelectedNightsPoseOverview extends StatefulWidget {
  const _SelectedNightsPoseOverview({
    required this.controller,
    required this.mg24,
    required this.relativeYawDeg,
    required this.onResetPose,
    required this.onBodyInteractionChanged,
  });

  final MeasurementController controller;
  final Mg24State mg24;
  final double? relativeYawDeg;
  final VoidCallback? onResetPose;
  final ValueChanged<bool> onBodyInteractionChanged;

  @override
  State<_SelectedNightsPoseOverview> createState() =>
      _SelectedNightsPoseOverviewState();
}

class _SelectedNightsPoseOverviewState
    extends State<_SelectedNightsPoseOverview> {
  late Future<_HomePoseHistory> _historyFuture;
  String _historySignature = '';

  @override
  void initState() {
    super.initState();
    _reloadHistory();
  }

  @override
  void didUpdateWidget(covariant _SelectedNightsPoseOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _sleepHistorySignature(
      widget.controller.selectedCorrelationSleepHistory,
    );
    if (signature != _historySignature) {
      _reloadHistory();
    }
  }

  void _reloadHistory() {
    final records = List<SleepSessionRecord>.from(
      widget.controller.selectedCorrelationSleepHistory,
    );
    _historySignature = _sleepHistorySignature(records);
    _historyFuture = Future.wait([
      for (final record in records)
        widget.controller.loadSleepSessionSeries(record).then(
              (series) => _SleepHistorySeries(record: record, series: series),
            ),
    ]).then((history) {
      final usableNights =
          history.where((entry) => entry.series.any((point) => point.hasPose));
      return _HomePoseHistory(
        analysis: _poseAnalysisFromHistory(history),
        selectedNightCount: records.length,
        usableNightCount: usableNights.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomePoseHistory>(
      future: _historyFuture,
      builder: (context, historySnapshot) {
        final history = historySnapshot.data;
        return _Mg24PoseOverview(
          mg24: widget.mg24,
          relativeYawDeg: widget.relativeYawDeg,
          onResetPose: widget.onResetPose,
          onBodyInteractionChanged: widget.onBodyInteractionChanged,
          showPowerAndTemperature: false,
          summaryLine: _homePoseSnoreRiskText(
            widget.mg24,
            history,
            loading: historySnapshot.connectionState != ConnectionState.done,
          ),
        );
      },
    );
  }
}

class _HomePoseHistory {
  const _HomePoseHistory({
    required this.analysis,
    required this.selectedNightCount,
    required this.usableNightCount,
  });

  final PoseSnoreAnalysis analysis;
  final int selectedNightCount;
  final int usableNightCount;
}

String _sleepHistorySignature(List<SleepSessionRecord> records) {
  return records
      .map(
        (record) =>
            '${record.id}:${record.dataCsvPath ?? ''}:${record.metrics.endedAt.millisecondsSinceEpoch}',
      )
      .join('|');
}

String _homePoseSnoreRiskText(
  Mg24State mg24,
  _HomePoseHistory? history, {
  required bool loading,
}) {
  if (loading) {
    return 'Traeger-Schnarchwahrscheinlichkeit: Journal wird ausgewertet ...';
  }
  if (history == null || history.selectedNightCount == 0) {
    return 'Traeger-Schnarchwahrscheinlichkeit: keine Nacht ausgewaehlt';
  }
  if (history.usableNightCount == 0 || !history.analysis.hasData) {
    return 'Traeger-Schnarchwahrscheinlichkeit: noch zu wenig Journaldaten';
  }
  if (!mg24.hasDataPair) {
    return 'Traeger-Schnarchwahrscheinlichkeit: beide Sensoren erforderlich';
  }
  final forehead = mg24.forehead;
  final belly = mg24.belly;
  final foreheadRoll = forehead.rollDeg;
  final foreheadPitch = forehead.pitchDeg;
  final bellyRoll = belly.rollDeg;
  final bellyPitch = belly.pitchDeg;
  if (foreheadRoll == null ||
      foreheadPitch == null ||
      bellyRoll == null ||
      bellyPitch == null) {
    return 'Traeger-Schnarchwahrscheinlichkeit: Position wird ermittelt';
  }
  final estimate = history.analysis.estimateAtVisiblePose(
    foreheadRollDeg: foreheadRoll,
    foreheadPitchDeg: foreheadPitch,
    bellyRollDeg: bellyRoll,
    bellyPitchDeg: bellyPitch,
  );
  if (estimate == null) {
    return 'Traeger-Schnarchwahrscheinlichkeit: Position noch zu selten';
  }
  final probability = (estimate.probability * 100).toStringAsFixed(1);
  final nights = history.usableNightCount == history.selectedNightCount
      ? history.selectedNightCount == 1
          ? '1 ausgewaehlte Nacht'
          : '${history.selectedNightCount} ausgewaehlte Naechte'
      : '${history.usableNightCount} von ${history.selectedNightCount} '
          'ausgewaehlten Naechten mit Positionsdaten';
  return 'Traeger-Schnarchwahrscheinlichkeit: $probability % | '
      '${_formatDurationSeconds(estimate.observedSeconds)} Positionszeit | '
      '$nights';
}

class _HomeConnectionCard extends StatelessWidget {
  const _HomeConnectionCard({
    required this.controller,
    required this.snapshot,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mg24 = snapshot.mg24;
    final running = snapshot.running;
    final measurementActive = controller.measurementActive;
    final boardRecording = controller.boardRecording;
    final connecting = controller.mg24Connecting ||
        mg24.scanning ||
        mg24.forehead.connecting ||
        mg24.belly.connecting;
    final disconnecting = controller.mg24Disconnecting;
    final needsMeasurementSensors =
        measurementActive || controller.hasPendingBoardArchiveRecovery;
    final canConnect = !controller.stopping &&
        !connecting &&
        !disconnecting &&
        (needsMeasurementSensors
            ? controller.missingMeasurementSensorLabels.isNotEmpty
            : !mg24.ready);
    final canDisconnect = !controller.stopping &&
        !disconnecting &&
        (mg24.connected || connecting);
    final canStart = !controller.stopping &&
        controller.canStartMg24Measurement &&
        !connecting &&
        !disconnecting;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  mg24.connected ? Icons.sensors : Icons.sensors_off,
                  color: mg24.connected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sensoren',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (measurementActive)
                  _InfoPill(
                    label: 'Messung',
                    value: running
                        ? 'laeuft'
                        : boardRecording
                            ? 'Board'
                            : 'aktiv',
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canConnect
                        ? () => controller.connectMg24Sensors()
                        : null,
                    icon: connecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(connecting ? 'Verbinde ...' : 'Verbinden'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canDisconnect
                        ? () => controller.disconnectMg24Sensors()
                        : null,
                    icon: Icon(connecting ? Icons.close : Icons.link_off),
                    label: Text(
                      connecting
                          ? 'Abbrechen'
                          : disconnecting
                              ? 'Trenne ...'
                              : 'Trennen',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (controller.hasPendingBoardArchiveRecovery)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: controller.canRecoverPendingBoardArchive
                      ? () => _recoverPendingBoardArchiveWithMorningQuestions(
                            context,
                            controller,
                          )
                      : null,
                  icon: controller.stopping
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                    controller.stopping
                        ? 'Archiv wird geladen ...'
                        : 'Messung ins Journal uebernehmen',
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: canStart
                          ? () => _startMeasurementWithEveningQuestions(
                                context,
                                controller,
                              )
                          : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Starten'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.canStopMeasurement
                          ? () => _stopMeasurementWithMorningQuestions(
                                context,
                                controller,
                              )
                          : null,
                      icon: controller.stopping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop),
                      label:
                          Text(controller.stopping ? 'Stoppt ...' : 'Stoppen'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            Text(
              mg24.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            if (controller.stopping ||
                controller.hasPendingBoardArchiveRecovery) ...[
              const SizedBox(height: 5),
              Text(
                snapshot.status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (needsMeasurementSensors &&
                controller.missingMeasurementSensorLabels.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                '${measurementActive ? 'Zum Stoppen' : 'Zum Laden'} verbinden: '
                '${controller.missingMeasurementSensorLabels.join(' + ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Mg24SensorPill(
                  label: 'Stirn',
                  sensor: mg24.forehead,
                  measurementExpected:
                      controller.isMeasurementSensor(Mg24SensorRole.forehead) &&
                          measurementActive,
                  activeSessionConfirmed:
                      controller.boardHasActiveMeasurementSession(
                          Mg24SensorRole.forehead),
                ),
                _Mg24SensorPill(
                  label: 'Bauch',
                  sensor: mg24.belly,
                  measurementExpected:
                      controller.isMeasurementSensor(Mg24SensorRole.belly) &&
                          measurementActive,
                  activeSessionConfirmed: controller
                      .boardHasActiveMeasurementSession(Mg24SensorRole.belly),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeLiveValues extends StatefulWidget {
  const _HomeLiveValues({required this.snapshot});

  final MeasurementSnapshot snapshot;

  @override
  State<_HomeLiveValues> createState() => _HomeLiveValuesState();
}

class _HomeLiveValuesState extends State<_HomeLiveValues> {
  static const _holdDuration = Duration(seconds: 25);
  static const _heartJumpThreshold = 18.0;
  static const _breathingJumpThreshold = 5.0;

  _StableHomeMetric _heartRate = const _StableHomeMetric.empty();
  _StableHomeMetric _breathingRate = const _StableHomeMetric.empty();

  @override
  void initState() {
    super.initState();
    _updateStableValues(widget.snapshot);
  }

  @override
  void didUpdateWidget(covariant _HomeLiveValues oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateStableValues(widget.snapshot);
  }

  void _updateStableValues(MeasurementSnapshot snapshot) {
    final mg24 = snapshot.mg24;
    _heartRate = _nextStableMetric(
      current: _heartRate,
      raw: snapshot.heartRate ?? mg24.heartRateBpm,
      sourceConnected: mg24.forehead.connected || snapshot.heartRate != null,
      minValue: 35,
      maxValue: 220,
      jumpThreshold: _heartJumpThreshold,
    );
    _breathingRate = _nextStableMetric(
      current: _breathingRate,
      raw: snapshot.breathingRate ?? mg24.breathingRatePerMin,
      sourceConnected: mg24.belly.connected || snapshot.breathingRate != null,
      minValue: 4,
      maxValue: 45,
      jumpThreshold: _breathingJumpThreshold,
    );
  }

  _StableHomeMetric _nextStableMetric({
    required _StableHomeMetric current,
    required double? raw,
    required bool sourceConnected,
    required double minValue,
    required double maxValue,
    required double jumpThreshold,
  }) {
    final now = DateTime.now();
    if (!sourceConnected) return const _StableHomeMetric.empty();
    if (raw != null && raw.isFinite && raw >= minValue && raw <= maxValue) {
      final previous = current.value;
      final previousAt = current.updatedAt;
      if (previous == null ||
          previousAt == null ||
          now.difference(previousAt) > _holdDuration) {
        return _StableHomeMetric(raw, now);
      }
      final delta = (raw - previous).abs();
      final weight = delta > jumpThreshold ? 0.55 : 0.30;
      return _StableHomeMetric(previous + (raw - previous) * weight, now);
    }
    final previousAt = current.updatedAt;
    if (current.value != null &&
        previousAt != null &&
        now.difference(previousAt) <= _holdDuration) {
      return current;
    }
    return const _StableHomeMetric.empty();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final mg24 = snapshot.mg24;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final width = wide
            ? (constraints.maxWidth - 10 * 3) / 4
            : math.max(150.0, (constraints.maxWidth - 10) / 2);
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            MetricTile(
              width: width,
              label: 'Herzfrequenz',
              value: _formatNumber(_heartRate.value, 0),
              unit: 'bpm',
            ),
            MetricTile(
              width: width,
              label: 'Atemfrequenz',
              value: _formatNumber(_breathingRate.value, 0),
              unit: '/min',
            ),
            MetricTile(
              width: width,
              label: 'Ohrtemperatur',
              value: _formatNumber(mg24.forehead.earTemperatureC, 2),
              unit: 'C',
            ),
            MetricTile(
              width: width,
              label: 'SpO2',
              value: _formatNumber(
                  snapshot.oxygenSaturation ?? mg24.spo2Percent, 0),
              unit: '%',
            ),
            MetricTile(
              width: width,
              label: 'Schnarchphase',
              value: _homeSnorePhaseValue(snapshot.snore),
              unit: _homeSnorePhaseUnit(snapshot.snore),
            ),
            MetricTile(
              width: width,
              label: 'Schnarchzug',
              value: _homeSnoreBreathValue(snapshot.snore),
              unit: _homeSnoreBreathUnit(snapshot.snore),
            ),
          ],
        );
      },
    );
  }
}

class _StableHomeMetric {
  const _StableHomeMetric(this.value, this.updatedAt);

  const _StableHomeMetric.empty()
      : value = null,
        updatedAt = null;

  final double? value;
  final DateTime? updatedAt;
}

class _MeasurementTab extends StatelessWidget {
  const _MeasurementTab({
    required this.controller,
    required this.snapshot,
    required this.scrollLocked,
    required this.onViewportInteractionChanged,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;
  final bool scrollLocked;
  final ValueChanged<bool> onViewportInteractionChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: scrollLocked
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        _Controls(controller: controller),
        const SizedBox(height: 10),
        const _DeveloperClockPanel(),
        const SizedBox(height: 10),
        _Mg24Panel(
          controller: controller,
          snapshot: snapshot,
          onBodyInteractionChanged: onViewportInteractionChanged,
        ),
        const SizedBox(height: 10),
        _StatusStrip(snapshot: snapshot),
        const SizedBox(height: 10),
        _SnorePositionGrid(snapshot: snapshot),
        const SizedBox(height: 12),
        _SnoreTimelinePanel(snapshot: snapshot),
        const SizedBox(height: 12),
        _CsvFilePanel(controller: controller, snapshot: snapshot),
      ],
    );
  }
}

class _JournalTab extends StatelessWidget {
  const _JournalTab({required this.controller});

  final MeasurementController controller;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const Material(
            color: Colors.transparent,
            child: TabBar(
              tabs: [
                Tab(icon: Icon(Icons.bedtime_outlined), text: 'Naechte'),
                Tab(icon: Icon(Icons.query_stats), text: 'Korrelationen'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  children: [
                    _SleepJournalPanel(controller: controller),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  children: [
                    _SleepJournalCorrelationSection(controller: controller),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
  });

  final MeasurementController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final measurementActive = controller.measurementActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.38),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.nightlight_round,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        measurementActive
                            ? 'Messung laeuft'
                            : 'XIAO-Messung bereit',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: !controller.canStartMg24Measurement
                          ? null
                          : () => _startMeasurementWithEveningQuestions(
                                context,
                                controller,
                              ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start'),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.canStopMeasurement
                          ? () => _stopMeasurementWithMorningQuestions(
                                context,
                                controller,
                              )
                          : null,
                      icon: controller.stopping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop),
                      label: Text(controller.stopping ? 'Stoppt ...' : 'Stop'),
                    ),
                    if (controller.hasPendingBoardArchiveRecovery)
                      FilledButton.icon(
                        onPressed: controller.canRecoverPendingBoardArchive
                            ? () =>
                                _recoverPendingBoardArchiveWithMorningQuestions(
                                  context,
                                  controller,
                                )
                            : null,
                        icon: const Icon(Icons.download),
                        label: const Text('Archiv ins Journal'),
                      ),
                    _ModeChip(
                      avatar: const _ZzzAvatar(),
                      label: 'Schnarchen',
                      selected: controller.snoreEnabled,
                      onTap: measurementActive
                          ? null
                          : () => controller
                              .setSnoreEnabled(!controller.snoreEnabled),
                    ),
                    _ModeChip(
                      avatar: const Icon(Icons.phone_android, size: 17),
                      label: 'YAMNet Messung',
                      selected: controller.yamnetMeasurementEnabled,
                      onTap: measurementActive
                          ? null
                          : () => unawaited(
                                controller.setYamnetMeasurementEnabled(
                                  !controller.yamnetMeasurementEnabled,
                                ),
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> _startMeasurementWithEveningQuestions(
  BuildContext context,
  MeasurementController controller,
) async {
  if (_measurementStartFlowActive || !controller.canStartMg24Measurement) {
    return;
  }
  _measurementStartFlowActive = true;
  try {
    final answers = await _showMeasurementQuestionnaire(
      context,
      title: 'Abendfragen',
      questions: controller.sleepQuestionsFor(SleepQuestionPhase.evening),
      initialAnswers:
          controller.latestSleepAnswersFor(SleepQuestionPhase.evening),
    );
    if (answers == null) return;
    if (!context.mounted || controller.measurementActive) return;
    controller.prepareSleepSession(answers);
    final scheduledCompleter = Completer<DateTime>();
    final armFuture = controller.armMg24Measurement(
      onScheduled: (scheduledAt) {
        if (!scheduledCompleter.isCompleted) {
          scheduledCompleter.complete(scheduledAt);
        }
      },
    );
    final scheduledAt = await Future.any<DateTime?>([
      scheduledCompleter.future.then<DateTime?>((value) => value),
      armFuture.then<DateTime?>((_) => null),
    ]);
    if (scheduledAt == null || !context.mounted) {
      final armed = await armFuture;
      if (armed || !context.mounted) return;
      if (context.mounted) {
        final message = controller.snapshot.status.trim().isEmpty
            ? 'Die Sensoren konnten nicht fuer die Messung vorbereitet werden.'
            : controller.snapshot.status;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    final countdownAbort = ValueNotifier<bool>(false);
    try {
      final countdownFuture = _showMeasurementStartCountdown(
        context,
        scheduledAt: scheduledAt,
        abortSignal: countdownAbort,
        signalEnabled: controller.measurementStartSignalEnabled,
        onSignalEnabledChanged: (enabled) {
          unawaited(controller.setMeasurementStartSignalEnabled(enabled));
        },
      );
      final armed = await armFuture;
      if (!armed) {
        countdownAbort.value = true;
        await countdownFuture;
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(controller.snapshot.status)));
        }
        return;
      }
      final shouldStart = await countdownFuture;
      if (!shouldStart) {
        await controller.cancelArmedMg24Measurement();
        return;
      }
      await controller.start(activateArmedMeasurement: true);
      if (!controller.running) return;
      await _playMeasurementStartCue(
        soundEnabled: controller.measurementStartSignalEnabled,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      controller.calibrateMg24PoseNow();
    } finally {
      countdownAbort.dispose();
    }
  } finally {
    _measurementStartFlowActive = false;
  }
}

Future<void> _stopMeasurementWithMorningQuestions(
  BuildContext context,
  MeasurementController controller,
) async {
  if (_measurementStopFlowActive ||
      controller.stopping ||
      !controller.canStopMeasurement) {
    return;
  }
  _measurementStopFlowActive = true;
  try {
    await controller.stop();
    if (controller.measurementActive ||
        !controller.sleepSessionReadyForJournal) {
      return;
    }
    final record = await controller.completeSleepSession(const <String, int>{});
    if (record == null || !context.mounted) return;
    final answers = await _showMeasurementQuestionnaire(
          context,
          title: 'Morgenfragen',
          questions: controller.sleepQuestionsFor(SleepQuestionPhase.morning),
          initialAnswers:
              controller.latestSleepAnswersFor(SleepQuestionPhase.morning),
        ) ??
        const <String, int>{};
    await controller.updateSleepSessionAnswers(record.id, answers);
  } finally {
    _measurementStopFlowActive = false;
  }
}

Future<void> _recoverPendingBoardArchiveWithMorningQuestions(
  BuildContext context,
  MeasurementController controller,
) async {
  if (_measurementStopFlowActive ||
      controller.stopping ||
      !controller.canRecoverPendingBoardArchive) {
    return;
  }
  _measurementStopFlowActive = true;
  try {
    final recovered = await controller.recoverPendingBoardArchive();
    if (!recovered) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(controller.snapshot.status)));
      }
      return;
    }
    if (!controller.sleepSessionReadyForJournal) return;
    final record = await controller.completeSleepSession(const <String, int>{});
    if (record == null || !context.mounted) return;
    final answers = await _showMeasurementQuestionnaire(
          context,
          title: 'Morgenfragen',
          questions: controller.sleepQuestionsFor(SleepQuestionPhase.morning),
          initialAnswers:
              controller.latestSleepAnswersFor(SleepQuestionPhase.morning),
        ) ??
        const <String, int>{};
    await controller.updateSleepSessionAnswers(record.id, answers);
  } finally {
    _measurementStopFlowActive = false;
  }
}

bool _measurementStartFlowActive = false;
bool _measurementStopFlowActive = false;

Future<Map<String, int>?> _showMeasurementQuestionnaire(
  BuildContext context, {
  required String title,
  required List<SleepQuestion> questions,
  Map<String, int> initialAnswers = const <String, int>{},
}) async {
  if (questions.isEmpty) return const {};
  final questionIds = questions.map((question) => question.id).toSet();
  final answers = <String, int>{
    for (final entry in initialAnswers.entries)
      if (questionIds.contains(entry.key)) entry.key: entry.value,
  };

  return showModalBottomSheet<Map<String, int>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          final bottom = MediaQuery.viewInsetsOf(context).bottom;

          return SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8 + bottom),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.86,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child:
                              Text(title, style: theme.textTheme.titleMedium),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: questions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final question = questions[index];
                          return _QuestionAnswerCard(
                            question: question,
                            value: answers[question.id],
                            onChanged: (value) {
                              setSheetState(() {
                                if (value == null) {
                                  answers.remove(question.id);
                                } else {
                                  answers[question.id] = value;
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(
                            const <String, int>{},
                          ),
                          icon: const Icon(Icons.skip_next),
                          label: const Text('Ueberspringen'),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: () => Navigator.of(context).pop(answers),
                          icon: const Icon(Icons.check),
                          label: const Text('Weiter'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Future<bool> _showMeasurementStartCountdown(
  BuildContext context, {
  required DateTime scheduledAt,
  required ValueNotifier<bool> abortSignal,
  bool signalEnabled = true,
  ValueChanged<bool>? onSignalEnabledChanged,
}) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MeasurementStartCountdownDialog(
          scheduledAt: scheduledAt,
          abortSignal: abortSignal,
          signalEnabled: signalEnabled,
          onSignalEnabledChanged: onSignalEnabledChanged,
        ),
      ) ??
      false;
}

@visibleForTesting
Future<bool> measurementStartCountdownForTest(
  BuildContext context, {
  required DateTime scheduledAt,
  required ValueNotifier<bool> abortSignal,
  bool signalEnabled = true,
  ValueChanged<bool>? onSignalEnabledChanged,
}) {
  return _showMeasurementStartCountdown(
    context,
    scheduledAt: scheduledAt,
    abortSignal: abortSignal,
    signalEnabled: signalEnabled,
    onSignalEnabledChanged: onSignalEnabledChanged,
  );
}

class _MeasurementStartCountdownDialog extends StatefulWidget {
  const _MeasurementStartCountdownDialog({
    required this.scheduledAt,
    required this.abortSignal,
    required this.signalEnabled,
    required this.onSignalEnabledChanged,
  });

  final DateTime scheduledAt;
  final ValueNotifier<bool> abortSignal;
  final bool signalEnabled;
  final ValueChanged<bool>? onSignalEnabledChanged;

  @override
  State<_MeasurementStartCountdownDialog> createState() =>
      _MeasurementStartCountdownDialogState();
}

class _MeasurementStartCountdownDialogState
    extends State<_MeasurementStartCountdownDialog> {
  Timer? _timer;
  late int _remainingSeconds;
  bool _finished = false;
  late bool _signalEnabled;

  int _secondsUntilStart() => math.max(
        0,
        (widget.scheduledAt.difference(DateTime.now()).inMilliseconds / 1000)
            .ceil(),
      );

  @override
  void initState() {
    super.initState();
    _remainingSeconds = _secondsUntilStart();
    _signalEnabled = widget.signalEnabled;
    widget.abortSignal.addListener(_handleAbort);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  void _handleAbort() {
    if (widget.abortSignal.value) _finish(false);
  }

  void _tick() {
    if (!mounted || _finished) return;
    if (widget.abortSignal.value) {
      _finish(false);
      return;
    }
    final remaining = _secondsUntilStart();
    if (remaining <= 0) {
      _finish(true);
      return;
    }
    if (remaining != _remainingSeconds) {
      setState(() => _remainingSeconds = remaining);
    }
  }

  void _finish(bool shouldStart) {
    if (!mounted || _finished) return;
    _finished = true;
    _timer?.cancel();
    Navigator.of(context).pop(shouldStart);
  }

  @override
  void dispose() {
    widget.abortSignal.removeListener(_handleAbort);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Messung startet in 30 s'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _remainingSeconds.toString(),
              style: theme.textTheme.displayLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bitte Sensoren anlegen und gerade ohne Kissen auf den Ruecken legen. '
              '${_signalEnabled ? 'Nach dem Signalton' : 'Nach Ablauf des Countdowns'} startet die Messung.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              secondary: Icon(
                _signalEnabled ? Icons.volume_up : Icons.volume_off,
              ),
              title: const Text('Signalton'),
              value: _signalEnabled,
              onChanged: (enabled) {
                setState(() => _signalEnabled = enabled);
                widget.onSignalEnabledChanged?.call(enabled);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _finish(false),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
  }
}

Future<void> _playMeasurementStartCue({required bool soundEnabled}) async {
  // The native alarm stream remains audible when the phone's notification
  // sound is muted. It does not change the user's volume settings.
  if (soundEnabled) {
    try {
      await _measurementAudioChannel.invokeMethod<void>(
        'playMeasurementStartTone',
      );
    } catch (_) {}
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }
  try {
    await HapticFeedback.heavyImpact();
  } catch (_) {}
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.avatar,
  });

  final Widget avatar;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final iconColor = theme.colorScheme.primary.withValues(
      alpha: enabled ? 1 : 0.48,
    );
    final textColor = theme.colorScheme.onSurface.withValues(
      alpha: enabled ? 1 : 0.48,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? _selectedChipColor : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Center(
                    child: IconTheme.merge(
                  data: IconThemeData(size: 18, color: iconColor),
                  child: avatar,
                )),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(color: textColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZzzAvatar extends StatelessWidget {
  const _ZzzAvatar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 22,
      child: Text(
        'Zz',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.snapshot});

  final MeasurementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            snapshot.status,
            style: textTheme.bodyMedium,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            snapshot.fileLabel,
            textAlign: TextAlign.end,
            style: textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _DeveloperClockPanel extends StatefulWidget {
  const _DeveloperClockPanel();

  @override
  State<_DeveloperClockPanel> createState() => _DeveloperClockPanelState();
}

class _DeveloperClockPanelState extends State<_DeveloperClockPanel> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = _secondsOfDay(_now);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('Uhrzeit', style: theme.textTheme.labelLarge),
          const Spacer(),
          Text(
            '${_formatClockTime(_now)} | $seconds s',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionAnswerCard extends StatelessWidget {
  const _QuestionAnswerCard({
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final SleepQuestion question;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(question.prompt, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 10),
          if (question.type == SleepQuestionType.scale) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '1 = ${question.lowLabel ?? 'niedrig'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    '5 = ${question.highLabel ?? 'hoch'}',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: List.generate(5, (index) {
                final next = index + 1;
                return ChoiceChip(
                  label: Text(next.toString()),
                  selected: value == next,
                  onSelected: (selected) => onChanged(selected ? next : null),
                );
              }),
            ),
          ] else
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Nein'),
                  selected: value == 0,
                  onSelected: (selected) => onChanged(selected ? 0 : null),
                ),
                ChoiceChip(
                  label: const Text('Ja'),
                  selected: value == 1,
                  onSelected: (selected) => onChanged(selected ? 1 : null),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SleepJournalPanel extends StatefulWidget {
  const _SleepJournalPanel({required this.controller});

  final MeasurementController controller;

  @override
  State<_SleepJournalPanel> createState() => _SleepJournalPanelState();
}

class _SleepJournalPanelState extends State<_SleepJournalPanel> {
  int _selectedIndex = 0;
  String? _deletingId;

  Future<void> _confirmDelete(SleepSessionRecord record) async {
    if (_deletingId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Schlafmessung loeschen?'),
        content: Text(
          'Die Messung vom ${_formatDate(record.metrics.startedAt)} und ihre '
          'lokalen Messdateien werden dauerhaft geloescht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Loeschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingId = record.id);
    final deleted = await widget.controller.deleteSleepSession(record);
    if (!mounted) return;
    setState(() {
      _deletingId = null;
      _selectedIndex = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted
              ? 'Schlafmessung geloescht.'
              : 'Schlafmessung wurde nicht gefunden.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final records = controller.sleepHistory;
    if (_selectedIndex >= records.length) _selectedIndex = 0;
    final selected = records.isEmpty ? null : records[_selectedIndex];
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selected == null)
                  Text(
                    'Noch kein gespeicherter Schlafzyklus.',
                    style: theme.textTheme.bodyMedium,
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: _SleepSessionSelector(
                          records: records,
                          selectedIndex: _selectedIndex,
                          onChanged: (index) => setState(() {
                            _selectedIndex = index;
                          }),
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        tooltip: 'Schlafjournal teilen',
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(3),
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: controller.shareSleepSessionsCsv,
                        icon: const Icon(Icons.ios_share, size: 22),
                      ),
                      IconButton(
                        tooltip: 'Schlafmessung loeschen',
                        color: theme.colorScheme.error,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(3),
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: _deletingId == null
                            ? () => _confirmDelete(selected)
                            : null,
                        icon: _deletingId == selected.id
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_outline, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SleepSessionSeriesPanel(
                    controller: controller,
                    record: selected,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SleepSessionSelector extends StatelessWidget {
  const _SleepSessionSelector({
    required this.records,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<SleepSessionRecord> records;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropdownButtonFormField<int>(
      initialValue: selectedIndex,
      isExpanded: true,
      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15.5),
      decoration: const InputDecoration(
        labelText: 'Schlafzyklus',
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.fromLTRB(12, 12, 4, 12),
      ),
      items: [
        for (var i = 0; i < records.length; i++)
          DropdownMenuItem<int>(
            value: i,
            child: Text(
              '${_formatCalendarDate(records[i].metrics.startedAt)} | '
              '${_formatClockTime(records[i].metrics.startedAt).substring(0, 5)} - '
              '${_formatClockTime(records[i].metrics.endedAt).substring(0, 5)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      selectedItemBuilder: (context) => [
        for (final record in records)
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${_formatCalendarDate(record.metrics.startedAt)} | '
                '${_formatClockTime(record.metrics.startedAt).substring(0, 5)} - '
                '${_formatClockTime(record.metrics.endedAt).substring(0, 5)}',
                maxLines: 1,
              ),
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class _SleepSessionSummaryGrid extends StatelessWidget {
  const _SleepSessionSummaryGrid({
    required this.record,
    this.series,
  });

  final SleepSessionRecord record;
  final List<SleepSessionSeriesPoint>? series;

  @override
  Widget build(BuildContext context) {
    final metrics = record.metrics;
    final meanHeartRate = _meanSeriesValue((point) => point.heartRateBpm) ??
        metrics.meanHeartRateBpm;
    final meanBreathingRate =
        _meanSeriesValue((point) => point.breathingRatePerMin) ??
            metrics.meanBreathingRatePerMin;
    final snoreFraction = metrics.snoreTimeFraction;
    double? fallbackSnoreSeconds;
    if (snoreFraction != null) {
      fallbackSnoreSeconds = metrics.durationSeconds * snoreFraction;
    }
    final rawSnoreSeconds =
        _sumSeriesValue((point) => point.snoreSeconds) ?? fallbackSnoreSeconds;
    final snoreSeconds =
        rawSnoreSeconds?.clamp(0.0, metrics.durationSeconds).toDouble();
    final meanEarTemperature = _meanSeriesValue(
          (point) => point.earTemperatureC,
          min: 30,
          max: 42,
        ) ??
        metrics.meanEarTemperatureC;
    final displayedSnoreFraction = snoreSeconds == null ||
            !metrics.durationSeconds.isFinite ||
            metrics.durationSeconds <= 0
        ? snoreFraction
        : (snoreSeconds / metrics.durationSeconds).clamp(0.0, 1.0).toDouble();
    final scores = computeSleepMetricScores(
      meanHeartRateBpm: meanHeartRate,
      meanBreathingRatePerMin: meanBreathingRate,
      snoreTimeFraction: displayedSnoreFraction,
      meanEarTemperatureC: meanEarTemperature,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 760
            ? (constraints.maxWidth - 10 * 3) / 4
            : math.max(150.0, (constraints.maxWidth - 10) / 2);
        return Column(
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                MetricTile(
                  width: width,
                  label: 'Mittlere Herzfrequenz',
                  value: _formatNumber(meanHeartRate, 1),
                  unit: 'bpm',
                  showScore: true,
                  score: scores.heartRateScore,
                ),
                MetricTile(
                  width: width,
                  label: 'Mittlere Atemfrequenz',
                  value: _formatNumber(meanBreathingRate, 0),
                  unit: '/min',
                  showScore: true,
                  score: scores.breathingRateScore,
                ),
                MetricTile(
                  width: width,
                  label: 'Schnarchzeit',
                  value: snoreSeconds == null
                      ? '--'
                      : _formatDurationSeconds(snoreSeconds),
                  unit: '',
                  showScore: true,
                  score: scores.snoreScore,
                ),
                MetricTile(
                  width: width,
                  label: 'Mittlere Ohrtemp',
                  value: _formatNumber(meanEarTemperature, 2),
                  unit: 'C',
                  showScore: true,
                  score: scores.temperatureScore,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SleepOverallScore(score: scores.overallScore),
          ],
        );
      },
    );
  }

  double? _meanSeriesValue(
    double? Function(SleepSessionSeriesPoint point) valueFor, {
    double? min,
    double? max,
  }) {
    final points = series;
    if (points == null || points.isEmpty) return null;
    var sum = 0.0;
    var count = 0;
    for (final point in points) {
      final value = valueFor(point);
      if (value != null &&
          value.isFinite &&
          (min == null || value >= min) &&
          (max == null || value <= max)) {
        sum += value;
        count++;
      }
    }
    return count == 0 ? null : sum / count;
  }

  double? _sumSeriesValue(
    double? Function(SleepSessionSeriesPoint point) valueFor,
  ) {
    final points = series;
    if (points == null || points.isEmpty) return null;
    var sum = 0.0;
    var count = 0;
    for (final point in points) {
      final value = valueFor(point);
      if (value != null && value.isFinite) {
        sum += value;
        count++;
      }
    }
    return count == 0 ? null : sum;
  }
}

class _SleepSessionSeriesPanel extends StatefulWidget {
  const _SleepSessionSeriesPanel({
    required this.controller,
    required this.record,
  });

  final MeasurementController controller;
  final SleepSessionRecord record;

  @override
  State<_SleepSessionSeriesPanel> createState() =>
      _SleepSessionSeriesPanelState();
}

class _SleepSessionSeriesPanelState extends State<_SleepSessionSeriesPanel> {
  final ValueNotifier<int> _selectedPointIndex = ValueNotifier<int>(0);
  final ValueNotifier<DateTime?> _selectedChartTime =
      ValueNotifier<DateTime?>(null);
  late Future<List<SleepSessionSeriesPoint>> _seriesFuture;

  @override
  void initState() {
    super.initState();
    _seriesFuture = widget.controller.loadSleepSessionSeries(widget.record);
  }

  @override
  void didUpdateWidget(covariant _SleepSessionSeriesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id) {
      _selectedPointIndex.value = 0;
      _selectedChartTime.value = null;
      _seriesFuture = widget.controller.loadSleepSessionSeries(widget.record);
    }
  }

  @override
  void dispose() {
    _selectedPointIndex.dispose();
    _selectedChartTime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SleepSessionSeriesPoint>>(
      future: _seriesFuture,
      builder: (context, snapshot) {
        final series = snapshot.data ?? const <SleepSessionSeriesPoint>[];
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (series.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SleepSessionSummaryGrid(record: widget.record),
              const SizedBox(height: 10),
              Text(
                'Fuer diesen Schlafzyklus wurde keine Zeitreihe gefunden.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        }
        final movementByTime = _sleepMovementByTime(series);
        final basalTemperature =
            _estimateBasalTemperature(series, movementByTime);
        final usesYamnetSnoreSeries = series.any(
          (point) =>
              point.yamnetSnoreSeconds != null ||
              point.yamnetSnoreWindowCount != null,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SleepSessionSummaryGrid(record: widget.record, series: series),
            const SizedBox(height: 10),
            _BasalTemperatureCard(estimate: basalTemperature),
            const SizedBox(height: 12),
            _SleepMetricChart(
              title: 'Herzfrequenz',
              unit: 'bpm',
              color: const Color(0xFFFF6B6B),
              series: series,
              valueFor: (point) => point.heartRateBpm,
              valueDigits: 0,
              selectedTimeListenable: _selectedChartTime,
              onSelectedTimeChanged: (time) => _selectChartTime(time, series),
            ),
            const SizedBox(height: 10),
            _SleepMetricChart(
              title: 'Atemfrequenz',
              unit: '/min',
              color: const Color(0xFF5EE0B5),
              series: series,
              valueFor: (point) => point.breathingRatePerMin,
              valueDigits: 0,
              selectedTimeListenable: _selectedChartTime,
              onSelectedTimeChanged: (time) => _selectChartTime(time, series),
            ),
            const SizedBox(height: 10),
            _SleepMetricChart(
              title: usesYamnetSnoreSeries
                  ? 'Schnarchzuege (YAMNet Handy)'
                  : 'Schnarchzuege',
              unit: '/min',
              color: _snoreWearerColor,
              series: series,
              valueFor: (point) => point.snoreWindowCount ?? 0.0,
              valueDigits: 0,
              colorFor: (point) => _snoreSourceColor(point.snoreSource),
              legendItems: [
                const _SleepChartLegendItem(
                  label: 'Traeger',
                  color: _snoreWearerColor,
                ),
                const _SleepChartLegendItem(
                  label: 'Andere',
                  color: _snoreExternalColor,
                ),
                const _SleepChartLegendItem(
                  label: 'Unbekannt',
                  color: _snoreUnknownColor,
                ),
              ],
              minY: 0,
              selectedTimeListenable: _selectedChartTime,
              onSelectedTimeChanged: (time) => _selectChartTime(time, series),
            ),
            const SizedBox(height: 10),
            _SleepMetricChart(
              title: 'Ohrtemperatur',
              unit: 'C',
              color: const Color(0xFF7AA7FF),
              series: series,
              valueFor: (point) => point.earTemperatureC,
              valueDigits: 2,
              selectedTimeListenable: _selectedChartTime,
              onSelectedTimeChanged: (time) => _selectChartTime(time, series),
            ),
            const SizedBox(height: 10),
            _SleepMetricChart(
              title: 'Bewegung',
              unit: 'deg/10min',
              color: const Color(0xFFA6E36F),
              series: series,
              valueFor: (point) => movementByTime[point.time],
              valueDigits: 0,
              minY: 0,
              selectedTimeListenable: _selectedChartTime,
              onSelectedTimeChanged: (time) => _selectChartTime(time, series),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
              valueListenable: _selectedPointIndex,
              builder: (context, rawIndex, _) {
                final index = rawIndex.clamp(0, series.length - 1).toInt();
                final selected = series[index];
                final selectedMg24 = _mg24StateFromSeriesPoint(selected);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Schlafposition',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Slider(
                      value: index.toDouble(),
                      min: 0,
                      max: math.max(0, series.length - 1).toDouble(),
                      divisions: series.length > 1 ? series.length - 1 : null,
                      label: _formatClockTime(selected.time),
                      onChanged: (value) {
                        final nextIndex = value.round();
                        _publishChartSelection(nextIndex, series);
                      },
                    ),
                    Text(
                      _formatClockTime(selected.time),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (selected.hasAnyPose)
                      _SelectedNightsPoseOverview(
                        controller: widget.controller,
                        mg24: selectedMg24,
                        relativeYawDeg: _relativeYawFromSeriesPoint(selected),
                        onResetPose: null,
                        onBodyInteractionChanged: (_) {},
                      )
                    else
                      Text(
                        'Fuer diesen Zeitpunkt liegen keine Positionsdaten vor.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }

  void _selectChartTime(
    DateTime time,
    List<SleepSessionSeriesPoint> series,
  ) {
    var low = 0;
    var high = series.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (series[middle].time.isBefore(time)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var nearestIndex = low;
    if (nearestIndex > 0) {
      final before = series[nearestIndex - 1].time.difference(time).abs();
      final after = series[nearestIndex].time.difference(time).abs();
      if (before <= after) nearestIndex--;
    }
    _publishChartSelection(nearestIndex, series);
  }

  void _publishChartSelection(
    int rawIndex,
    List<SleepSessionSeriesPoint> series,
  ) {
    final index = rawIndex.clamp(0, series.length - 1).toInt();
    final time = series[index].time;
    if (_selectedPointIndex.value != index) {
      _selectedPointIndex.value = index;
    }
    if (_selectedChartTime.value != time) {
      _selectedChartTime.value = time;
    }
  }

  Mg24State _mg24StateFromSeriesPoint(SleepSessionSeriesPoint point) {
    final head = const Mg24SensorSummary.empty().copyWith(
      connected: point.hasForeheadPose,
      lastUpdate: point.time,
      rollDeg: point.foreheadRollDeg,
      pitchDeg: point.foreheadPitchDeg,
      yawDeg: point.foreheadYawDeg,
      angleDeg: point.foreheadRollDeg,
    );
    final belly = const Mg24SensorSummary.empty().copyWith(
      connected: point.hasBellyPose,
      lastUpdate: point.time,
      rollDeg: point.bellyRollDeg,
      pitchDeg: point.bellyPitchDeg,
      yawDeg: point.bellyYawDeg,
      angleDeg: point.bellyRollDeg,
    );
    return const Mg24State.empty().copyWith(
      status: 'Archiv',
      forehead: head,
      belly: belly,
    );
  }

  double? _relativeYawFromSeriesPoint(SleepSessionSeriesPoint point) {
    final headYaw = point.foreheadYawDeg;
    final bellyYaw = point.bellyYawDeg;
    if (headYaw == null ||
        bellyYaw == null ||
        !headYaw.isFinite ||
        !bellyYaw.isFinite) {
      return null;
    }
    return 0;
  }
}

class _BasalTemperatureCard extends StatelessWidget {
  const _BasalTemperatureCard({required this.estimate});

  final _BasalTemperatureEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = estimate.temperatureC != null;
    final quality = estimate.qualityPercent;
    final qualityText =
        quality == null ? '--' : '${quality.toStringAsFixed(0)}%';
    final timeText = estimate.start == null || estimate.end == null
        ? null
        : '${_formatClockTime(estimate.start!).substring(0, 5)} - '
            '${_formatClockTime(estimate.end!).substring(0, 5)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: available
              ? theme.colorScheme.primary.withValues(alpha: 0.38)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.thermostat,
            color: available
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Basaltemperatur', style: theme.textTheme.labelLarge),
                const SizedBox(height: 3),
                Text(
                  available
                      ? '${_formatNumber(estimate.temperatureC, 2)} C | Zuverlaessigkeit $qualityText'
                      : 'nicht sicher bestimmbar',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (timeText != null) timeText,
                    estimate.reason,
                  ].where((part) => part.isNotEmpty).join(' | '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BasalTemperatureEstimate {
  const _BasalTemperatureEstimate({
    required this.temperatureC,
    required this.qualityPercent,
    required this.start,
    required this.end,
    required this.reason,
  });

  final double? temperatureC;
  final double? qualityPercent;
  final DateTime? start;
  final DateTime? end;
  final String reason;

  const _BasalTemperatureEstimate.unavailable(this.reason)
      : temperatureC = null,
        qualityPercent = null,
        start = null,
        end = null;
}

class _BasalWindowCandidate {
  const _BasalWindowCandidate({
    required this.temperatureC,
    required this.qualityPercent,
    required this.start,
    required this.end,
    required this.tempStdC,
    this.movementDeg,
  });

  final double temperatureC;
  final double qualityPercent;
  final DateTime start;
  final DateTime end;
  final double tempStdC;
  final double? movementDeg;
}

class _SleepMovementIncrement {
  const _SleepMovementIncrement({
    required this.time,
    required this.degrees,
  });

  final DateTime time;
  final double degrees;
}

Map<DateTime, double> _sleepMovementByTime(
  List<SleepSessionSeriesPoint> series, {
  Duration window = const Duration(minutes: 10),
}) {
  final result = <DateTime, double>{};
  if (series.length < 2) return result;
  final increments = <_SleepMovementIncrement>[];
  for (var i = 1; i < series.length; i++) {
    final previous = series[i - 1];
    final current = series[i];
    final minutes =
        current.time.difference(previous.time).inMilliseconds.abs() / 60000.0;
    if (minutes <= 0 || minutes > 4) continue;
    final delta = _sleepPoseStepDegrees(previous, current);
    if (delta == null) continue;
    increments.add(
      _SleepMovementIncrement(
        time: current.time,
        degrees: delta.clamp(0.0, 90.0).toDouble(),
      ),
    );
  }
  var firstIncrement = 0;
  for (final point in series) {
    while (firstIncrement < increments.length &&
        point.time.difference(increments[firstIncrement].time) > window) {
      firstIncrement++;
    }
    var sum = 0.0;
    var count = 0;
    for (var i = firstIncrement; i < increments.length; i++) {
      final increment = increments[i];
      if (increment.time.isAfter(point.time)) break;
      sum += increment.degrees;
      count++;
    }
    if (count > 0) {
      result[point.time] = sum;
    }
  }
  return result;
}

double? _sleepPoseStepDegrees(
  SleepSessionSeriesPoint previous,
  SleepSessionSeriesPoint current,
) {
  final deltas = <double>[];
  void add(double? value) {
    if (value != null && value.isFinite) deltas.add(value);
  }

  add(_sleepAngleDeltaDeg(previous.foreheadRollDeg, current.foreheadRollDeg));
  add(_sleepAngleDeltaDeg(previous.foreheadPitchDeg, current.foreheadPitchDeg));
  add(_sleepAngleDeltaDeg(previous.bellyRollDeg, current.bellyRollDeg));
  add(_sleepAngleDeltaDeg(previous.bellyPitchDeg, current.bellyPitchDeg));
  if (deltas.length < 2) return null;
  final sumSquares = deltas.fold<double>(
    0,
    (sum, value) => sum + value * value,
  );
  return math.sqrt(sumSquares / deltas.length);
}

double? _sleepAngleDeltaDeg(double? a, double? b) {
  if (a == null || b == null || !a.isFinite || !b.isFinite) return null;
  var delta = (a - b).abs() % 360.0;
  if (delta > 180) delta = 360.0 - delta;
  return delta;
}

_BasalTemperatureEstimate _estimateBasalTemperature(
  List<SleepSessionSeriesPoint> series,
  Map<DateTime, double> movementByTime,
) {
  const minimumWindowMinutes = 20;
  const preferredWindowMinutes = 60;
  if (series.length < 12 ||
      series.last.time.difference(series.first.time).inMinutes <
          minimumWindowMinutes - 1) {
    return const _BasalTemperatureEstimate.unavailable(
      'zu wenige Zeitpunkte fuer ein ruhiges 20-Minuten-Fenster',
    );
  }
  final heartReference = _sleepPercentile(
    _sleepValues(
      series,
      (point) => point.heartRateBpm,
      min: 35,
      max: 125,
    ),
    0.35,
  );
  final breathingReference = _sleepPercentile(
    _sleepValues(
      series,
      (point) => point.breathingRatePerMin,
      min: 4,
      max: 36,
    ),
    0.35,
  );

  _BasalWindowCandidate? best;
  for (var start = 0; start < series.length; start++) {
    for (var end = start; end < series.length; end++) {
      final durationMinutes =
          series[end].time.difference(series[start].time).inMinutes + 1;
      if (durationMinutes < minimumWindowMinutes) continue;
      if (durationMinutes > 120) break;
      if ((durationMinutes - minimumWindowMinutes) % 5 != 0 &&
          end != series.length - 1) {
        continue;
      }
      final candidate = _basalCandidateForWindow(
        series.sublist(start, end + 1),
        movementByTime,
        heartReference: heartReference,
        breathingReference: breathingReference,
      );
      if (candidate == null) continue;
      if (best == null || candidate.qualityPercent > best.qualityPercent) {
        best = candidate;
      }
    }
  }

  if (best == null) {
    return const _BasalTemperatureEstimate.unavailable(
      'kein ausreichend stabiles 20-Minuten-Fenster mit genuegend Temperaturwerten',
    );
  }
  final quality = best.qualityPercent.clamp(0.0, 100.0).toDouble();
  final durationMinutes = best.end.difference(best.start).inMinutes + 1;
  final movementText = best.movementDeg == null
      ? 'Bewegung --'
      : 'Bewegung ${best.movementDeg!.toStringAsFixed(0)} deg/10min';
  final durationText = durationMinutes >= preferredWindowMinutes
      ? '$durationMinutes min stabil'
      : '$durationMinutes min stabil (kurzes Fenster)';
  final reason = '$durationText, Temp-SD '
      '${best.tempStdC.toStringAsFixed(2)} C, $movementText';
  return _BasalTemperatureEstimate(
    temperatureC: best.temperatureC,
    qualityPercent: quality,
    start: best.start,
    end: best.end,
    reason: reason,
  );
}

_BasalWindowCandidate? _basalCandidateForWindow(
  List<SleepSessionSeriesPoint> window,
  Map<DateTime, double> movementByTime, {
  required double? heartReference,
  required double? breathingReference,
}) {
  final durationMinutes =
      window.last.time.difference(window.first.time).inMinutes + 1;
  if (durationMinutes < 20 || window.length < 12) return null;
  final tempValues = _sleepValues(
    window,
    (point) => point.earTemperatureC,
    min: 30,
    max: 42,
  );
  final requiredSamples = math.max(12, durationMinutes * 0.50).round();
  if (tempValues.length < requiredSamples) return null;
  final heartValues = _sleepValues(
    window,
    (point) => point.heartRateBpm,
    min: 35,
    max: 125,
  );
  final breathingValues = _sleepValues(
    window,
    (point) => point.breathingRatePerMin,
    min: 4,
    max: 36,
  );
  final hasEnoughHeart =
      heartValues.length >= math.max(6, durationMinutes * 0.25);
  final hasEnoughBreathing =
      breathingValues.length >= math.max(6, durationMinutes * 0.25);
  final movementValues = <double>[
    for (final point in window)
      if (movementByTime[point.time] case final value?)
        if (value.isFinite) value,
  ];
  final hasEnoughMovement =
      movementValues.length >= math.max(4, durationMinutes * 0.20);

  final robustTempValues = _sleepTrimmedValues(tempValues, 0.10);
  final tempMean = _sleepMean(robustTempValues);
  final tempStd = _sleepStd(robustTempValues, tempMean);
  final tempRange =
      robustTempValues.reduce(math.max) - robustTempValues.reduce(math.min);
  final heartMean = hasEnoughHeart ? _sleepMean(heartValues) : null;
  final heartStd = hasEnoughHeart ? _sleepStd(heartValues, heartMean!) : null;
  final breathingMean = hasEnoughBreathing ? _sleepMean(breathingValues) : null;
  final breathingStd =
      hasEnoughBreathing ? _sleepStd(breathingValues, breathingMean!) : null;
  final movementMean = hasEnoughMovement ? _sleepMean(movementValues) : null;
  final qualityValues = <double>[
    ..._sleepValues(
      window,
      (point) => point.ppgQualityPercent,
      min: 0,
      max: 100,
    ),
    ..._sleepValues(
      window,
      (point) => point.breathingQualityPercent,
      min: 0,
      max: 100,
    ),
  ];
  final sensorQuality = qualityValues.isEmpty
      ? 0.72
      : _sleepScoreHigher(_sleepMean(qualityValues), ideal: 75, limit: 35);

  final tempScore = 0.65 *
          _sleepScoreLower(
            tempStd,
            ideal: 0.04,
            limit: 0.18,
          ) +
      0.35 *
          _sleepScoreLower(
            tempRange,
            ideal: 0.15,
            limit: 0.50,
          );
  final heartScore = !hasEnoughHeart
      ? 0.55
      : () {
          final heartLowScore = heartReference == null
              ? 0.68
              : _sleepScoreLower(
                  heartMean! - heartReference,
                  ideal: 1.0,
                  limit: 8.0,
                );
          return 0.52 * heartLowScore +
              0.48 * _sleepScoreLower(heartStd!, ideal: 1.8, limit: 6.5);
        }();
  final breathingScore = !hasEnoughBreathing
      ? 0.62
      : () {
          final breathingLowScore = breathingReference == null
              ? 0.68
              : _sleepScoreLower(
                  breathingMean! - breathingReference,
                  ideal: 0.8,
                  limit: 5.0,
                );
          return 0.50 * breathingLowScore +
              0.50 * _sleepScoreLower(breathingStd!, ideal: 0.9, limit: 4.0);
        }();
  final movementScore = movementMean == null
      ? 0.52
      : _sleepScoreLower(movementMean, ideal: 3.0, limit: 20.0);
  final coverageScore =
      (tempValues.length / durationMinutes).clamp(0.0, 1.0).toDouble();
  final durationScore = _sleepScoreHigher(
    durationMinutes.toDouble(),
    ideal: 60,
    limit: 20,
  );
  final quality = 100.0 *
      (0.34 * tempScore +
          0.15 * heartScore +
          0.12 * breathingScore +
          0.17 * movementScore +
          0.08 * coverageScore +
          0.06 * sensorQuality +
          0.08 * durationScore);
  if (quality < 35 ||
      tempStd > 0.22 ||
      tempRange > 0.65 ||
      (movementMean != null && movementMean > 22)) {
    return null;
  }
  return _BasalWindowCandidate(
    temperatureC: tempMean,
    qualityPercent: quality,
    start: window.first.time,
    end: window.last.time,
    tempStdC: tempStd,
    movementDeg: movementMean,
  );
}

List<double> _sleepTrimmedValues(List<double> values, double fraction) {
  if (values.length < 10 || fraction <= 0) return [...values];
  final sorted = [...values]..sort();
  final trim = (sorted.length * fraction.clamp(0.0, 0.25)).floor();
  if (trim <= 0 || trim * 2 >= sorted.length - 2) return sorted;
  return sorted.sublist(trim, sorted.length - trim);
}

List<double> _sleepValues(
  List<SleepSessionSeriesPoint> points,
  double? Function(SleepSessionSeriesPoint point) valueFor, {
  required double min,
  required double max,
}) {
  return [
    for (final point in points)
      if (valueFor(point) case final value?)
        if (value.isFinite && value >= min && value <= max) value,
  ];
}

double? _sleepPercentile(List<double> values, double fraction) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final index = ((sorted.length - 1) * fraction.clamp(0.0, 1.0)).round();
  return sorted[index.clamp(0, sorted.length - 1)];
}

double _sleepMean(List<double> values) {
  if (values.isEmpty) return 0;
  return values.fold<double>(0, (sum, value) => sum + value) / values.length;
}

double _sleepStd(List<double> values, double mean) {
  if (values.length < 2) return 0;
  final variance = values.fold<double>(
        0,
        (sum, value) => sum + math.pow(value - mean, 2),
      ) /
      (values.length - 1);
  return math.sqrt(variance);
}

double _sleepScoreLower(
  double value, {
  required double ideal,
  required double limit,
}) {
  if (!value.isFinite) return 0;
  if (value <= ideal) return 1;
  if (value >= limit) return 0;
  return 1 - (value - ideal) / (limit - ideal);
}

double _sleepScoreHigher(
  double value, {
  required double ideal,
  required double limit,
}) {
  if (!value.isFinite) return 0;
  if (value >= ideal) return 1;
  if (value <= limit) return 0;
  return (value - limit) / (ideal - limit);
}

class _SleepMetricChart extends StatefulWidget {
  const _SleepMetricChart({
    required this.title,
    required this.unit,
    required this.color,
    required this.series,
    required this.valueFor,
    this.colorFor,
    this.legendItems = const [],
    this.valueDigits = 1,
    this.minY,
    required this.selectedTimeListenable,
    required this.onSelectedTimeChanged,
  });

  final String title;
  final String unit;
  final Color color;
  final List<SleepSessionSeriesPoint> series;
  final double? Function(SleepSessionSeriesPoint point) valueFor;
  final Color Function(SleepSessionSeriesPoint point)? colorFor;
  final List<_SleepChartLegendItem> legendItems;
  final int valueDigits;
  final double? minY;
  final ValueListenable<DateTime?> selectedTimeListenable;
  final ValueChanged<DateTime> onSelectedTimeChanged;

  @override
  State<_SleepMetricChart> createState() => _SleepMetricChartState();
}

class _SleepMetricChartState extends State<_SleepMetricChart> {
  double? _viewMinX;
  double? _viewMaxX;
  double? _scaleStartMinX;
  double? _scaleStartMaxX;
  bool _zooming = false;

  @override
  void didUpdateWidget(covariant _SleepMetricChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series.length != widget.series.length ||
        oldWidget.title != widget.title ||
        oldWidget.series.first.time != widget.series.first.time ||
        oldWidget.series.last.time != widget.series.last.time) {
      _viewMinX = null;
      _viewMaxX = null;
      _scaleStartMinX = null;
      _scaleStartMaxX = null;
      _zooming = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final startTime = widget.series.first.time;
    final axisOrigin = DateTime(
      startTime.year,
      startTime.month,
      startTime.day,
    );
    final chartSegments = <_SleepChartSegment>[];
    var currentEntries = <_SleepChartEntry>[];
    Color? currentColor;
    for (final point in widget.series) {
      final value = widget.valueFor(point);
      if (value != null && value.isFinite) {
        final x = point.time.difference(axisOrigin).inMilliseconds / 60000.0;
        final pointColor = widget.colorFor?.call(point) ?? widget.color;
        final entry = _SleepChartEntry(
          spot: FlSpot(x, value),
          time: point.time,
          color: pointColor,
        );
        if (currentEntries.isNotEmpty && pointColor != currentColor) {
          currentEntries.add(entry);
          chartSegments.add(
            _SleepChartSegment(color: currentColor!, entries: currentEntries),
          );
          currentEntries = <_SleepChartEntry>[entry];
          currentColor = pointColor;
          continue;
        }
        currentColor = pointColor;
        currentEntries.add(entry);
      } else if (currentEntries.isNotEmpty) {
        chartSegments.add(
          _SleepChartSegment(color: currentColor!, entries: currentEntries),
        );
        currentEntries = <_SleepChartEntry>[];
        currentColor = null;
      }
    }
    if (currentEntries.isNotEmpty) {
      chartSegments.add(
        _SleepChartSegment(color: currentColor!, entries: currentEntries),
      );
    }
    final primarySpots = chartSegments
        .expand((segment) => segment.entries.map((entry) => entry.spot))
        .toList();
    final spots = primarySpots;
    final theme = Theme.of(context);
    if (spots.isEmpty) {
      return Text(
        '${widget.title}: zu wenig Daten',
        style: theme.textTheme.bodySmall,
      );
    }
    final bars = <LineChartBarData>[];
    final indexedEntries = <_SleepChartIndexedEntry>[];
    for (var segmentIndex = 0;
        segmentIndex < chartSegments.length;
        segmentIndex++) {
      final segment = chartSegments[segmentIndex];
      final segmentSpots = [
        for (final entry in segment.entries) entry.spot,
      ];
      if (segmentSpots.length < 2) continue;
      bars.add(
        LineChartBarData(
          spots: segmentSpots,
          color: segment.color,
          barWidth: 2.2,
          isCurved: true,
          dotData: const FlDotData(show: false),
        ),
      );
      for (var spotIndex = 0; spotIndex < segment.entries.length; spotIndex++) {
        indexedEntries.add(
          _SleepChartIndexedEntry(
            entry: segment.entries[spotIndex],
          ),
        );
      }
    }
    if (bars.isEmpty) {
      return Text(
        '${widget.title}: zu wenig zusammenhaengende Daten',
        style: theme.textTheme.bodySmall,
      );
    }
    final minX =
        widget.series.first.time.difference(axisOrigin).inMilliseconds /
            60000.0;
    final maxX = math.max(
      minX,
      widget.series.last.time.difference(axisOrigin).inMilliseconds / 60000.0,
    );
    ({
      double? x,
      _SleepChartIndexedEntry? primary,
    }) selectionFor(DateTime? time) {
      if (time == null) return (x: null, primary: null);
      final x = (time.difference(axisOrigin).inMilliseconds / 60000.0)
          .clamp(minX, maxX)
          .toDouble();
      return (
        x: x,
        primary: _nearestChartEntry(indexedEntries, x, maxDistance: 0.51),
      );
    }

    final fullXRange = math.max(0.001, maxX - minX);
    var viewMinX = (_viewMinX ?? minX).clamp(minX, maxX).toDouble();
    var viewMaxX = (_viewMaxX ?? maxX).clamp(minX, maxX).toDouble();
    if (viewMaxX - viewMinX < 0.5 || fullXRange <= 0.5) {
      viewMinX = minX;
      viewMaxX = maxX;
    }
    final zoomed = (viewMaxX - viewMinX) < fullXRange - 0.05;
    final allValues = spots.map((spot) => spot.y).toList();
    final visibleValues = _visibleChartYValues(spots, viewMinX, viewMaxX);
    final scaleValues = visibleValues.isEmpty ? allValues : visibleValues;
    final dataMinY = widget.minY ?? scaleValues.reduce(math.min);
    final dataMaxY = scaleValues.reduce(math.max);
    final yAxis = _niceChartAxis(
      dataMinY,
      dataMaxY,
      fixedMin: widget.minY,
      minSpan: widget.valueDigits >= 2 ? 0.2 : 4.0,
    );
    final leftAxisWidth = widget.valueDigits >= 2 ? 46.0 : 38.0;
    const rightPadding = 8.0;

    void selectAt(Offset position, double width) {
      final range = math.max(0.001, viewMaxX - viewMinX);
      final plotWidth = math.max(1.0, width - leftAxisWidth - rightPadding);
      final localX = (position.dx - leftAxisWidth).clamp(0.0, plotWidth);
      final selectedX = viewMinX + (localX / plotWidth) * range;
      final selectedMinute =
          selectedX.round().clamp(minX.round(), maxX.round()).toInt();
      widget.onSelectedTimeChanged(
        axisOrigin.add(Duration(minutes: selectedMinute)),
      );
    }

    bool isXAxisTouch(Offset position, double height) {
      return position.dy >= height - 30;
    }

    void panViewBy(double dx, double width) {
      if (!zoomed) return;
      final plotWidth = math.max(1.0, width - leftAxisWidth - rightPadding);
      final range = math.max(0.001, viewMaxX - viewMinX);
      final deltaMinutes = dx / plotWidth * range;
      var newMin = viewMinX - deltaMinutes;
      var newMax = viewMaxX - deltaMinutes;
      if (newMin < minX) {
        newMin = minX;
        newMax = newMin + range;
      }
      if (newMax > maxX) {
        newMax = maxX;
        newMin = newMax - range;
      }
      setState(() {
        _viewMinX = newMin.clamp(minX, maxX).toDouble();
        _viewMaxX = newMax.clamp(minX, maxX).toDouble();
      });
    }

    void handleScaleStart(
      ScaleStartDetails details,
      double width,
      double height,
    ) {
      if (details.pointerCount >= 2) {
        _zooming = true;
        _scaleStartMinX = viewMinX;
        _scaleStartMaxX = viewMaxX;
        return;
      }
      _zooming = false;
      if (isXAxisTouch(details.localFocalPoint, height)) {
        selectAt(details.localFocalPoint, width);
      }
    }

    void handleScaleUpdate(
      ScaleUpdateDetails details,
      double width,
      double height,
    ) {
      if (details.pointerCount >= 2) {
        final startMin = _scaleStartMinX ?? viewMinX;
        final startMax = _scaleStartMaxX ?? viewMaxX;
        final startRange = math.max(0.001, startMax - startMin);
        final scale = details.scale.clamp(0.25, 8.0).toDouble();
        final minRange = math.min(fullXRange, 3.0);
        var newRange = (startRange / scale).clamp(minRange, fullXRange);
        final plotWidth = math.max(1.0, width - leftAxisWidth - rightPadding);
        final focusFraction =
            ((details.localFocalPoint.dx - leftAxisWidth) / plotWidth)
                .clamp(0.0, 1.0)
                .toDouble();
        final focusX = startMin + focusFraction * startRange;
        var newMin = focusX - focusFraction * newRange;
        var newMax = newMin + newRange;
        if (newMin < minX) {
          newMin = minX;
          newMax = newMin + newRange;
        }
        if (newMax > maxX) {
          newMax = maxX;
          newMin = newMax - newRange;
        }
        setState(() {
          _viewMinX = newMin.clamp(minX, maxX).toDouble();
          _viewMaxX = newMax.clamp(minX, maxX).toDouble();
        });
        return;
      }
      if (_zooming) return;
      if (isXAxisTouch(details.localFocalPoint, height)) {
        selectAt(details.localFocalPoint, width);
      } else {
        panViewBy(details.focalPointDelta.dx, width);
      }
    }

    void resetZoom() {
      setState(() {
        _viewMinX = null;
        _viewMaxX = null;
      });
    }

    return Container(
      height: 155,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withValues(alpha: 0.62),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.title} ${widget.unit.isEmpty ? '' : '(${widget.unit})'}',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              Flexible(
                child: ValueListenableBuilder<DateTime?>(
                  valueListenable: widget.selectedTimeListenable,
                  builder: (context, selectedTime, _) {
                    if (selectedTime == null) {
                      return const SizedBox.shrink();
                    }
                    final selection = selectionFor(selectedTime);
                    return Text(
                      '${_formatClockTime(selectedTime).substring(0, 5)} '
                      '${selection.primary?.entry.spot.y.toStringAsFixed(widget.valueDigits) ?? '--'}'
                      '${widget.unit.isEmpty ? '' : ' ${widget.unit}'}',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selection.primary?.entry.color ?? widget.color,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          if (widget.legendItems.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final item in widget.legendItems)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: item.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(item.label, style: theme.textTheme.labelSmall),
                    ],
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final xInterval = _niceTimeIntervalMinutes(
                  viewMaxX - viewMinX,
                  constraints.maxWidth,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    if (isXAxisTouch(
                      details.localPosition,
                      constraints.maxHeight,
                    )) {
                      selectAt(details.localPosition, constraints.maxWidth);
                    }
                  },
                  onDoubleTap: resetZoom,
                  onScaleStart: (details) => handleScaleStart(
                    details,
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                  onScaleUpdate: (details) => handleScaleUpdate(
                    details,
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                  onScaleEnd: (_) {
                    _zooming = false;
                    _scaleStartMinX = null;
                    _scaleStartMaxX = null;
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: LineChart(
                            LineChartData(
                              minY: yAxis.min,
                              maxY: yAxis.max,
                              minX: viewMinX,
                              maxX: viewMaxX,
                              clipData: const FlClipData.all(),
                              gridData: FlGridData(
                                show: true,
                                drawVerticalLine: false,
                                getDrawingHorizontalLine: (_) => FlLine(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.3),
                                  strokeWidth: 1,
                                ),
                              ),
                              borderData: FlBorderData(show: false),
                              lineTouchData:
                                  const LineTouchData(enabled: false),
                              titlesData: FlTitlesData(
                                topTitles: const AxisTitles(),
                                rightTitles: const AxisTitles(),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: leftAxisWidth,
                                    interval: yAxis.interval,
                                    getTitlesWidget: (value, meta) => Text(
                                      value.toStringAsFixed(widget.valueDigits),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 26,
                                    interval: xInterval,
                                    getTitlesWidget: (value, meta) {
                                      if ((value - viewMinX).abs() < 0.001 ||
                                          (value - viewMaxX).abs() < 0.001) {
                                        return const SizedBox.shrink();
                                      }
                                      final time = axisOrigin.add(
                                        Duration(
                                          milliseconds: (value * 60000).round(),
                                        ),
                                      );
                                      return Text(
                                        _formatClockTime(time).substring(0, 5),
                                        style: theme.textTheme.labelSmall,
                                      );
                                    },
                                  ),
                                ),
                              ),
                              lineBarsData: bars,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ValueListenableBuilder<DateTime?>(
                            valueListenable: widget.selectedTimeListenable,
                            builder: (context, selectedTime, _) {
                              final selection = selectionFor(selectedTime);
                              final selectedX = selection.x;
                              final range = viewMaxX - viewMinX;
                              final plotWidth = math.max(
                                1.0,
                                constraints.maxWidth -
                                    leftAxisWidth -
                                    rightPadding,
                              );
                              final lineX = selectedX == null ||
                                      selectedX < viewMinX ||
                                      selectedX > viewMaxX ||
                                      range <= 0
                                  ? null
                                  : leftAxisWidth +
                                      ((selectedX - viewMinX) / range) *
                                          plotWidth;
                              return CustomPaint(
                                painter: _SleepChartSelectionPainter(
                                  x: lineX,
                                  color: (selection.primary?.entry.color ??
                                          widget.color)
                                      .withValues(alpha: 0.75),
                                  bottomInset: 26,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  _SleepChartIndexedEntry? _nearestChartEntry(
    List<_SleepChartIndexedEntry> entries,
    double x, {
    double? maxDistance,
  }) {
    if (entries.isEmpty) return null;
    var low = 0;
    var high = entries.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (entries[middle].entry.spot.x < x) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var best = entries[low];
    var bestDistance = (best.entry.spot.x - x).abs();
    if (low > 0) {
      final previous = entries[low - 1];
      final previousDistance = (previous.entry.spot.x - x).abs();
      if (previousDistance <= bestDistance) {
        best = previous;
        bestDistance = previousDistance;
      }
    }
    if (maxDistance != null && bestDistance > maxDistance) return null;
    return best;
  }
}

class _SleepChartSelectionPainter extends CustomPainter {
  const _SleepChartSelectionPainter({
    required this.x,
    required this.color,
    required this.bottomInset,
  });

  final double? x;
  final Color color;
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final lineX = x;
    if (lineX == null || !lineX.isFinite) return;
    final endY = math.max(0.0, size.height - bottomInset);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square;
    const dash = 6.0;
    const gap = 4.0;
    for (var y = 0.0; y < endY; y += dash + gap) {
      canvas.drawLine(
        Offset(lineX, y),
        Offset(lineX, math.min(endY, y + dash)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SleepChartSelectionPainter oldDelegate) =>
      oldDelegate.x != x ||
      oldDelegate.color != color ||
      oldDelegate.bottomInset != bottomInset;
}

List<double> _visibleChartYValues(
  Iterable<FlSpot> spots,
  double viewMinX,
  double viewMaxX,
) {
  return spots
      .where((spot) => spot.x >= viewMinX && spot.x <= viewMaxX)
      .map((spot) => spot.y)
      .toList(growable: false);
}

@visibleForTesting
({double min, double max}) visibleChartDataRangeForTest(
  List<({double x, double y})> points, {
  required double viewMinX,
  required double viewMaxX,
}) {
  final allValues = points.map((point) => point.y).toList(growable: false);
  final visibleValues = _visibleChartYValues(
    points.map((point) => FlSpot(point.x, point.y)),
    viewMinX,
    viewMaxX,
  );
  final values = visibleValues.isEmpty ? allValues : visibleValues;
  return (min: values.reduce(math.min), max: values.reduce(math.max));
}

class _SleepChartLegendItem {
  const _SleepChartLegendItem({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;
}

class _SleepChartSegment {
  const _SleepChartSegment({
    required this.color,
    required this.entries,
  });

  final Color color;
  final List<_SleepChartEntry> entries;
}

class _SleepChartEntry {
  const _SleepChartEntry({
    required this.spot,
    required this.time,
    required this.color,
  });

  final FlSpot spot;
  final DateTime time;
  final Color color;
}

class _SleepChartIndexedEntry {
  const _SleepChartIndexedEntry({
    required this.entry,
  });

  final _SleepChartEntry entry;
}

const _snoreWearerColor = Color(0xFF32D6E8);
const _snoreExternalColor = Color(0xFFFFC857);
const _snoreUnknownColor = Color(0xFFE879F9);

Color _snoreSourceColor(String? source) {
  return switch (source) {
    'wearer' => _snoreWearerColor,
    'external' => _snoreExternalColor,
    _ => _snoreUnknownColor,
  };
}

class _NiceChartAxis {
  const _NiceChartAxis({
    required this.min,
    required this.max,
    required this.interval,
  });

  final double min;
  final double max;
  final double interval;
}

_NiceChartAxis _niceChartAxis(
  double dataMin,
  double dataMax, {
  double? fixedMin,
  double? fixedMax,
  double minSpan = 1,
}) {
  if (fixedMin != null && fixedMax != null && fixedMax > fixedMin) {
    return _NiceChartAxis(
      min: fixedMin,
      max: fixedMax,
      interval: _niceStep((fixedMax - fixedMin) / 4),
    );
  }
  var min = dataMin;
  var max = dataMax;
  if (!min.isFinite || !max.isFinite) {
    return const _NiceChartAxis(min: 0, max: 1, interval: 0.25);
  }
  if (min == max) {
    final half = math.max(minSpan / 2, min.abs() * 0.02);
    if (fixedMin == null) min -= half;
    if (fixedMax == null) max += half;
  }
  final span = math.max(minSpan, max - min);
  final interval = _niceStep(span / 2);
  final paddedMin = fixedMin ?? min - span * 0.08;
  final paddedMax = fixedMax ?? max + span * 0.08;
  final axisMin = fixedMin ?? (paddedMin / interval).floor() * interval;
  final axisMax = fixedMax ?? (paddedMax / interval).ceil() * interval;
  return _NiceChartAxis(
    min: axisMin.toDouble(),
    max: axisMax <= axisMin ? axisMin + interval : axisMax.toDouble(),
    interval: interval,
  );
}

double _niceStep(double rawStep) {
  if (!rawStep.isFinite || rawStep <= 0) return 1;
  final exponent = math.pow(10, (math.log(rawStep) / math.ln10).floor());
  final fraction = rawStep / exponent;
  final niceFraction = fraction <= 1
      ? 1.0
      : fraction <= 2
          ? 2.0
          : fraction <= 2.5
              ? 2.5
              : fraction <= 5
                  ? 5.0
                  : 10.0;
  return (niceFraction * exponent).toDouble();
}

double _niceTimeIntervalMinutes(double visibleMinutes, double chartWidth) {
  if (!visibleMinutes.isFinite || visibleMinutes <= 6) return 1;
  final maxLabels = math.max(3, (chartWidth / 72).floor());
  final rawInterval = visibleMinutes / maxLabels;
  final candidates = <double>[
    1,
    2,
    5,
    10,
    15,
    30,
    60,
    90,
    120,
    180,
    240,
    360,
    720,
  ];
  for (final candidate in candidates) {
    if (candidate >= rawInterval) return candidate;
  }
  return 1440;
}

class _SleepJournalCorrelationSection extends StatefulWidget {
  const _SleepJournalCorrelationSection({
    required this.controller,
  });

  final MeasurementController controller;

  @override
  State<_SleepJournalCorrelationSection> createState() =>
      _SleepJournalCorrelationSectionState();
}

class _SleepJournalCorrelationSectionState
    extends State<_SleepJournalCorrelationSection> {
  int _selectedTab = 0;
  late Future<List<_SleepHistorySeries>> _seriesFuture;
  String _historySignature = '';

  @override
  void initState() {
    super.initState();
    _reloadSeries();
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.controller.sleepHistory;
    final selectedRecords = widget.controller.selectedCorrelationSleepHistory;
    final nextSignature = selectedRecords
        .map((record) => '${record.id}:${record.dataCsvPath ?? ''}')
        .join('|');
    if (nextSignature != _historySignature) {
      _reloadSeries();
    }

    final theme = Theme.of(context);
    final nightCount = selectedRecords.length;
    final totalNightCount = records.length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  nightCount == 1
                      ? '1 Nacht wird ausgewertet.'
                      : '$nightCount von $totalNightCount Naechten werden ausgewertet.',
                  style: theme.textTheme.bodySmall,
                ),
                OutlinedButton.icon(
                  onPressed: records.isEmpty ? null : _chooseNights,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: const Text('Naechte auswaehlen'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DefaultTabController(
              length: 2,
              initialIndex: _selectedTab,
              child: TabBar(
                onTap: (index) => setState(() => _selectedTab = index),
                tabs: const [
                  Tab(text: 'Position'),
                  Tab(text: 'Antworten'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (nightCount == 0)
              Text(
                'Noch keine gespeicherten Naechte vorhanden.',
                style: theme.textTheme.bodySmall,
              )
            else if (_selectedTab == 0)
              FutureBuilder<List<_SleepHistorySeries>>(
                future: _seriesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  final history =
                      snapshot.data ?? const <_SleepHistorySeries>[];
                  return _PoseSnoreExtremesView(
                    analysis: _poseAnalysisFromHistory(history),
                    meanHeartRateBpm: _meanHistoryMetric(
                      history,
                      (point) => point.heartRateBpm,
                      (record) => record.metrics.meanHeartRateBpm,
                    ),
                    meanBreathingRatePerMin: _meanHistoryMetric(
                      history,
                      (point) => point.breathingRatePerMin,
                      (record) => record.metrics.meanBreathingRatePerMin,
                    ),
                  );
                },
              )
            else
              _SleepAnswerCorrelationView(
                correlations: computeSleepQuestionPhysiologyCorrelations(
                  selectedRecords,
                  widget.controller.sleepQuestions,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _reloadSeries() {
    final records = widget.controller.selectedCorrelationSleepHistory;
    _historySignature = records
        .map((record) => '${record.id}:${record.dataCsvPath ?? ''}')
        .join('|');
    _seriesFuture = Future.wait([
      for (final record in records)
        widget.controller.loadSleepSessionSeries(record).then(
              (series) => _SleepHistorySeries(record: record, series: series),
            ),
    ]);
  }

  Future<void> _chooseNights() async {
    final records = widget.controller.sleepHistory;
    final pending =
        Set<String>.from(widget.controller.selectedCorrelationRecordIds);
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final allSelected = pending.length == records.length;
            return AlertDialog(
              title: const Text('Naechte auswaehlen'),
              content: SizedBox(
                width: 420,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Alle Naechte'),
                      value: allSelected,
                      onChanged: (value) => setDialogState(() {
                        pending.clear();
                        if (value == true) {
                          pending.addAll(records.map((record) => record.id));
                        }
                      }),
                    ),
                    const Divider(),
                    for (final record in records)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: pending.contains(record.id),
                        title: Text(_formatDate(record.metrics.startedAt)),
                        subtitle: Text(
                          '${_formatClockTime(record.metrics.startedAt).substring(0, 5)} - '
                          '${_formatClockTime(record.metrics.endedAt).substring(0, 5)}',
                        ),
                        onChanged: (value) => setDialogState(() {
                          if (value == true) {
                            pending.add(record.id);
                          } else {
                            pending.remove(record.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: pending.isEmpty
                      ? null
                      : () => Navigator.pop(
                            dialogContext,
                            Set<String>.from(pending),
                          ),
                  child: const Text('Auswerten'),
                ),
              ],
            );
          },
        );
      },
    );
    if (selected == null || !mounted) return;
    await widget.controller.setCorrelationNightSelection(selected);
    if (!mounted) return;
    setState(() {
      _reloadSeries();
    });
  }
}

class _PoseSnoreExtremesView extends StatelessWidget {
  const _PoseSnoreExtremesView({
    required this.analysis,
    required this.meanHeartRateBpm,
    required this.meanBreathingRatePerMin,
  });

  final PoseSnoreAnalysis analysis;
  final double? meanHeartRateBpm;
  final double? meanBreathingRatePerMin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highest = analysis.topRiskBins(limit: 1);
    final lowest = analysis.lowestRiskBins(limit: 1);
    final lowestHeartRate = analysis.lowestHeartRateBins(limit: 1);
    final lowestBreathingRate = analysis.lowestBreathingRateBins(limit: 1);
    if (highest.isEmpty &&
        lowest.isEmpty &&
        lowestHeartRate.isEmpty &&
        lowestBreathingRate.isEmpty) {
      return Text(
        'Noch zu wenig gemeinsame Positions- und Messdaten.',
        style: theme.textTheme.bodySmall,
      );
    }

    final highestBin = highest.isEmpty ? null : highest.first;
    final lowestBin = lowest.isEmpty ? null : lowest.first;
    final heartBin = lowestHeartRate.isEmpty ? null : lowestHeartRate.first;
    final breathingBin =
        lowestBreathingRate.isEmpty ? null : lowestBreathingRate.first;
    final sameCluster = highestBin != null &&
        lowestBin != null &&
        identical(highestBin, lowestBin);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final itemWidth =
                wide ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (highestBin != null)
                  _PoseMetricExtremeTile(
                    width: itemWidth,
                    title: 'Hoechste Schnarchwahrscheinlichkeit',
                    icon: Icons.trending_up,
                    color: const Color(0xFFFF6B6B),
                    bin: highestBin,
                    primaryValue: _formatPercent(highestBin.snoreProbability),
                    comparisonText: _snoreBaselineDifference(
                      highestBin,
                      analysis.baselineSnoreProbability,
                    ),
                  ),
                if (lowestBin != null)
                  _PoseMetricExtremeTile(
                    width: itemWidth,
                    title: 'Niedrigste Schnarchwahrscheinlichkeit',
                    icon: Icons.trending_down,
                    color: const Color(0xFF5EE0B5),
                    bin: lowestBin,
                    primaryValue: _formatPercent(lowestBin.snoreProbability),
                    comparisonText: _snoreBaselineDifference(
                      lowestBin,
                      analysis.baselineSnoreProbability,
                    ),
                  ),
                if (heartBin != null)
                  _PoseMetricExtremeTile(
                    width: itemWidth,
                    title: 'Niedrigste Herzfrequenz',
                    icon: Icons.favorite_outline,
                    color: const Color(0xFFFFB04A),
                    bin: heartBin,
                    primaryValue: _formatMetricDifference(
                      heartBin.meanHeartRateBpm,
                      meanHeartRateBpm,
                      'bpm',
                    ),
                    comparisonText: _formatMetricBaseline(
                      meanHeartRateBpm,
                      'bpm',
                    ),
                    footerMetricText:
                        'Herzfrequenz ${heartBin.meanHeartRateBpm!.toStringAsFixed(1)} bpm',
                  ),
                if (breathingBin != null)
                  _PoseMetricExtremeTile(
                    width: itemWidth,
                    title: 'Niedrigste Atemfrequenz',
                    icon: Icons.air,
                    color: const Color(0xFF7AA7FF),
                    bin: breathingBin,
                    primaryValue: _formatMetricDifference(
                      breathingBin.meanBreathingRatePerMin,
                      meanBreathingRatePerMin,
                      '/min',
                    ),
                    comparisonText: _formatMetricBaseline(
                      meanBreathingRatePerMin,
                      '/min',
                    ),
                    footerMetricText:
                        'Atemfrequenz ${breathingBin.meanBreathingRatePerMin!.toStringAsFixed(0)} /min',
                  ),
              ],
            );
          },
        ),
        if (sameCluster) ...[
          const SizedBox(height: 8),
          Text(
            'Bisher ist nur eine ausreichend lange Positionsgruppe vorhanden.',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ],
    );
  }

  String _snoreBaselineDifference(PoseSnoreBin bin, double baseline) {
    final difference = (bin.snoreProbability - baseline) * 100;
    return '${difference >= 0 ? '+' : ''}${difference.toStringAsFixed(1)} '
        '%-Pkt gegenueber der gesamten Messzeit';
  }

  String _formatMetricDifference(
    double? positionValue,
    double? overallValue,
    String unit,
  ) {
    if (positionValue == null ||
        !positionValue.isFinite ||
        overallValue == null ||
        !overallValue.isFinite) {
      return '--';
    }
    final difference = positionValue - overallValue;
    return '${difference >= 0 ? '+' : ''}${difference.toStringAsFixed(1)} $unit';
  }

  String _formatMetricBaseline(double? value, String unit) {
    if (value == null || !value.isFinite) {
      return 'Gesamtmittel nicht verfuegbar';
    }
    return 'gegenueber Gesamtmittel ${value.toStringAsFixed(1)} $unit';
  }
}

class _PoseMetricExtremeTile extends StatelessWidget {
  const _PoseMetricExtremeTile({
    required this.width,
    required this.title,
    required this.icon,
    required this.color,
    required this.bin,
    required this.primaryValue,
    required this.comparisonText,
    this.footerMetricText,
  });

  final double width;
  final String title;
  final IconData icon;
  final Color color;
  final PoseSnoreBin bin;
  final String primaryValue;
  final String comparisonText;
  final String? footerMetricText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title, style: theme.textTheme.labelLarge),
              ),
              Text(
                primaryValue,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            comparisonText,
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 8),
          _Mg24PoseOverview(
            mg24: const Mg24State.empty().copyWith(
              status: 'Archiv',
              forehead: _poseSensor(
                rollDeg: bin.foreheadRollDeg,
                pitchDeg: bin.foreheadPitchDeg,
                yawDeg: bin.foreheadYawDeg,
              ),
              belly: _poseSensor(
                rollDeg: bin.bellyRollDeg,
                pitchDeg: bin.bellyPitchDeg,
                yawDeg: bin.bellyYawDeg,
              ),
            ),
            relativeYawDeg: _relativeYawFromAngles(
              bin.foreheadYawDeg,
              bin.bellyYawDeg,
            ),
            onResetPose: null,
            onBodyInteractionChanged: (_) {},
            showPowerAndTemperature: false,
            summaryLine:
                'Zeit ${_formatDurationSeconds(bin.durationSeconds)} | '
                '${footerMetricText ?? 'Schnarch ${_formatDurationSeconds(bin.snoreDurationSeconds)}'}',
          ),
        ],
      ),
    );
  }
}

class _SleepAnswerCorrelationView extends StatelessWidget {
  const _SleepAnswerCorrelationView({required this.correlations});

  final List<SleepQuestionPhysiologyCorrelation> correlations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (correlations.isEmpty) {
      return Text(
        'Mehr gespeicherte Schlafzyklen noetig.',
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                Icons.swap_horiz,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Links: niedrigere Frequenz   |   Rechts: hoehere Frequenz',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final correlation in correlations)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.help_outline,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        correlation.label,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  correlation.prompt,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (correlation.lowLabel != null ||
                    correlation.highLabel != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          correlation.lowLabel ?? 'niedrig',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, size: 13),
                      ),
                      Expanded(
                        child: Text(
                          correlation.highLabel ?? 'hoch',
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                _PhysiologyCorrelationLine(
                  label: 'Herzfrequenz',
                  correlation: correlation.heartRateCorrelation,
                  sampleCount: correlation.heartRateSampleCount,
                  color: const Color(0xFFFFB04A),
                ),
                const SizedBox(height: 5),
                _PhysiologyCorrelationLine(
                  label: 'Atemfrequenz',
                  correlation: correlation.breathingRateCorrelation,
                  sampleCount: correlation.breathingRateSampleCount,
                  color: const Color(0xFF7AA7FF),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PhysiologyCorrelationLine extends StatelessWidget {
  const _PhysiologyCorrelationLine({
    required this.label,
    required this.correlation,
    required this.sampleCount,
    required this.color,
  });

  final String label;
  final double? correlation;
  final int sampleCount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = correlation;
    final strength = value == null ? null : _correlationStrength(value);
    final direction = value == null
        ? 'Mindestens 4 Naechte mit Antwort und Messwert noetig'
        : value.abs() < 0.15
            ? 'Kein klarer Zusammenhang'
            : value < 0
                ? 'Hoehere Antwort, niedrigere $label'
                : 'Hoehere Antwort, hoehere $label';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(label, style: theme.textTheme.labelMedium),
            ),
            Text(
              value == null
                  ? '$sampleCount Naechte'
                  : '${value.toStringAsFixed(2)}  |  $sampleCount Naechte',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 12,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final center = width / 2;
              final extent =
                  value == null ? 0.0 : value.abs().clamp(0.0, 1.0) * center;
              return Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  if (value != null && extent > 0)
                    Positioned(
                      left: value < 0 ? center - extent : center,
                      width: extent,
                      top: 1,
                      bottom: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  Positioned(
                    left: center - 0.5,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: ColoredBox(
                      color: theme.colorScheme.outline.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          strength == null ? direction : '$strength: $direction',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _correlationStrength(double value) {
    final magnitude = value.abs();
    if (magnitude >= 0.7) return 'stark';
    if (magnitude >= 0.4) return 'mittel';
    return 'schwach';
  }
}

class _SleepHistorySeries {
  const _SleepHistorySeries({required this.record, required this.series});

  final SleepSessionRecord record;
  final List<SleepSessionSeriesPoint> series;
}

PoseSnoreAnalysis _poseAnalysisFromHistory(
  List<_SleepHistorySeries> history,
) {
  if (history.isEmpty) return const PoseSnoreAnalysis.empty();
  final stats = SleepMeasurementStats();
  for (final entry in history) {
    if (entry.series.any((point) => point.hasPose)) {
      _addPoseSeriesToStats(stats, entry.series);
    }
  }
  final startedAt = history
      .map((entry) => entry.record.metrics.startedAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  final endedAt = history
      .map((entry) => entry.record.metrics.endedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  return stats.summary(startedAt: startedAt, endedAt: endedAt).poseSnore;
}

double? _meanHistoryMetric(
  List<_SleepHistorySeries> history,
  double? Function(SleepSessionSeriesPoint point) valueFor,
  double? Function(SleepSessionRecord record) fallbackFor,
) {
  var weightedSum = 0.0;
  var totalWeight = 0.0;
  for (final entry in history) {
    var addedSeriesValue = false;
    for (var i = 0; i < entry.series.length; i++) {
      final point = entry.series[i];
      final value = valueFor(point);
      if (value == null || !value.isFinite) continue;
      final next = i + 1 < entry.series.length ? entry.series[i + 1] : null;
      final rawSeconds = next == null
          ? 60.0
          : next.time.difference(point.time).inMilliseconds / 1000.0;
      final seconds = rawSeconds.isFinite && rawSeconds > 0
          ? rawSeconds.clamp(1.0, 300.0).toDouble()
          : 60.0;
      weightedSum += value * seconds;
      totalWeight += seconds;
      addedSeriesValue = true;
    }
    if (addedSeriesValue) continue;
    final fallback = fallbackFor(entry.record);
    if (fallback == null || !fallback.isFinite) continue;
    final seconds = entry.record.metrics.durationSeconds;
    final weight = seconds.isFinite && seconds > 0 ? seconds : 1.0;
    weightedSum += fallback * weight;
    totalWeight += weight;
  }
  return totalWeight <= 0 ? null : weightedSum / totalWeight;
}

void _addPoseSeriesToStats(
  SleepMeasurementStats stats,
  List<SleepSessionSeriesPoint> series,
) {
  for (var i = 0; i < series.length; i++) {
    final point = series[i];
    if (!point.hasPose) continue;
    final next = i + 1 < series.length ? series[i + 1] : null;
    final inferredSeconds = next == null
        ? 60.0
        : next.time.difference(point.time).inMilliseconds / 1000.0;
    final seconds = inferredSeconds.isFinite && inferredSeconds > 0
        ? inferredSeconds.clamp(1.0, 300.0).toDouble()
        : 60.0;
    final wearerSnoreSeconds = point.snoreSource == 'wearer'
        ? (point.snoreSeconds?.clamp(0.0, seconds).toDouble() ?? 0.0)
        : 0.0;
    stats.add(
      heartRate: point.heartRateBpm,
      breathingRate: point.breathingRatePerMin,
      relativeAngleDeg: 0,
      isSnoring: wearerSnoreSeconds > 0,
      durationSeconds: seconds,
      snoreFraction: wearerSnoreSeconds / seconds,
      foreheadRollDeg: point.foreheadRollDeg,
      foreheadPitchDeg: point.foreheadPitchDeg,
      foreheadYawDeg: point.foreheadYawDeg,
      bellyRollDeg: point.bellyRollDeg,
      bellyPitchDeg: point.bellyPitchDeg,
      bellyYawDeg: point.bellyYawDeg,
      hasForeheadPose: point.hasForeheadPose,
      hasBellyPose: point.hasBellyPose,
      hasSnoreData: true,
    );
  }
}

// ignore: unused_element
class _SleepJournalLegacyPanel extends StatelessWidget {
  const _SleepJournalLegacyPanel({required this.controller});

  final MeasurementController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = controller.latestSleepSession;
    final summary = controller.sleepSummary;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bedtime_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Text('Schlafjournal', style: theme.textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () => _showCustomQuestions(context, controller),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Zusatzfrage'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (latest == null)
              Text(
                'Nach der ersten vollstaendigen Messung erscheinen Score, Historie, Korrelationen und Tipps.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 650;
                  final scoreWidth = compact ? constraints.maxWidth : 170.0;
                  final statWidth = compact
                      ? math.max(145.0, (constraints.maxWidth - 8) / 2)
                      : math.max(
                          130.0, (constraints.maxWidth - scoreWidth - 32) / 4);
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ScoreBadge(
                        width: scoreWidth,
                        score: latest.score,
                        label: 'Letzte Nacht',
                      ),
                      _MiniStat(
                        width: statWidth,
                        label: 'Durchschnitt',
                        value: _formatOptional(summary.averageScore, digits: 0),
                        unit: 'Score',
                      ),
                      _MiniStat(
                        width: statWidth,
                        label: 'Sitzungen',
                        value: summary.sessionCount.toString(),
                        unit: '',
                      ),
                      _MiniStat(
                        width: statWidth,
                        label: 'Herzfrequenz mittel',
                        value: _formatOptional(
                          latest.metrics.meanHeartRateBpm,
                          digits: 1,
                        ),
                        unit: 'bpm',
                      ),
                      _MiniStat(
                        width: statWidth,
                        label: 'Schnarchzeit',
                        value: _formatOptional(
                          latest.metrics.snoreTimeFraction == null
                              ? null
                              : latest.metrics.snoreTimeFraction! * 100,
                          digits: 1,
                        ),
                        unit: '%',
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _TipsList(tips: controller.personalizedSleepTips),
              const SizedBox(height: 12),
              _PoseSnoreAnalysisPanel(
                analysis: latest.metrics.poseSnore,
                relativeAnalysis: latest.metrics.relativeAngleSnore,
              ),
              const SizedBox(height: 12),
              _CorrelationPanel(correlations: controller.sleepCorrelations),
              const SizedBox(height: 12),
              _HistoryStrip(records: controller.sleepHistory),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: controller.sleepHistory.isEmpty
                      ? null
                      : () => _showHistory(context, controller.sleepHistory),
                  icon: const Icon(Icons.history),
                  label: const Text('Historie'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.openSleepSessionsCsv(),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Schlaf-CSV'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.shareSleepSessionsCsv(),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Teilen'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatOptional(double? value, {required int digits}) {
    return value == null ? '--' : value.toStringAsFixed(digits);
  }

  Future<void> _showCustomQuestions(
    BuildContext context,
    MeasurementController controller,
  ) async {
    final textController = TextEditingController();
    var phase = SleepQuestionPhase.evening;
    var type = SleepQuestionType.scale;

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setSheetState) {
              final theme = Theme.of(context);
              final bottom = MediaQuery.viewInsetsOf(context).bottom;
              final custom = controller.customSleepQuestions;

              return Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Zusatzfragen',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: textController,
                        decoration: const InputDecoration(
                          labelText: 'Neue Frage',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<SleepQuestionPhase>(
                            value: phase,
                            items: SleepQuestionPhase.values
                                .map(
                                  (entry) => DropdownMenuItem(
                                    value: entry,
                                    child: Text(entry.label),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (value) {
                              if (value != null) {
                                setSheetState(() => phase = value);
                              }
                            },
                          ),
                          DropdownButton<SleepQuestionType>(
                            value: type,
                            items: SleepQuestionType.values
                                .map(
                                  (entry) => DropdownMenuItem(
                                    value: entry,
                                    child: Text(entry.label),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (value) {
                              if (value != null) {
                                setSheetState(() => type = value);
                              }
                            },
                          ),
                          FilledButton.icon(
                            onPressed: () async {
                              await controller.addCustomSleepQuestion(
                                title: textController.text,
                                phase: phase,
                                type: type,
                              );
                              textController.clear();
                              setSheetState(() {});
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Hinzufuegen'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: custom.isEmpty
                            ? Center(
                                child: Text(
                                  'Noch keine Zusatzfragen.',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              )
                            : ListView.separated(
                                itemCount: custom.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final question = custom[index];
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(question.title),
                                    subtitle: Text(
                                      '${question.phase.label} | ${question.type.label}',
                                    ),
                                    trailing: IconButton(
                                      onPressed: () async {
                                        await controller
                                            .removeCustomSleepQuestion(
                                          question.id,
                                        );
                                        setSheetState(() {});
                                      },
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      textController.dispose();
    }
  }

  Future<void> _showHistory(
    BuildContext context,
    List<SleepSessionRecord> records,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.84,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child:
                          Text('Historie', style: theme.textTheme.titleMedium),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${_formatDate(record.metrics.startedAt)} | Score ${record.score.toStringAsFixed(0)}',
                        ),
                        subtitle: Text(
                          'Herzfrequenz ${_formatNumber(record.metrics.meanHeartRateBpm, 1)} bpm | '
                          'Atemfrequenz ${_formatNumber(record.metrics.meanBreathingRatePerMin, 0)} /min | '
                          'Schnarchen ${_formatPercent(record.metrics.snoreTimeFraction)}',
                        ),
                        onTap: () => _showSessionDetails(context, record),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSessionDetails(
    BuildContext context,
    SleepSessionRecord record,
  ) {
    final theme = Theme.of(context);
    final poseSnore = record.metrics.poseSnore;
    final topPose = poseSnore.topRiskBins(limit: 1);
    final riskiestPose = topPose.isEmpty ? null : topPose.first;
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Score ${record.score.toStringAsFixed(0)}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_formatDate(record.metrics.startedAt)),
                const SizedBox(height: 10),
                Text(
                  'Herz: ${_formatNumber(record.metrics.meanHeartRateBpm, 1)} bpm\n'
                  'Atmung: ${_formatNumber(record.metrics.meanBreathingRatePerMin, 1)} /min\n'
                  'Relative Drehung: ${_formatNumber(record.metrics.meanRelativeAngleDeg, 1)} deg\n'
                  'Schnarchzeit: ${_formatPercent(record.metrics.snoreTimeFraction)}',
                  style: theme.textTheme.bodyMedium,
                ),
                if (poseSnore.hasData) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Basisrate: ${_formatPercent(poseSnore.baselineSnoreProbability)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (riskiestPose != null)
                    Text(
                      'Top-Position: ${riskiestPose.rangeLabel} '
                      '(${_formatPercent(riskiestPose.snoreProbability)})',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
                const SizedBox(height: 10),
                ...record.tips.map((tip) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('- $tip'),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schliessen'),
            ),
          ],
        );
      },
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({
    required this.width,
    required this.score,
    required this.label,
  });

  final double width;
  final double score;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = score >= 75
        ? const Color(0xFF16805F)
        : score >= 55
            ? const Color(0xFFE0822D)
            : const Color(0xFFB4232A);
    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withValues(alpha: 0.78),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: (score / 100).clamp(0.0, 1.0),
                  strokeWidth: 5,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.14),
                ),
                Text(
                  score.toStringAsFixed(0),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.width,
    required this.label,
    required this.value,
    required this.unit,
  });

  final double width;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withValues(alpha: 0.62),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(unit, style: theme.textTheme.bodySmall),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TipsList extends StatelessWidget {
  const _TipsList({required this.tips});

  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Personalisierte Tipps', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        ...tips.map(
          (tip) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('- '),
                Expanded(child: Text(tip, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CorrelationPanel extends StatelessWidget {
  const _CorrelationPanel({required this.correlations});

  final List<SleepCorrelation> correlations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Korrelationen', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        if (correlations.isEmpty)
          Text(
            'Mindestens 4 gespeicherte Naechte mit variierenden Werten noetig.',
            style: theme.textTheme.bodySmall,
          )
        else
          ...correlations.map((correlation) {
            final positive = correlation.correlation >= 0;
            final color =
                positive ? const Color(0xFF16805F) : const Color(0xFFB4232A);
            return Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          correlation.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        'r=${correlation.correlation.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: correlation.correlation.abs().clamp(0.0, 1.0),
                      minHeight: 6,
                      color: color,
                      backgroundColor: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.35),
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

class _PoseSnoreAnalysisPanel extends StatelessWidget {
  const _PoseSnoreAnalysisPanel({
    required this.analysis,
    required this.relativeAnalysis,
  });

  final PoseSnoreAnalysis analysis;
  final RelativeAngleSnoreAnalysis relativeAnalysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseline = analysis.baselineSnoreProbability;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withValues(alpha: 0.70),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.view_in_ar,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Schnarch-Positionen',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (analysis.hasData)
                Text(
                  'Basis ${_formatPercent(baseline)}',
                  style: theme.textTheme.labelSmall,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!analysis.hasData)
            Text(
              'Noch keine gemeinsame Stirn-/Bauch-Orientierung mit Schnarchdaten.',
              style: theme.textTheme.bodySmall,
            )
          else
            DefaultTabController(
              length: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TabBar(
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    tabs: const [
                      Tab(text: 'Top 3'),
                      Tab(text: 'Cluster'),
                      Tab(text: 'Winkel'),
                      Tab(text: 'Relativ'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 500,
                    child: TabBarView(
                      children: [
                        SingleChildScrollView(
                          child: _PoseSnoreTopView(analysis: analysis),
                        ),
                        SingleChildScrollView(
                          child: _PoseSnoreRateList(analysis: analysis),
                        ),
                        SingleChildScrollView(
                          child: _PoseAngleFeatureList(analysis: analysis),
                        ),
                        SingleChildScrollView(
                          child: _AngleSnorePanel(analysis: relativeAnalysis),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PoseSnoreTopView extends StatelessWidget {
  const _PoseSnoreTopView({required this.analysis});

  final PoseSnoreAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = analysis.topRiskBins();
    if (top.isEmpty) {
      return Text(
        'Noch zu wenig Aufenthaltszeit in einzelnen Winkelkombinationen.',
        style: theme.textTheme.bodySmall,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final width =
            wide ? (constraints.maxWidth - 16) / 3 : constraints.maxWidth;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < top.length; i++)
              _PoseSnoreCard(
                width: width,
                rank: i + 1,
                bin: top[i],
                baselineProbability: analysis.baselineSnoreProbability,
              ),
          ],
        );
      },
    );
  }
}

class _PoseSnoreCard extends StatelessWidget {
  const _PoseSnoreCard({
    required this.width,
    required this.rank,
    required this.bin,
    required this.baselineProbability,
  });

  final double width;
  final int rank;
  final PoseSnoreBin bin;
  final double baselineProbability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lift = bin.snoreProbability - baselineProbability;
    final liftText = lift >= 0
        ? '+${(lift * 100).toStringAsFixed(1)} %-Pkt'
        : '${(lift * 100).toStringAsFixed(1)} %-Pkt';

    return Container(
      width: width,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#$rank',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatPercent(bin.snoreProbability),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(liftText, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            width: double.infinity,
            child: _Mg24PosePreview(
              head: _poseSensor(
                rollDeg: bin.foreheadRollDeg,
                pitchDeg: bin.foreheadPitchDeg,
                yawDeg: bin.foreheadYawDeg,
              ),
              chest: _poseSensor(
                rollDeg: bin.bellyRollDeg,
                pitchDeg: bin.bellyPitchDeg,
                yawDeg: bin.bellyYawDeg,
              ),
              relativeYawDeg: _relativeYawFromAngles(
                bin.foreheadYawDeg,
                bin.bellyYawDeg,
              ),
              viewYawDeg: -18,
              interactive: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Kopf Drehung/Neigung ${_formatAngleCompact(bin.foreheadRollDeg)} / '
            '${_formatAngleCompact(bin.foreheadPitchDeg)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Brust Drehung/Neigung ${_formatAngleCompact(bin.bellyRollDeg)} / '
            '${_formatAngleCompact(bin.bellyPitchDeg)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Relativ Drehung/Neigung ${_formatAngleCompact(bin.relativeRollCenterDeg)} / '
            '${_formatAngleCompact(bin.relativePitchCenterDeg)} | '
            'Zeit ${_formatDurationSeconds(bin.durationSeconds)} | '
            'Schnarch ${_formatDurationSeconds(bin.snoreDurationSeconds)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PoseSnoreRateList extends StatelessWidget {
  const _PoseSnoreRateList({required this.analysis});

  final PoseSnoreAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = analysis.reliableBins.isNotEmpty
        ? analysis.reliableBins
        : analysis.bins.where((bin) => bin.durationSeconds > 0).toList();
    final sorted = [...candidates]..sort((a, b) {
        final probabilityCompare =
            b.snoreProbability.compareTo(a.snoreProbability);
        if (probabilityCompare != 0) return probabilityCompare;
        return b.durationSeconds.compareTo(a.durationSeconds);
      });
    final rows = sorted.take(12).toList(growable: false);
    if (rows.isEmpty) {
      return Text(
        'Noch keine auswertbaren Positionsfenster.',
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mindestzeit pro Bereich: ${_formatDurationSeconds(analysis.minimumReliableBinSeconds)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...rows.map(
          (bin) => _PoseSnoreRateRow(
            bin: bin,
            baselineProbability: analysis.baselineSnoreProbability,
          ),
        ),
      ],
    );
  }
}

class _PoseSnoreRateRow extends StatelessWidget {
  const _PoseSnoreRateRow({
    required this.bin,
    required this.baselineProbability,
  });

  final PoseSnoreBin bin;
  final double baselineProbability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final probability = bin.snoreProbability.clamp(0.0, 1.0);
    final aboveBaseline = probability >= baselineProbability;
    final color =
        aboveBaseline ? theme.colorScheme.error : const Color(0xFF2E9D72);

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  bin.rangeLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatPercent(probability),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: probability,
              minHeight: 8,
              color: color,
              backgroundColor:
                  theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Zeit ${_formatDurationSeconds(bin.durationSeconds)} | '
            'Schnarch ${_formatDurationSeconds(bin.snoreDurationSeconds)} | '
            'Relativ Drehung/Neigung ${_formatAngleCompact(bin.relativeRollCenterDeg)} / '
            '${_formatAngleCompact(bin.relativePitchCenterDeg)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _PoseAngleFeatureList extends StatelessWidget {
  const _PoseAngleFeatureList({required this.analysis});

  final PoseSnoreAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final features = analysis.angleFeatures
        .where((feature) => feature.hasData)
        .toList(growable: false);
    if (features.isEmpty) {
      return Text(
        'Noch keine Einzelwinkel-Verteilung vorhanden.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Jede Achse ist zeitnormalisiert. Die kombinierten Posen oben sind fuer Lagekombinationen aussagekraeftiger.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...features.map(
          (feature) => _PoseAngleFeatureRow(
            feature: feature,
            baselineProbability: analysis.baselineSnoreProbability,
          ),
        ),
      ],
    );
  }
}

class _PoseAngleFeatureRow extends StatelessWidget {
  const _PoseAngleFeatureRow({
    required this.feature,
    required this.baselineProbability,
  });

  final PoseAngleSnoreFeature feature;
  final double baselineProbability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = feature.topBins(limit: 3);
    if (top.isEmpty) return const SizedBox.shrink();
    final primary = top.first;
    final probability = primary.snoreProbability.clamp(0.0, 1.0);
    final aboveBaseline = probability >= baselineProbability;
    final color =
        aboveBaseline ? theme.colorScheme.error : const Color(0xFF2E9D72);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  feature.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              Text(
                _formatPercent(probability),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: probability,
              minHeight: 8,
              color: color,
              backgroundColor:
                  theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Top ${primary.rangeLabel} | '
            'Zeit ${_formatDurationSeconds(primary.durationSeconds)} | '
            'Schnarch ${_formatDurationSeconds(primary.snoreDurationSeconds)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (top.length > 1) ...[
            const SizedBox(height: 3),
            Text(
              top
                  .skip(1)
                  .map((bin) =>
                      '${bin.rangeLabel}: ${_formatPercent(bin.snoreProbability)}')
                  .join(' | '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _Mg24PosePreview extends StatefulWidget {
  const _Mg24PosePreview({
    required this.head,
    required this.chest,
    this.relativeYawDeg,
    required this.viewYawDeg,
    this.interactive = false,
  });

  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final double viewYawDeg;
  final bool interactive;

  @override
  State<_Mg24PosePreview> createState() => _Mg24PosePreviewState();
}

class _Mg24PosePreviewState extends State<_Mg24PosePreview> {
  late final Future<_Mg24BodyAssetMode> _modelAssetMode =
      _detectMg24BodyModelAssets();
  double _viewPitchDeg = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_Mg24BodyAssetMode>(
      future: _modelAssetMode,
      builder: (context, assets) {
        final assetMode = assets.data ?? _Mg24BodyAssetMode.none;
        late final Widget scene;
        if (assetMode == _Mg24BodyAssetMode.mesh) {
          scene = _Mg24MeshBodyScene(
            head: widget.head,
            chest: widget.chest,
            relativeYawDeg: widget.relativeYawDeg,
            headColor: const Color(0xFFE0822D),
            chestColor: theme.colorScheme.primary,
            outlineColor: theme.colorScheme.outlineVariant,
            viewYawDeg: widget.viewYawDeg,
            viewPitchDeg: _viewPitchDeg,
          );
        } else if (assetMode == _Mg24BodyAssetMode.body) {
          scene = _Mg24UpperBodyModelScene(
            head: widget.head,
            chest: widget.chest,
            relativeYawDeg: widget.relativeYawDeg,
            viewYawDeg: widget.viewYawDeg,
            viewPitchDeg: _viewPitchDeg,
          );
        } else if (assetMode == _Mg24BodyAssetMode.split) {
          scene = _Mg24BodyModelScene(
            head: widget.head,
            chest: widget.chest,
            relativeYawDeg: widget.relativeYawDeg,
            viewYawDeg: widget.viewYawDeg,
            viewPitchDeg: _viewPitchDeg,
          );
        } else {
          scene = CustomPaint(
            painter: _Mg24BodyPainter(
              head: widget.head,
              chest: widget.chest,
              relativeYawDeg: widget.relativeYawDeg,
              headColor: const Color(0xFFE0822D),
              chestColor: theme.colorScheme.primary,
              outlineColor: theme.colorScheme.outlineVariant,
              textColor: theme.colorScheme.onSurfaceVariant,
              viewYawDeg: widget.viewYawDeg,
              viewPitchDeg: _viewPitchDeg,
            ),
          );
        }
        if (!widget.interactive) return scene;
        return Stack(
          children: [
            Positioned.fill(child: scene),
            Positioned(
              left: 0,
              top: 4,
              bottom: 4,
              child: _VerticalViewSlider(
                value: _viewPitchDeg,
                onChangeStart: () {},
                onChanged: (value) => setState(() {
                  _viewPitchDeg = value;
                }),
                onChangeEnd: () {},
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: 'Ansicht zuruecksetzen',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.center_focus_strong, size: 17),
                onPressed: () => setState(() {
                  _viewPitchDeg = 0;
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AngleSnorePanel extends StatelessWidget {
  const _AngleSnorePanel({required this.analysis});

  final RelativeAngleSnoreAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final most = analysis.mostSnoredBin;
    final least = analysis.leastSnoredBin;
    final reliableBins = [...analysis.reliableBins]
      ..sort((a, b) => a.lowerDeg.compareTo(b.lowerDeg));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Relative Drehung und Schnarchen',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        if (!analysis.hasData)
          Text(
            'Noch keine gemeinsamen Winkel- und Schnarchdaten vorhanden.',
            style: theme.textTheme.bodySmall,
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _AngleSnoreHighlight(
                label: 'Am meisten',
                bin: most,
              ),
              _AngleSnoreHighlight(
                label: 'Am wenigsten',
                bin: least,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _angleSnoreRelevanceText(analysis),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (reliableBins.isEmpty)
            Text(
              'Noch zu wenige Messpunkte pro Winkelbereich.',
              style: theme.textTheme.bodySmall,
            )
          else
            ...reliableBins.map((bin) => _AngleSnoreBinRow(bin: bin)),
        ],
      ],
    );
  }
}

class _AngleSnoreHighlight extends StatelessWidget {
  const _AngleSnoreHighlight({
    required this.label,
    required this.bin,
  });

  final String label;
  final RelativeAngleSnoreBin? bin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = bin;
    return Container(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 240),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withValues(alpha: 0.62),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            current?.rangeLabel ?? '--',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 3),
          Text(
            current == null ? '--' : _formatPercent(current.snoreProbability),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AngleSnoreBinRow extends StatelessWidget {
  const _AngleSnoreBinRow({required this.bin});

  final RelativeAngleSnoreBin bin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final probability = bin.snoreProbability.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            child: Text(
              bin.rangeLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: probability,
                minHeight: 8,
                color: const Color(0xFFB4232A),
                backgroundColor:
                    theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 58,
            child: Text(
              _formatPercent(probability),
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 54,
            child: Text(
              'n=${bin.sampleCount}',
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({required this.records});

  final List<SleepSessionRecord> records;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = records.take(5).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Letzte Schlafzyklen', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: latest.map((record) {
              return Container(
                width: 112,
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.surface.withValues(alpha: 0.65),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatShortDate(record.metrics.startedAt),
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      record.score.toStringAsFixed(0),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _formatPercent(record.metrics.snoreTimeFraction),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }).toList(growable: false),
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _formatCalendarDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year}';
}

String _formatClockTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

int _secondsOfDay(DateTime value) =>
    value.hour * 3600 + value.minute * 60 + value.second;

DateTime? _clockTimeForPlotSecond(DateTime? startedAt, double timeS) {
  if (startedAt == null || !timeS.isFinite) return null;
  return startedAt.add(Duration(microseconds: (timeS * 1000000).round()));
}

String _formatPlotClockLabel(DateTime? startedAt, double timeS) {
  final time = _clockTimeForPlotSecond(startedAt, timeS);
  if (time == null) {
    return '${timeS.toStringAsFixed(timeS >= 100 ? 0 : 1)}s';
  }
  return _formatClockTime(time);
}

String _formatDuration(Duration duration) {
  final totalSeconds = math.max(0, duration.inSeconds);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
  return '${seconds}s';
}

String _formatShortDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}';
}

String _formatNumber(double? value, int digits) {
  return value == null || !value.isFinite
      ? '--'
      : value.toStringAsFixed(digits);
}

double? _relativeYawFromAngles(double? headYawDeg, double? chestYawDeg) {
  if (headYawDeg == null ||
      chestYawDeg == null ||
      !headYawDeg.isFinite ||
      !chestYawDeg.isFinite) {
    return null;
  }
  return 0;
}

String _formatPercent(double? fraction) {
  if (fraction == null || !fraction.isFinite) return '--';
  return '${(fraction * 100).toStringAsFixed(1)} %';
}

String _formatAngleCompact(double? value) {
  if (value == null || !value.isFinite) return '--';
  return '${_wrapAngleDeg(value).toStringAsFixed(0)} deg';
}

String _formatDurationSeconds(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '0 s';
  return _formatDuration(
    Duration(milliseconds: (seconds * 1000).round()),
  );
}

Mg24SensorSummary _poseSensor({
  required double rollDeg,
  required double pitchDeg,
  required double yawDeg,
}) {
  return const Mg24SensorSummary.empty().copyWith(
    connected: true,
    angleDeg: rollDeg,
    rollDeg: rollDeg,
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
  );
}

String _angleSnoreRelevanceText(RelativeAngleSnoreAnalysis analysis) {
  final correlation = analysis.correlation;
  final spread = analysis.probabilitySpread;
  final spreadText = spread == null
      ? ''
      : ' | Spanne ${(spread * 100).toStringAsFixed(1)} %-Punkte';
  if (correlation == null || !correlation.isFinite) {
    return 'Relevanz: r nicht berechenbar$spreadText';
  }

  final abs = correlation.abs();
  final strength = abs >= 0.50
      ? 'stark'
      : abs >= 0.30
          ? 'mittel'
          : abs >= 0.10
              ? 'schwach'
              : 'kaum';
  final direction = abs < 0.10
      ? 'keine klare Richtung'
      : correlation > 0
          ? 'hoeherer Winkel: mehr Schnarchen'
          : 'hoeherer Winkel: weniger Schnarchen';
  return 'Relevanz: r=${correlation.toStringAsFixed(2)} ($strength) | '
      '$direction$spreadText';
}

String _snoreSourceText(String source) {
  switch (source) {
    case 'wearer':
      return 'Traeger';
    case 'external':
      return 'andere';
    case 'mixed':
      return 'gemischt';
    default:
      return 'unklar';
  }
}

String _snoreStateSourceValue(SnoreState snore) {
  if (!_homeSnorePhaseRecent(snore)) return '--';
  return _snoreSourceText(snore.source);
}

String _snoreStateSourceUnit(SnoreState snore) {
  if (!_homeSnorePhaseRecent(snore) ||
      snore.source == 'unknown' ||
      snore.sourceConfidence <= 0) {
    return '';
  }
  return '${(snore.sourceConfidence * 100).clamp(0, 99).toStringAsFixed(0)}%';
}

bool _homeSnorePhaseRecent(SnoreState snore) {
  if (snore.isSnoring || snore.detectedNow || snore.snoreBurstActive) {
    return true;
  }
  final windowCenterAt = snore.windowCenterAt;
  if (windowCenterAt == null) return false;
  final hasConfirmedWindow =
      snore.snoreBreathWidthMs != null || snore.snoreActiveWidthMs != null;
  final hasAudioEvidence = snore.backend != 'none' && snore.score > 0;
  if (!hasConfirmedWindow && !hasAudioEvidence) return false;
  final age = DateTime.now().difference(windowCenterAt);
  return !age.isNegative && age <= const Duration(seconds: 10);
}

String _homeSnorePhaseValue(SnoreState snore) {
  return _homeSnorePhaseRecent(snore) ? 'ja' : 'nein';
}

String _homeSnorePhaseUnit(SnoreState snore) {
  if (!_homeSnorePhaseRecent(snore)) return '10s';
  final source = _snoreSourceText(snore.source);
  if (snore.source == 'unknown' || snore.sourceConfidence <= 0) {
    return source;
  }
  final confidence =
      (snore.sourceConfidence * 100).clamp(0, 99).toStringAsFixed(0);
  return '$source $confidence%';
}

String _snoreBreathWindowValue(SnoreState snore) {
  final center = snore.windowCenterAt;
  final widthMs = snore.snoreBurstActive
      ? snore.snoreActiveWidthMs
      : snore.snoreBreathWidthMs;
  if (center != null && widthMs != null && widthMs.isFinite && widthMs > 0) {
    final halfWidth = Duration(microseconds: (widthMs * 500).round());
    final start = center.subtract(halfWidth);
    final end = center.add(halfWidth);
    return '${_formatClockTime(start)}-${_formatClockTime(end)}';
  }
  if (snore.snoreBurstActive) return 'aktiv';
  if (snore.snoreBreathWidthMs != null) return 'letzte';
  return '--';
}

String _snoreBreathWindowUnit(SnoreState snore) {
  final widthMs = snore.snoreBurstActive
      ? snore.snoreActiveWidthMs
      : snore.snoreBreathWidthMs;
  if (widthMs == null || !widthMs.isFinite || widthMs <= 0) return '';
  final state = snore.snoreBurstActive ? 'aktiv' : 'letzte';
  return '$state ${(widthMs / 1000.0).toStringAsFixed(2)}s';
}

String _homeSnoreBreathValue(SnoreState snore) {
  return snore.snoreBurstActive ? 'aktiv' : 'nein';
}

String _homeSnoreBreathUnit(SnoreState snore) {
  final widthMs = snore.snoreBurstActive
      ? snore.snoreActiveWidthMs
      : snore.snoreBreathWidthMs;
  if (widthMs == null || !widthMs.isFinite || widthMs <= 0) {
    return snore.snoreBurstActive ? '' : 'kein letzter';
  }
  final seconds = (widthMs / 1000.0).toStringAsFixed(2);
  return snore.snoreBurstActive ? '$seconds s' : 'letzte $seconds s';
}

class _SnorePositionGrid extends StatelessWidget {
  const _SnorePositionGrid({required this.snapshot});

  final MeasurementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final volume = snoreVolumePercent(snapshot.snore);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        const tileCount = 7;
        final width = wide
            ? (constraints.maxWidth - 10 * (tileCount - 1)) / tileCount
            : math.max(150.0, (constraints.maxWidth - 10) / 2);
        final tiles = [
          MetricTile(
            width: width,
            label: 'Schnarchen',
            value: snapshot.snore.isSnoring ? 'ja' : 'nein',
            unit: snapshot.snore.backend == 'yamnet'
                ? 'YAMNet'
                : snapshot.snore.backend == 'mg24'
                    ? 'MG24 ${(snapshot.snore.score * 100).clamp(0, 99).toStringAsFixed(0)}%'
                    : '',
          ),
          MetricTile(
            width: width,
            label: 'Lautstaerke',
            value: volume == null ? '--' : volume.toStringAsFixed(0),
            unit: volume == null ? '' : '%',
          ),
          MetricTile(
            width: width,
            label: 'Quelle',
            value: _snoreStateSourceValue(snapshot.snore),
            unit: _snoreStateSourceUnit(snapshot.snore),
          ),
          MetricTile(
            width: width,
            label: 'Schnarchzug',
            value: _snoreBreathWindowValue(snapshot.snore),
            unit: _snoreBreathWindowUnit(snapshot.snore),
          ),
          MetricTile(
            width: width,
            label: 'Muster',
            value: snapshot.snore.patternQuality == null
                ? '--'
                : (snapshot.snore.patternQuality! * 100)
                    .clamp(0, 99)
                    .toStringAsFixed(0),
            unit: snapshot.snore.patternQuality == null ? '' : '%',
          ),
          MetricTile(
            width: width,
            label: 'Schnarchfreq.',
            value: snapshot.snore.snoreRatePerMin == null
                ? '--'
                : snapshot.snore.snoreRatePerMin!.toStringAsFixed(1),
            unit: snapshot.snore.snoreRatePerMin == null ? '' : '/min',
          ),
          MetricTile(
            width: width,
            label: 'Rel. Drehung',
            value: snapshot.orientation.relativeAngleDeg.toStringAsFixed(1),
            unit: 'deg',
          ),
        ];
        return Wrap(spacing: 10, runSpacing: 10, children: tiles);
      },
    );
  }
}

class _SnoreTimelinePanel extends StatefulWidget {
  const _SnoreTimelinePanel({required this.snapshot});

  final MeasurementSnapshot snapshot;

  @override
  State<_SnoreTimelinePanel> createState() => _SnoreTimelinePanelState();
}

class _SnoreTimelinePanelState extends State<_SnoreTimelinePanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;
    final now = DateTime.now();
    final segments = snapshot.snoreTimeline;
    final totalDuration = segments.fold<Duration>(
      Duration.zero,
      (total, segment) => total + segment.duration(now),
    );
    final active = segments.any((segment) => segment.active);
    final summary = segments.isEmpty
        ? 'Keine Phasen'
        : '${segments.length} Phasen | ${_formatDuration(totalDuration)}';

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.timeline,
                    color: active
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Schnarch-Zusammenfassung',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          active ? '$summary | aktiv' : summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _SnoreTimelineDetails(
                snapshot: snapshot,
                referenceTime: now,
              ),
            ),
        ],
      ),
    );
  }
}

class _SnoreTimelineDetails extends StatelessWidget {
  const _SnoreTimelineDetails({
    required this.snapshot,
    required this.referenceTime,
  });

  final MeasurementSnapshot snapshot;
  final DateTime referenceTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = snapshot.snoreTimeline;
    final startedAt = snapshot.measurementStartedAt ??
        (segments.isEmpty ? null : segments.first.startedAt);
    if (startedAt == null) {
      return Text(
        'Noch keine Messung gestartet.',
        style: theme.textTheme.bodySmall,
      );
    }

    final endedAt = snapshot.running
        ? referenceTime
        : _lastTimelineTime(segments) ?? referenceTime;
    final recent = segments.reversed.take(6).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 58,
          width: double.infinity,
          child: CustomPaint(
            painter: _SnoreTimelinePainter(
              startedAt: startedAt,
              endedAt: endedAt,
              referenceTime: referenceTime,
              segments: segments,
              baseColor: theme.colorScheme.outlineVariant,
              snoreColor: theme.colorScheme.error,
              activeColor: theme.colorScheme.tertiary,
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatClockTime(startedAt), style: theme.textTheme.bodySmall),
            Text(_formatClockTime(endedAt), style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 8),
        if (segments.isEmpty)
          Text(
            'Noch keine Schnarchphasen erkannt.',
            style: theme.textTheme.bodySmall,
          )
        else
          ...recent.map(
            (segment) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Icon(
                    segment.active ? Icons.graphic_eq : Icons.bedtime,
                    size: 16,
                    color: segment.active
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_formatClockTime(segment.startedAt)} - '
                      '${segment.endedAt == null ? 'jetzt' : _formatClockTime(segment.endedAt!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '${_formatDuration(segment.duration(referenceTime))} | '
                    '${_snoreSourceText(segment.source)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  DateTime? _lastTimelineTime(List<SnoreTimelineSegment> segments) {
    if (segments.isEmpty) return snapshot.measurementStartedAt;
    return segments
        .map((segment) => segment.endedAt ?? referenceTime)
        .reduce((a, b) => a.isAfter(b) ? a : b);
  }
}

class _SnoreTimelinePainter extends CustomPainter {
  const _SnoreTimelinePainter({
    required this.startedAt,
    required this.endedAt,
    required this.referenceTime,
    required this.segments,
    required this.baseColor,
    required this.snoreColor,
    required this.activeColor,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final DateTime referenceTime;
  final List<SnoreTimelineSegment> segments;
  final Color baseColor;
  final Color snoreColor;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final baselinePaint = Paint()..color = baseColor.withValues(alpha: 0.55);
    final snorePaint = Paint()..color = snoreColor.withValues(alpha: 0.85);
    final activePaint = Paint()..color = activeColor.withValues(alpha: 0.85);
    final centerY = size.height / 2;
    final baseRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - 4, size.width, 8),
      const Radius.circular(4),
    );
    canvas.drawRRect(baseRect, baselinePaint);

    final totalMs =
        math.max(1, endedAt.difference(startedAt).inMilliseconds).toDouble();
    for (final segment in segments) {
      final segmentEnd = segment.endedAt ?? referenceTime;
      final startMs = segment.startedAt.difference(startedAt).inMilliseconds;
      final endMs = segmentEnd.difference(startedAt).inMilliseconds;
      if (endMs <= 0 || startMs >= totalMs) continue;
      final clampedStart = startMs.clamp(0, totalMs).toDouble();
      final clampedEnd = endMs.clamp(0, totalMs).toDouble();
      final x1 = size.width * clampedStart / totalMs;
      final x2 = size.width * clampedEnd / totalMs;
      final width = math.max(3.0, x2 - x1);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x1, centerY - 14, width, 28),
        const Radius.circular(6),
      );
      canvas.drawRRect(rect, segment.active ? activePaint : snorePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SnoreTimelinePainter oldDelegate) {
    return oldDelegate.startedAt != startedAt ||
        oldDelegate.endedAt != endedAt ||
        oldDelegate.referenceTime != referenceTime ||
        oldDelegate.segments != segments ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.snoreColor != snoreColor ||
        oldDelegate.activeColor != activeColor;
  }
}

class _Mg24Panel extends StatelessWidget {
  const _Mg24Panel({
    required this.controller,
    required this.snapshot,
    required this.onBodyInteractionChanged,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;
  final ValueChanged<bool> onBodyInteractionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mg24 = snapshot.mg24;
    final connecting = controller.mg24Connecting ||
        mg24.scanning ||
        mg24.forehead.connecting ||
        mg24.belly.connecting;
    final disconnecting = controller.mg24Disconnecting;
    final canConnect = !controller.stopping &&
        !connecting &&
        !disconnecting &&
        (controller.measurementActive
            ? controller.missingMeasurementSensorLabels.isNotEmpty
            : !mg24.ready);
    final canDisconnect = !controller.stopping &&
        !disconnecting &&
        (mg24.connected || connecting);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth_connected,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Seeed XIAO MG24 Sense',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed:
                      canConnect ? () => controller.connectMg24Sensors() : null,
                  icon: connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(
                    connecting ? 'Verbinde ...' : 'Sensoren suchen',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: canDisconnect
                      ? () => controller.disconnectMg24Sensors()
                      : null,
                  icon: Icon(connecting ? Icons.close : Icons.link_off),
                  label: Text(
                    connecting
                        ? 'Abbrechen'
                        : disconnecting
                            ? 'Trenne ...'
                            : 'Trennen',
                  ),
                ),
              ],
            ),
            if (controller.hasRecoverableBoardArchive) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: controller.stopping
                    ? null
                    : controller.recoverLatestBoardMeasurement,
                icon: const Icon(Icons.restore),
                label: const Text('Board-Archiv ins Journal uebernehmen'),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              mg24.status,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            _Mg24SensorPowerOverview(mg24: mg24),
            const SizedBox(height: 10),
            SegmentedButton<Mg24LiveMode>(
              segments: const [
                ButtonSegment(
                  value: Mg24LiveMode.valuesOnly,
                  label: Text('Messwerte'),
                  icon: Icon(Icons.speed, size: 17),
                ),
                ButtonSegment(
                  value: Mg24LiveMode.valuesAndPlots,
                  label: Text('Messwerte + Signale'),
                  icon: Icon(Icons.monitor_heart, size: 17),
                ),
              ],
              selected: {controller.mg24LiveMode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  controller.setMg24LiveMode(selection.first);
                }
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Mg24SensorPill(
                  label: 'Stirn',
                  sensor: mg24.forehead,
                ),
                _Mg24SensorPill(
                  label: 'Bauch',
                  sensor: mg24.belly,
                ),
                _InfoPill(
                  label: 'MAX30102',
                  value: _formatMax30102State(mg24),
                  valueColor: _max30102StatusColor(context, mg24),
                ),
                _InfoPill(
                  label: 'Ohrtemp',
                  value:
                      _formatTemperatureCompact(mg24.forehead.earTemperatureC),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SnoreTrainingControls(
              controller: controller,
              recordingAvailable: mg24.forehead.connected,
            ),
            if (mg24.connected) ...[
              const SizedBox(height: 12),
              _Mg24PoseOverview(
                mg24: mg24,
                relativeYawDeg: snapshot.orientation.relativeYawDeg,
                onResetPose: controller.calibrateMg24PoseNow,
                onBodyInteractionChanged: onBodyInteractionChanged,
              ),
              const SizedBox(height: 10),
              _Mg24RespirationOverview(
                mg24: mg24,
                samples: snapshot.samples,
                peaks: snapshot.breathPeaks,
                snoreBreathWindows: snapshot.snoreBreathWindows,
                inhaleBreathWindows: snapshot.inhaleBreathWindows,
                recentSnoreAssessments: snapshot.recentSnoreAssessments,
                measurementStartedAt: snapshot.measurementStartedAt,
                plotLatencySeconds: snapshot.breathingPlotLatencySeconds,
                showPlot:
                    controller.mg24LiveMode == Mg24LiveMode.valuesAndPlots,
              ),
              const SizedBox(height: 10),
              _Mg24OximeterOverview(
                mg24: mg24,
                showPlot:
                    controller.mg24LiveMode == Mg24LiveMode.valuesAndPlots,
              ),
              if (controller.mg24LiveMode == Mg24LiveMode.valuesAndPlots) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoPill(
                      label: 'MAX Plotpakete verloren',
                      value: _formatLoss(mg24.forehead.plotPacketLossPercent),
                    ),
                    _InfoPill(
                      label: 'MAX Zwischenwerte verloren',
                      value: _formatLoss(mg24.forehead.plotSampleLossPercent),
                    ),
                    _InfoPill(
                      label: 'IMU Plotpakete verloren',
                      value: _formatLoss(mg24.belly.plotPacketLossPercent),
                    ),
                    _InfoPill(
                      label: 'IMU Zwischenwerte verloren',
                      value: _formatLoss(mg24.belly.plotSampleLossPercent),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _formatLoss(double? value) =>
    value == null ? '--' : '${value.toStringAsFixed(2)} %';

class _SnoreTrainingControls extends StatelessWidget {
  const _SnoreTrainingControls({
    required this.controller,
    required this.recordingAvailable,
  });

  final MeasurementController controller;
  final bool recordingAvailable;

  @override
  Widget build(BuildContext context) {
    final active = controller.snoreTrainingActive;
    final activeLabel = controller.snoreTrainingLabel;
    final windowActive = controller.snoreTrainingWindowActive;
    final windowId = controller.snoreTrainingWindowId;
    final automaticTeacher = controller.snoreAutomaticTeacherMode;
    final yamnetMonitoring = controller.developerYamnetMonitorActive;
    final sync = controller.snoreTeacherSyncEstimate;
    Widget button(String label, IconData icon) {
      final selected = active && activeLabel == label;
      return OutlinedButton.icon(
        onPressed: !selected && !recordingAvailable
            ? null
            : () async {
                if (selected) {
                  await controller.stopSnoreTraining();
                } else {
                  await controller.startSnoreTraining(label);
                }
              },
        icon: Icon(selected ? Icons.stop : icon, size: 17),
        label: Text(selected ? 'Stop $label' : label),
      );
    }

    final recordings = controller.snoreTrainingRecordings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _InfoPill(
              label: 'Board Schnarchen',
              value: controller.boardSnoreDetected ? 'ja' : 'nein',
              valueColor: controller.boardSnoreDetected
                  ? Theme.of(context).colorScheme.error
                  : const Color(0xFF63D39A),
            ),
            _InfoPill(
              label: 'YAMNet Schnarchen',
              value: controller.yamnetSnoreDetected == null
                  ? 'aus'
                  : controller.yamnetSnoreDetected!
                      ? 'ja'
                      : 'nein',
              valueColor: controller.yamnetSnoreDetected == true
                  ? Theme.of(context).colorScheme.error
                  : controller.yamnetSnoreDetected == false
                      ? const Color(0xFF63D39A)
                      : Theme.of(context).colorScheme.outline,
            ),
            if (controller.yamnetSnoreScorePercent != null)
              _InfoPill(
                label: 'YAMNet Score',
                value:
                    '${controller.yamnetSnoreScorePercent!.toStringAsFixed(0)}%',
              ),
            if (controller.yamnetBreathingScorePercent != null)
              _InfoPill(
                label: 'Atmen',
                value:
                    '${controller.yamnetBreathingScorePercent!.toStringAsFixed(0)}%',
              ),
            if (controller.yamnetWindScorePercent != null)
              _InfoPill(
                label: 'Wind/Pusten',
                value:
                    '${controller.yamnetWindScorePercent!.toStringAsFixed(0)}%',
              ),
            if (controller.yamnetVoiceScorePercent != null)
              _InfoPill(
                label: 'Sprache',
                value:
                    '${controller.yamnetVoiceScorePercent!.toStringAsFixed(0)}%',
              ),
            if (controller.yamnetInputGainDb != null)
              _InfoPill(
                label: 'Auto-Pegel',
                value:
                    '+${controller.yamnetInputGainDb!.toStringAsFixed(0)} dB',
              ),
            if (controller.yamnetRejectionReason != null &&
                controller.yamnetSnoreScorePercent != null &&
                controller.yamnetSnoreScorePercent! >= 8)
              _InfoPill(
                label: 'Blockiert als',
                value: controller.yamnetRejectionReason!,
              ),
            OutlinedButton.icon(
              onPressed:
                  active || controller.developerYamnetMonitorStartInProgress
                      ? null
                      : yamnetMonitoring
                          ? controller.stopDeveloperYamnetMonitor
                          : controller.startDeveloperYamnetMonitor,
              icon: controller.developerYamnetMonitorStartInProgress
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(yamnetMonitoring ? Icons.stop : Icons.hearing),
              label: Text(
                yamnetMonitoring ? 'YAMNet Live stoppen' : 'YAMNet Live',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            button('ruhe', Icons.volume_off),
            button('sprechen', Icons.record_voice_over),
            button('schnarchen', Icons.air),
            button('kratzen', Icons.gesture),
            FilledButton.icon(
              onPressed: !recordingAvailable && !automaticTeacher
                  ? null
                  : () async {
                      if (active && automaticTeacher) {
                        await controller.stopSnoreTraining();
                      } else {
                        await controller.startAutomaticYamnetTraining();
                      }
                    },
              icon: Icon(
                active && automaticTeacher ? Icons.stop : Icons.auto_awesome,
                size: 17,
              ),
              label: Text(
                active && automaticTeacher
                    ? 'YAMNet-Training stoppen'
                    : 'YAMNet-Training',
              ),
            ),
            if (active && !automaticTeacher)
              FilledButton.icon(
                onPressed: controller.snoreMelTransportReady
                    ? controller.toggleSnoreTrainingWindow
                    : null,
                icon: Icon(
                  windowActive
                      ? Icons.stop_circle_outlined
                      : Icons.fiber_manual_record,
                  size: 17,
                ),
                label: Text(
                  windowActive ? 'Fenster Ende' : 'Fenster Start',
                ),
              ),
            if (active && activeLabel != null)
              Text(
                automaticTeacher
                    ? 'YAMNet setzt die Schnarchfenster automatisch'
                    : windowActive
                        ? 'Training: $activeLabel | Fenster $windowId'
                        : 'Training: $activeLabel',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (active)
              Text(
                !controller.snoreMelTransportReady
                    ? controller.snoreMelPreflightSliceCount == 0
                        ? 'Log-Mel: Initialisierung und Datenratenpruefung'
                        : 'Log-Mel: Datenrate wird geprueft '
                            '(${controller.snoreMelPreflightSliceCount} Testslices'
                            '${controller.snoreMelPreflightRetryCount == 0 ? '' : ', Versuch ${controller.snoreMelPreflightRetryCount + 1}'})'
                    : 'Log-Mel: bereit | ${controller.snoreMelSliceCount} Slices'
                        ' | fehlend: ${controller.snoreMelDroppedSliceCount}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: !controller.snoreMelTransportReady
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : controller.snoreMelDroppedSliceCount == 0
                              ? const Color(0xFF63D39A)
                              : Theme.of(context).colorScheme.error,
                    ),
              ),
            if (active && controller.latestSnoreMelModelScorePercent != null)
              Text(
                'Board-ML ${controller.latestSnoreMelModelTrusted ? '' : '(Shadow) '}'
                '${controller.latestSnoreMelModelScorePercent}%'
                '${controller.latestSnoreMelModelActive ? ' | aktiv' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (active && automaticTeacher)
              Text(
                !sync.ready
                    ? 'Synchronisierung: wartet auf gemeinsame Audiodaten'
                    : 'Synchronisierung: ${sync.method} '
                        '+/-${sync.errorMs?.toStringAsFixed(0) ?? '--'} ms'
                        '${sync.correlation == null ? '' : ' | r=${sync.correlation!.toStringAsFixed(2)}'}'
                        ' | Fenster ${controller.automaticTeacherWindowCount}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: sync.ready
                          ? const Color(0xFF63D39A)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          leading: const Icon(Icons.library_music_outlined, size: 20),
          title: Row(
            children: [
              Expanded(
                child: Text('Trainingsaufnahmen (${recordings.length})'),
              ),
              if (controller.snoreTrainingRecordingsLoading)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else ...[
                IconButton(
                  tooltip: 'Trainingsdaten exportieren',
                  onPressed:
                      controller.exportSnoreTrainingRecordingsForAnalysis,
                  icon: const Icon(Icons.download_outlined),
                ),
                IconButton(
                  tooltip: 'Liste aktualisieren',
                  onPressed: controller.refreshSnoreTrainingRecordings,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ],
          ),
          children: [
            if (recordings.isEmpty &&
                !controller.snoreTrainingRecordingsLoading)
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('Keine Trainingsaufnahmen gespeichert'),
              ),
            for (final recording in recordings)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_trainingRecordingIcon(recording.label)),
                title: Text(_trainingRecordingLabel(recording.label)),
                subtitle: Text(
                  '${_formatTrainingRecordedAt(recording.recordedAt)} | '
                  '${_formatTrainingFileSize(recording.sizeBytes)}',
                ),
                trailing: IconButton(
                  tooltip: 'Aufnahme loeschen',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Trainingsaufnahme loeschen?'),
                        content: Text(
                          '${_trainingRecordingLabel(recording.label)} vom '
                          '${_formatTrainingRecordedAt(recording.recordedAt)} '
                          'wird dauerhaft entfernt.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: const Text('Abbrechen'),
                          ),
                          FilledButton.icon(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Loeschen'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await controller.deleteSnoreTrainingRecording(
                        recording.fileName,
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}

IconData _trainingRecordingIcon(String label) {
  return switch (label.toLowerCase()) {
    'ruhe' => Icons.volume_off,
    'sprechen' => Icons.record_voice_over,
    'schnarchen' => Icons.air,
    'kratzen' => Icons.gesture,
    'yamnet_teacher' => Icons.auto_awesome,
    _ => Icons.graphic_eq,
  };
}

String _trainingRecordingLabel(String label) {
  if (label.isEmpty) return 'Unbekannt';
  if (label.toLowerCase() == 'yamnet_teacher') {
    return 'Automatisches YAMNet-Training';
  }
  return '${label[0].toUpperCase()}${label.substring(1)}';
}

String _formatTrainingRecordedAt(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _formatTrainingFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kibibytes = bytes / 1024.0;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} KB';
  return '${(kibibytes / 1024.0).toStringAsFixed(1)} MB';
}

String _formatMax30102State(Mg24State mg24) {
  final connected = mg24.max30102Connected;
  if (connected == null) return 'wird geprueft';
  if (!connected) return 'nicht erkannt';
  final bus = mg24.max30102Bus;
  return bus == null || bus == 0 ? 'erkannt' : 'erkannt | Bus $bus';
}

Color _max30102StatusColor(BuildContext context, Mg24State mg24) {
  final connected = mg24.max30102Connected;
  final scheme = Theme.of(context).colorScheme;
  if (connected == false) return scheme.error;
  if (connected == true) return scheme.primary;
  return scheme.outline;
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Text(
        '$label: $value',
        style: theme.textTheme.bodySmall?.copyWith(color: valueColor),
      ),
    );
  }
}

class _Mg24SensorPowerOverview extends StatelessWidget {
  const _Mg24SensorPowerOverview({required this.mg24});

  final Mg24State mg24;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final tiles = [
          _Mg24SensorPowerTile(label: 'Stirn', sensor: mg24.forehead),
          _Mg24SensorPowerTile(label: 'Bauch', sensor: mg24.belly),
        ];
        if (compact) {
          return Column(
            children: [
              tiles[0],
              const SizedBox(height: 8),
              tiles[1],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 8),
            Expanded(child: tiles[1]),
          ],
        );
      },
    );
  }
}

class _Mg24SensorPowerTile extends StatelessWidget {
  const _Mg24SensorPowerTile({
    required this.label,
    required this.sensor,
  });

  final String label;
  final Mg24SensorSummary sensor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _mg24SensorPowerStatus(sensor);
    final color = _mg24SensorPowerColor(theme, status);
    final icon = _mg24SensorPowerIcon(status);
    final archiveText = _formatArchiveCompact(sensor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _mg24SensorPowerLabel(status),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (archiveText != null)
                Text(
                  archiveText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Mg24SensorPowerStatus {
  disconnected,
  connecting,
  recording,
  liveActive,
  standby,
  unknown,
}

_Mg24SensorPowerStatus _mg24SensorPowerStatus(Mg24SensorSummary sensor) {
  if (sensor.connecting) return _Mg24SensorPowerStatus.connecting;
  if (!sensor.connected) return _Mg24SensorPowerStatus.disconnected;
  if (sensor.recording == true) return _Mg24SensorPowerStatus.recording;
  if (sensor.sensorsEnabled == false) return _Mg24SensorPowerStatus.standby;
  if (sensor.sensorsEnabled == true) return _Mg24SensorPowerStatus.liveActive;
  return _Mg24SensorPowerStatus.unknown;
}

String _mg24SensorPowerLabel(_Mg24SensorPowerStatus status) {
  return switch (status) {
    _Mg24SensorPowerStatus.disconnected => 'nicht verbunden',
    _Mg24SensorPowerStatus.connecting => 'verbindet',
    _Mg24SensorPowerStatus.recording => 'Board-Messung laeuft',
    _Mg24SensorPowerStatus.liveActive => 'Live aktiv',
    _Mg24SensorPowerStatus.standby => 'Standby, Sensorik aus',
    _Mg24SensorPowerStatus.unknown => 'Status unbekannt',
  };
}

IconData _mg24SensorPowerIcon(_Mg24SensorPowerStatus status) {
  return switch (status) {
    _Mg24SensorPowerStatus.disconnected => Icons.link_off,
    _Mg24SensorPowerStatus.connecting => Icons.sync,
    _Mg24SensorPowerStatus.recording => Icons.fiber_manual_record,
    _Mg24SensorPowerStatus.liveActive => Icons.sensors,
    _Mg24SensorPowerStatus.standby => Icons.power_settings_new,
    _Mg24SensorPowerStatus.unknown => Icons.help_outline,
  };
}

Color _mg24SensorPowerColor(ThemeData theme, _Mg24SensorPowerStatus status) {
  return switch (status) {
    _Mg24SensorPowerStatus.recording => const Color(0xFFE0822D),
    _Mg24SensorPowerStatus.liveActive => theme.colorScheme.primary,
    _Mg24SensorPowerStatus.standby => const Color(0xFF48A868),
    _Mg24SensorPowerStatus.connecting => const Color(0xFFE0A22D),
    _Mg24SensorPowerStatus.unknown => theme.colorScheme.tertiary,
    _Mg24SensorPowerStatus.disconnected => theme.colorScheme.outline,
  };
}

String? _formatArchiveCompact(Mg24SensorSummary sensor) {
  final records = sensor.archiveRecords;
  if (records == null || records <= 0) return null;
  final capacity = sensor.archiveCapacity;
  if (capacity == null || capacity <= 0) return '$records Min';
  return '$records/$capacity Min';
}

class _Mg24SensorPill extends StatelessWidget {
  const _Mg24SensorPill({
    required this.label,
    required this.sensor,
    this.measurementExpected = false,
    this.activeSessionConfirmed = false,
  });

  final String label;
  final Mg24SensorSummary sensor;
  final bool measurementExpected;
  final bool activeSessionConfirmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final operatingStatus = _mg24SensorPowerStatus(sensor);
    final measurementMismatch = measurementExpected &&
        sensor.connected &&
        !activeSessionConfirmed &&
        sensor.recordingArmed != true;
    final signalColor = measurementMismatch
        ? theme.colorScheme.error
        : _mg24ConnectionColor(theme, sensor, operatingStatus);
    final statusLabel = measurementExpected
        ? !sensor.connected
            ? 'Messung offline'
            : activeSessionConfirmed
                ? 'Messung'
                : sensor.recordingArmed == true
                    ? 'vorbereitet'
                    : 'misst nicht'
        : _mg24SensorCompactStatus(operatingStatus, sensor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 7),
          _SignalBars(
            level: _mg24ConnectionLevel(sensor),
            color: signalColor,
          ),
          const SizedBox(width: 7),
          _BatteryIndicator(sensor: sensor),
          const SizedBox(width: 7),
          Text(
            statusLabel,
            style: theme.textTheme.bodySmall?.copyWith(color: signalColor),
          ),
        ],
      ),
    );
  }
}

class _BatteryIndicator extends StatelessWidget {
  const _BatteryIndicator({required this.sensor});

  final Mg24SensorSummary sensor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = sensor.batteryPercent;
    final connected = sensor.connected || sensor.connecting;
    final color = _batteryIndicatorColor(theme, percent, connected);
    final clampedPercent = percent?.clamp(0, 100).toDouble();
    final label = clampedPercent != null && clampedPercent.isFinite
        ? '${clampedPercent.toStringAsFixed(0)}%'
        : '--';
    return SizedBox(
      width: 42,
      height: 22,
      child: CustomPaint(
        painter: _BatteryIndicatorPainter(
          color: color,
          fillFraction: clampedPercent == null || !connected
              ? null
              : clampedPercent / 100,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Text(
              label,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatteryIndicatorPainter extends CustomPainter {
  const _BatteryIndicatorPainter({
    required this.color,
    required this.fillFraction,
  });

  final Color color;
  final double? fillFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 3.5, size.width - 6, size.height - 7),
      const Radius.circular(4),
    );
    final nub = RRect.fromRectAndRadius(
      Rect.fromLTWH(
          size.width - 5, size.height * 0.36, 4.5, size.height * 0.28),
      const Radius.circular(2),
    );
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.86)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    canvas.drawRRect(body, stroke);
    canvas.drawRRect(nub, stroke);

    final fraction = fillFraction;
    if (fraction == null || !fraction.isFinite || fraction <= 0) return;
    final fillRect = Rect.fromLTWH(
      body.left + 2,
      body.top + 2,
      (body.width - 4) * fraction.clamp(0.0, 1.0),
      body.height - 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(fillRect, const Radius.circular(2.5)),
      Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _BatteryIndicatorPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.fillFraction != fillFraction;
  }
}

Color _batteryIndicatorColor(
  ThemeData theme,
  double? percent,
  bool connected,
) {
  if (!connected) return theme.colorScheme.outline;
  if (percent == null || !percent.isFinite) {
    return theme.colorScheme.onSurfaceVariant;
  }
  if (percent <= 12) return theme.colorScheme.error;
  if (percent <= 25) return const Color(0xFFE0A22D);
  return theme.colorScheme.primary;
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({
    required this.level,
    required this.color,
  });

  final int level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final inactive =
        Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55);
    return SizedBox(
      width: 18,
      height: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 3,
              height: 4.0 + i * 3.0,
              decoration: BoxDecoration(
                color: level > i ? color : inactive,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

int _mg24ConnectionLevel(Mg24SensorSummary sensor) {
  if (sensor.connecting) return 1;
  if (!sensor.connected) return 0;
  final rssi = sensor.rssi;
  if (rssi == null || rssi >= 0) return sensor.hasData ? 3 : 2;
  if (rssi >= -67) return 4;
  if (rssi >= -78) return 3;
  if (rssi >= -88) return 2;
  return 1;
}

Color _mg24ConnectionColor(
  ThemeData theme,
  Mg24SensorSummary sensor,
  _Mg24SensorPowerStatus status,
) {
  if (!sensor.connected && !sensor.connecting) {
    return theme.colorScheme.outline;
  }
  final rssi = sensor.rssi;
  if (rssi != null && rssi < 0) {
    if (rssi <= -92) return theme.colorScheme.error;
    if (rssi <= -82) return const Color(0xFFE0A22D);
  }
  return _mg24SensorPowerColor(theme, status);
}

String _mg24SensorCompactStatus(
  _Mg24SensorPowerStatus status,
  Mg24SensorSummary sensor,
) {
  if (sensor.connecting) return 'verbindet';
  return switch (status) {
    _Mg24SensorPowerStatus.disconnected => 'offen',
    _Mg24SensorPowerStatus.connecting => 'verbindet',
    _Mg24SensorPowerStatus.recording => 'Messung',
    _Mg24SensorPowerStatus.liveActive => sensor.hasData ? 'live' : 'warte',
    _Mg24SensorPowerStatus.standby => 'standby',
    _Mg24SensorPowerStatus.unknown => sensor.connected ? 'verbunden' : 'offen',
  };
}

const _bodyViewPitchMinDeg = -180.0;
const _bodyViewPitchMaxDeg = 180.0;

class _Mg24PoseOverview extends StatelessWidget {
  const _Mg24PoseOverview({
    required this.mg24,
    required this.relativeYawDeg,
    required this.onResetPose,
    required this.onBodyInteractionChanged,
    this.showPowerAndTemperature = true,
    this.summaryLine,
  });

  final Mg24State mg24;
  final double? relativeYawDeg;
  final VoidCallback? onResetPose;
  final ValueChanged<bool> onBodyInteractionChanged;
  final bool showPowerAndTemperature;
  final String? summaryLine;

  @override
  Widget build(BuildContext context) {
    return _Mg24BodyOverview(
      mg24: mg24,
      relativeYawDeg: relativeYawDeg,
      onResetPose: onResetPose,
      onInteractionChanged: onBodyInteractionChanged,
      showPowerAndTemperature: showPowerAndTemperature,
      summaryLine: summaryLine,
    );
  }
}

class _Mg24BodyOverview extends StatefulWidget {
  const _Mg24BodyOverview({
    required this.mg24,
    required this.relativeYawDeg,
    required this.onResetPose,
    required this.onInteractionChanged,
    required this.showPowerAndTemperature,
    this.summaryLine,
  });

  final Mg24State mg24;
  final double? relativeYawDeg;
  final VoidCallback? onResetPose;
  final ValueChanged<bool> onInteractionChanged;
  final bool showPowerAndTemperature;
  final String? summaryLine;

  @override
  State<_Mg24BodyOverview> createState() => _Mg24BodyOverviewState();
}

class _Mg24BodyOverviewState extends State<_Mg24BodyOverview> {
  late final Future<_Mg24BodyAssetMode> _modelAssetMode;
  static const double _viewYawDeg = 0;
  double _viewPitchDeg = 0;
  bool _viewSliderActive = false;

  @override
  void initState() {
    super.initState();
    _modelAssetMode = _detectMg24BodyModelAssets();
  }

  @override
  void dispose() {
    if (_viewSliderActive) {
      widget.onInteractionChanged(false);
    }
    super.dispose();
  }

  void _setViewSliderActive(bool active) {
    if (_viewSliderActive == active) return;
    _viewSliderActive = active;
    widget.onInteractionChanged(active);
  }

  void _setViewPitch(double value) {
    setState(() {
      _viewPitchDeg =
          value.clamp(_bodyViewPitchMinDeg, _bodyViewPitchMaxDeg).toDouble();
    });
  }

  void _resetView() {
    setState(() {
      _viewPitchDeg = 0;
    });
  }

  void _resetVisualPose() {
    _calibrateMg24VisualFlatPose(widget.mg24);
    widget.onResetPose?.call();
    setState(() {
      _viewPitchDeg = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mg24 = widget.mg24;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.accessibility_new,
                size: 18,
                color: mg24.connected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Kopf / Brust', style: theme.textTheme.labelLarge),
              ),
              Text(
                mg24.hasPair
                    ? 'gekoppelt'
                    : mg24.connected
                        ? 'teilweise'
                        : 'offen',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: mg24.connected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
              ),
              const SizedBox(width: 4),
              if (widget.onResetPose != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: const Icon(Icons.restart_alt, size: 17),
                  tooltip: '3D-Lage nullen',
                  onPressed: mg24.connected ? _resetVisualPose : null,
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                icon: const Icon(Icons.center_focus_strong, size: 17),
                tooltip: 'Ansicht zuruecksetzen',
                onPressed: _resetView,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 240,
            width: double.infinity,
            child: Stack(
              children: [
                Positioned.fill(
                  child: FutureBuilder<_Mg24BodyAssetMode>(
                    future: _modelAssetMode,
                    builder: (context, assets) {
                      final assetMode = assets.data ?? _Mg24BodyAssetMode.none;
                      if (assetMode == _Mg24BodyAssetMode.mesh) {
                        return _Mg24MeshBodyScene(
                          head: mg24.forehead,
                          chest: mg24.belly,
                          relativeYawDeg: widget.relativeYawDeg,
                          headColor: const Color(0xFFE0822D),
                          chestColor: theme.colorScheme.primary,
                          outlineColor: theme.colorScheme.outlineVariant,
                          viewYawDeg: _viewYawDeg,
                          viewPitchDeg: _viewPitchDeg,
                        );
                      }
                      if (assetMode == _Mg24BodyAssetMode.body) {
                        return _Mg24UpperBodyModelScene(
                          head: mg24.forehead,
                          chest: mg24.belly,
                          relativeYawDeg: widget.relativeYawDeg,
                          viewYawDeg: _viewYawDeg,
                          viewPitchDeg: _viewPitchDeg,
                        );
                      }
                      if (assetMode == _Mg24BodyAssetMode.split) {
                        return _Mg24BodyModelScene(
                          head: mg24.forehead,
                          chest: mg24.belly,
                          relativeYawDeg: widget.relativeYawDeg,
                          viewYawDeg: _viewYawDeg,
                          viewPitchDeg: _viewPitchDeg,
                        );
                      }
                      return CustomPaint(
                        painter: _Mg24BodyPainter(
                          head: mg24.forehead,
                          chest: mg24.belly,
                          relativeYawDeg: widget.relativeYawDeg,
                          headColor: const Color(0xFFE0822D),
                          chestColor: theme.colorScheme.primary,
                          outlineColor: theme.colorScheme.outlineVariant,
                          textColor: theme.colorScheme.onSurfaceVariant,
                          viewYawDeg: _viewYawDeg,
                          viewPitchDeg: _viewPitchDeg,
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: _VerticalViewSlider(
                    value: _viewPitchDeg,
                    onChangeStart: () => _setViewSliderActive(true),
                    onChanged: _setViewPitch,
                    onChangeEnd: () => _setViewSliderActive(false),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _MiniValue(
                label: 'Kopf',
                value: _formatVisualTiltCompact(
                  mg24.forehead,
                  isForehead: true,
                ),
              ),
              _MiniValue(
                label: 'Brust',
                value: _formatVisualTiltCompact(
                  mg24.belly,
                  isForehead: false,
                ),
              ),
              _MiniValue(
                label: 'Relativ',
                value: _formatRelativeVisualTiltCompact(mg24),
              ),
            ],
          ),
          if (widget.summaryLine != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.summaryLine!,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _VerticalViewSlider extends StatelessWidget {
  const _VerticalViewSlider({
    required this.value,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double value;
  final VoidCallback onChangeStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 34,
      height: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        child: Center(
          child: RotatedBox(
            quarterTurns: 3,
            child: SizedBox(
              width: 208,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                ),
                child: Slider(
                  min: _bodyViewPitchMinDeg,
                  max: _bodyViewPitchMaxDeg,
                  value: value
                      .clamp(_bodyViewPitchMinDeg, _bodyViewPitchMaxDeg)
                      .toDouble(),
                  onChangeStart: (_) => onChangeStart(),
                  onChanged: onChanged,
                  onChangeEnd: (_) => onChangeEnd(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _verticalCameraOrbit(
  double yawDeg,
  double pitchDeg, {
  required double basePhiDeg,
  required String radius,
}) {
  var theta = yawDeg;
  var phi = basePhiDeg + _normalizeVisualAngleDeg(pitchDeg);
  while (phi > 180) {
    phi = 360 - phi;
    theta += 180;
  }
  while (phi < 0) {
    phi = -phi;
    theta += 180;
  }
  phi = phi.clamp(1.0, 179.0).toDouble();
  theta = _normalizeVisualAngleDeg(theta);
  return '${theta.toStringAsFixed(1)}deg ${phi.toStringAsFixed(1)}deg $radius';
}

class _Mg24BodyModelScene extends StatelessWidget {
  const _Mg24BodyModelScene({
    required this.head,
    required this.chest,
    required this.relativeYawDeg,
    required this.viewYawDeg,
    required this.viewPitchDeg,
  });

  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final double viewYawDeg;
  final double viewPitchDeg;

  @override
  Widget build(BuildContext context) {
    final cameraOrbit = _cameraOrbit(viewYawDeg, viewPitchDeg);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 122,
            child: IgnorePointer(
              child: _Mg24ModelViewer(
                src: _mg24HeadModelAsset,
                alt: '3D head model',
                orientation: _modelOrientation(
                  head,
                  isForehead: true,
                  relativeYawDeg: relativeYawDeg,
                ),
                cameraOrbit: cameraOrbit,
                cameraTarget: 'auto auto auto',
                fieldOfView: '38deg',
                scale: '1 1 1',
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 148,
            child: IgnorePointer(
              child: _Mg24ModelViewer(
                src: _mg24ChestModelAsset,
                alt: '3D chest model',
                orientation: _modelOrientation(
                  chest,
                  isForehead: false,
                  relativeYawDeg: relativeYawDeg,
                ),
                cameraOrbit: cameraOrbit,
                cameraTarget: 'auto auto auto',
                fieldOfView: '38deg',
                scale: '1 1 1',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _cameraOrbit(double yawDeg, double pitchDeg) {
    return _verticalCameraOrbit(
      yawDeg,
      pitchDeg,
      basePhiDeg: 74,
      radius: '112%',
    );
  }

  String _modelOrientation(
    Mg24SensorSummary sensor, {
    required bool isForehead,
    required double? relativeYawDeg,
  }) {
    return _visualModelOrientation(
      sensor,
      isForehead: isForehead,
      relativeYawDeg: relativeYawDeg,
    );
  }
}

class _Mg24MeshBodyScene extends StatefulWidget {
  const _Mg24MeshBodyScene({
    required this.head,
    required this.chest,
    required this.relativeYawDeg,
    required this.headColor,
    required this.chestColor,
    required this.outlineColor,
    required this.viewYawDeg,
    required this.viewPitchDeg,
  });

  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final Color headColor;
  final Color chestColor;
  final Color outlineColor;
  final double viewYawDeg;
  final double viewPitchDeg;

  @override
  State<_Mg24MeshBodyScene> createState() => _Mg24MeshBodySceneState();
}

class _Mg24MeshBodySceneState extends State<_Mg24MeshBodyScene> {
  late final Future<_Mg24MeshPair> _meshes = _loadMeshes();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Mg24MeshPair>(
      future: _meshes,
      builder: (context, snapshot) {
        final meshes = snapshot.data;
        if (meshes == null) {
          return const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return CustomPaint(
          painter: _Mg24MeshBodyPainter(
            meshes: meshes,
            head: widget.head,
            chest: widget.chest,
            relativeYawDeg: widget.relativeYawDeg,
            headColor: widget.headColor,
            chestColor: widget.chestColor,
            outlineColor: widget.outlineColor,
            viewYawDeg: widget.viewYawDeg,
            viewPitchDeg: widget.viewPitchDeg,
          ),
        );
      },
    );
  }

  Future<_Mg24MeshPair> _loadMeshes() async {
    final head = await _Mg24MeshAsset.load(_mg24HeadMeshAsset);
    final chest = await _Mg24MeshAsset.load(_mg24ChestMeshAsset);
    return _Mg24MeshPair(head: head, chest: chest);
  }
}

class _Mg24MeshBodyPainter extends CustomPainter {
  const _Mg24MeshBodyPainter({
    required this.meshes,
    required this.head,
    required this.chest,
    required this.relativeYawDeg,
    required this.headColor,
    required this.chestColor,
    required this.outlineColor,
    required this.viewYawDeg,
    required this.viewPitchDeg,
  });

  final _Mg24MeshPair meshes;
  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final Color headColor;
  final Color chestColor;
  final Color outlineColor;
  final double viewYawDeg;
  final double viewPitchDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.54);
    final scale = math.min(size.width / 340, size.height / 270);

    _drawSceneShadow(canvas, origin, scale);

    final faces = <_MeshPaintFace>[];
    _appendMeshFaces(
      faces,
      mesh: meshes.chest,
      sensor: chest,
      isForehead: false,
      relativeYawDeg: relativeYawDeg,
      center: const _Vec3(-22, 4, 0),
      meshScale: 145,
      color: chest.connected ? chestColor : outlineColor,
      origin: origin,
      sceneScale: scale,
      alpha: chest.connected ? 0.94 : 0.46,
    );
    _appendMeshFaces(
      faces,
      mesh: meshes.head,
      sensor: head,
      isForehead: true,
      relativeYawDeg: relativeYawDeg,
      center: const _Vec3(22, -2, 0),
      meshScale: 190,
      color: head.connected ? headColor : outlineColor,
      origin: origin,
      sceneScale: scale,
      alpha: head.connected ? 0.94 : 0.46,
    );

    faces.sort((a, b) => b.depth.compareTo(a.depth));
    for (final face in faces) {
      final paint = Paint()
        ..color = face.color.withValues(alpha: face.alpha)
        ..style = PaintingStyle.fill;
      canvas.drawPath(face.path, paint);

      final linePaint = Paint()
        ..color = outlineColor.withValues(alpha: 0.16 * face.alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7;
      canvas.drawPath(face.path, linePaint);
    }
  }

  void _drawSceneShadow(Canvas canvas, Offset origin, double scale) {
    final paint = Paint()
      ..color = outlineColor.withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(origin.dx, origin.dy + 116 * scale),
        width: 150 * scale,
        height: 22 * scale,
      ),
      paint,
    );
  }

  void _appendMeshFaces(
    List<_MeshPaintFace> output, {
    required _Mg24MeshAsset mesh,
    required Mg24SensorSummary sensor,
    required bool isForehead,
    required double? relativeYawDeg,
    required _Vec3 center,
    required double meshScale,
    required Color color,
    required Offset origin,
    required double sceneScale,
    required double alpha,
  }) {
    final transformed = <_Vec3>[];
    final projected = <_ProjectedPoint>[];
    for (final vertex in mesh.vertices) {
      final local = _Vec3(
        (vertex.x - mesh.center.x) * meshScale,
        -(vertex.z - mesh.center.z) * meshScale,
        (vertex.y - mesh.center.y) * meshScale,
      );
      final scene = center +
          _rotateSensor(
            local,
            sensor,
            isForehead: isForehead,
            relativeYawDeg: relativeYawDeg,
          );
      final viewed = _rotateView(scene);
      transformed.add(viewed);
      projected.add(_projectViewed(viewed, origin, sceneScale));
    }

    for (final face in mesh.faces) {
      final a = transformed[face.a];
      final b = transformed[face.b];
      final c = transformed[face.c];
      final pa = projected[face.a];
      final pb = projected[face.b];
      final pc = projected[face.c];
      final area = _signedArea(pa.offset, pb.offset, pc.offset);
      if (area.abs() < 0.08) continue;

      final normal = _normal(a, b, c);
      final shade = _shade(normal);
      final shadedColor = Color.lerp(
        Colors.black,
        color,
        shade,
      )!;
      final path = Path()
        ..moveTo(pa.offset.dx, pa.offset.dy)
        ..lineTo(pb.offset.dx, pb.offset.dy)
        ..lineTo(pc.offset.dx, pc.offset.dy)
        ..close();
      output.add(
        _MeshPaintFace(
          path: path,
          depth: (pa.z + pb.z + pc.z) / 3,
          color: shadedColor,
          alpha: alpha,
        ),
      );
    }
  }

  double _signedArea(Offset a, Offset b, Offset c) {
    return (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  }

  _Vec3 _normal(_Vec3 a, _Vec3 b, _Vec3 c) {
    final u = b - a;
    final v = c - a;
    return _Vec3(
      u.y * v.z - u.z * v.y,
      u.z * v.x - u.x * v.z,
      u.x * v.y - u.y * v.x,
    ).normalized();
  }

  double _shade(_Vec3 normal) {
    const light = _Vec3(-0.35, -0.50, -0.78);
    final intensity =
        (normal.dot(light.normalized()).abs() * 0.58 + 0.42).clamp(0.0, 1.0);
    return intensity.toDouble();
  }

  _ProjectedPoint _projectViewed(_Vec3 viewed, Offset origin, double scale) {
    const distance = 520.0;
    final perspective = distance / (distance + viewed.z);
    return _ProjectedPoint(
      Offset(
        origin.dx + viewed.x * scale * perspective,
        origin.dy + viewed.y * scale * perspective,
      ),
      viewed.z,
      perspective,
    );
  }

  _Vec3 _rotateSensor(
    _Vec3 point,
    Mg24SensorSummary sensor, {
    required bool isForehead,
    required double? relativeYawDeg,
  }) {
    final quaternion = _visualQuaternion(
      sensor,
      isForehead: isForehead,
      relativeYawDeg: relativeYawDeg,
    );
    if (quaternion != null) {
      return quaternion.rotate(_visualZeroPoseQuaternion().rotate(point));
    }
    return _rotateEuler(
      _visualZeroPoseQuaternion().rotate(point),
      rollDeg: _finiteAngle(sensor.rollDeg ?? sensor.angleDeg),
      pitchDeg: _finiteAngle(sensor.pitchDeg),
      yawDeg: 0,
    );
  }

  _Vec3 _rotateView(_Vec3 point) {
    return _rotateEuler(
      point,
      rollDeg: viewPitchDeg,
      pitchDeg: viewYawDeg,
      yawDeg: 0,
    );
  }

  _Vec3 _rotateEuler(
    _Vec3 point, {
    required double rollDeg,
    required double pitchDeg,
    required double yawDeg,
  }) {
    final roll = rollDeg * math.pi / 180;
    final pitch = pitchDeg * math.pi / 180;
    final yaw = yawDeg * math.pi / 180;

    var x = point.x;
    var y = point.y * math.cos(roll) - point.z * math.sin(roll);
    var z = point.y * math.sin(roll) + point.z * math.cos(roll);

    final pitchX = x * math.cos(pitch) + z * math.sin(pitch);
    z = -x * math.sin(pitch) + z * math.cos(pitch);
    x = pitchX;

    final yawX = x * math.cos(yaw) - y * math.sin(yaw);
    y = x * math.sin(yaw) + y * math.cos(yaw);
    x = yawX;

    return _Vec3(x, y, z);
  }

  double _finiteAngle(double? value) {
    if (value == null || !value.isFinite) return 0;
    return value;
  }

  @override
  bool shouldRepaint(covariant _Mg24MeshBodyPainter oldDelegate) {
    return oldDelegate.meshes != meshes ||
        oldDelegate.head != head ||
        oldDelegate.chest != chest ||
        oldDelegate.relativeYawDeg != relativeYawDeg ||
        oldDelegate.headColor != headColor ||
        oldDelegate.chestColor != chestColor ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.viewYawDeg != viewYawDeg ||
        oldDelegate.viewPitchDeg != viewPitchDeg;
  }
}

class _Mg24UpperBodyModelScene extends StatelessWidget {
  const _Mg24UpperBodyModelScene({
    required this.head,
    required this.chest,
    required this.relativeYawDeg,
    required this.viewYawDeg,
    required this.viewPitchDeg,
  });

  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final double viewYawDeg;
  final double viewPitchDeg;

  @override
  Widget build(BuildContext context) {
    final cameraOrbit = _cameraOrbit(viewYawDeg, viewPitchDeg);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: IgnorePointer(
              child: _Mg24ModelViewer(
                src: _mg24BodyModelAsset,
                alt: '3D upper body head crop',
                orientation: _modelOrientation(
                  head,
                  isForehead: true,
                  relativeYawDeg: relativeYawDeg,
                ),
                cameraOrbit: cameraOrbit,
                cameraTarget: '0m 1.68m 0m',
                fieldOfView: '19deg',
                scale: '1 1 1',
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 162,
            child: IgnorePointer(
              child: _Mg24ModelViewer(
                src: _mg24BodyModelAsset,
                alt: '3D upper body chest crop',
                orientation: _modelOrientation(
                  chest,
                  isForehead: false,
                  relativeYawDeg: relativeYawDeg,
                ),
                cameraOrbit: cameraOrbit,
                cameraTarget: '0m 1.20m 0m',
                fieldOfView: '25deg',
                scale: '1 1 1',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _cameraOrbit(double yawDeg, double pitchDeg) {
    return _verticalCameraOrbit(
      yawDeg,
      pitchDeg,
      basePhiDeg: 76,
      radius: '62%',
    );
  }

  String _modelOrientation(
    Mg24SensorSummary sensor, {
    required bool isForehead,
    required double? relativeYawDeg,
  }) {
    return _visualModelOrientation(
      sensor,
      isForehead: isForehead,
      relativeYawDeg: relativeYawDeg,
    );
  }
}

class _Mg24ModelViewer extends StatelessWidget {
  const _Mg24ModelViewer({
    required this.src,
    required this.alt,
    required this.orientation,
    required this.cameraOrbit,
    required this.cameraTarget,
    required this.fieldOfView,
    required this.scale,
  });

  final String src;
  final String alt;
  final String orientation;
  final String cameraOrbit;
  final String cameraTarget;
  final String fieldOfView;
  final String scale;

  @override
  Widget build(BuildContext context) {
    return ModelViewer(
      src: src,
      alt: alt,
      backgroundColor: Colors.transparent,
      cameraControls: false,
      disablePan: true,
      disableTap: true,
      disableZoom: true,
      autoRotate: false,
      autoPlay: false,
      cameraOrbit: cameraOrbit,
      cameraTarget: cameraTarget,
      fieldOfView: fieldOfView,
      orientation: orientation,
      scale: scale,
      shadowIntensity: 0.18,
      shadowSoftness: 0.7,
      exposure: 0.95,
      debugLogging: false,
    );
  }
}

class _Mg24RespirationOverview extends StatefulWidget {
  const _Mg24RespirationOverview({
    required this.mg24,
    required this.samples,
    required this.peaks,
    required this.snoreBreathWindows,
    required this.inhaleBreathWindows,
    required this.recentSnoreAssessments,
    required this.measurementStartedAt,
    required this.plotLatencySeconds,
    required this.showPlot,
  });

  final Mg24State mg24;
  final List<SignalSample> samples;
  final List<PlotPoint> peaks;
  final List<TimeWindow> snoreBreathWindows;
  final List<TimeWindow> inhaleBreathWindows;
  final List<SnoreWindowAssessment> recentSnoreAssessments;
  final DateTime? measurementStartedAt;
  final double? plotLatencySeconds;
  final bool showPlot;

  @override
  State<_Mg24RespirationOverview> createState() =>
      _Mg24RespirationOverviewState();
}

class _Mg24RespirationOverviewState extends State<_Mg24RespirationOverview> {
  final _plotScale = _AdaptiveSignalScale(minSpan: 0.045);
  double? _lastSampleTimeS;
  double? _plotViewportEndS;

  double? _stablePlotEnd(List<SignalSample> samples) {
    if (samples.length < 2) {
      _plotViewportEndS = null;
      return null;
    }
    final latest = samples.last.timeS;
    if (!latest.isFinite) return _plotViewportEndS;
    _plotViewportEndS = latest;
    return _plotViewportEndS;
  }

  ({double center, double extent}) _stablePlotYScale(
    List<SignalSample> samples,
    double? plotEndS,
  ) {
    if (samples.length < 2) {
      _plotScale.reset();
      _lastSampleTimeS = null;
      return (center: 0.0, extent: 0.0225);
    }

    final maxX = plotEndS ?? samples.last.timeS;
    if (!maxX.isFinite) {
      return _plotScale.current(centerFallback: 0, extentFallback: 0.0225);
    }
    final previousMaxX = _lastSampleTimeS;
    if (previousMaxX == null ||
        maxX < previousMaxX ||
        maxX - previousMaxX > 3.0) {
      _plotScale.reset();
    }
    _lastSampleTimeS = maxX;

    final scaleMinX = math.max(0.0, maxX - 10.0);
    final values = <double>[];
    for (var i = samples.length - 1; i >= 0; i--) {
      final sample = samples[i];
      if (sample.timeS < scaleMinX) break;
      final value = sample.resp;
      if (sample.preview) continue;
      if (!sample.timeS.isFinite || !value.isFinite) continue;
      values.add(value);
    }
    if (values.length < 2) {
      for (var i = samples.length - 1; i >= 0; i--) {
        final sample = samples[i];
        if (sample.timeS < scaleMinX) break;
        final value = sample.resp;
        if (!sample.timeS.isFinite || !value.isFinite) continue;
        values.add(value);
      }
    }
    if (values.length < 2) {
      return _plotScale.current(centerFallback: 0, extentFallback: 0.0225);
    }
    return _plotScale.update(values);
  }

  int _finiteRespirationSampleCount(List<SignalSample> samples) {
    var count = 0;
    for (final sample in samples) {
      if (sample.timeS.isFinite && sample.resp.isFinite) {
        count++;
      }
    }
    return count;
  }

  String _formatRecentSnoreAssessments(
    List<SnoreWindowAssessment> assessments,
  ) {
    if (assessments.isEmpty) return '--';
    final newestFirst = assessments.reversed.take(3).map((assessment) {
      final window = assessment.window;
      final durationS = math.max(0.0, window.endS - window.startS);
      final start = _formatPlotClockLabel(
        widget.measurementStartedAt,
        window.startS,
      );
      final end = _formatPlotClockLabel(
        widget.measurementStartedAt,
        window.endS,
      );
      final source = _snoreSourceText(assessment.source);
      final confidence = assessment.sourceConfidence > 0
          ? ' ${(assessment.sourceConfidence * 100).clamp(0, 99).toStringAsFixed(0)}%'
          : '';
      final inhale = assessment.inhaleWindow;
      final inhaleText = inhale == null
          ? 'Einatmung offen'
          : 'Einatmung ${_formatPlotClockLabel(widget.measurementStartedAt, inhale.startS)}-'
              '${_formatPlotClockLabel(widget.measurementStartedAt, inhale.endS)}';
      return '$start-$end (${durationS.toStringAsFixed(2)}s) | '
          '$source$confidence | $inhaleText';
    });
    return newestFirst.join('  |  ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.mg24.belly.connected &&
        _finiteRespirationSampleCount(widget.samples) >= 2;
    final color = active ? const Color(0xFF6B4DBA) : theme.colorScheme.outline;
    final plotEndS = active ? _stablePlotEnd(widget.samples) : null;
    final yScale = _stablePlotYScale(widget.samples, plotEndS);
    final plotLatencyS = widget.plotLatencySeconds;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.air,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text('IMU-Atmung', style: theme.textTheme.labelLarge),
              ),
              Text(
                active ? 'aktiv' : 'warte',
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
          if (widget.showPlot) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 92,
              width: double.infinity,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _ImuBreathingPlotPainter(
                    samples: widget.samples,
                    peaks: widget.peaks,
                    snoreBreathWindows: widget.snoreBreathWindows,
                    inhaleBreathWindows: widget.inhaleBreathWindows,
                    lineColor: const Color(0xFF6B4DBA),
                    peakColor: const Color(0xFFE0822D),
                    snoreBreathWindowColor: const Color(0xFFFFB04A),
                    inhaleBreathWindowColor: const Color(0xFF39A78E),
                    gridColor: theme.colorScheme.outlineVariant,
                    windowSeconds: mg24BreathingPlotSeconds.toDouble(),
                    yCenter: yScale.center,
                    yExtent: yScale.extent,
                    measurementStartedAt: widget.measurementStartedAt,
                    plotEndS: plotEndS,
                  ),
                  child: active
                      ? const SizedBox.expand()
                      : Center(
                          child: Text(
                            'Warte auf Daten ...',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            const Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _PlotWindowLegend(
                  color: Color(0xFF39A78E),
                  label: 'Einatmung',
                ),
                _PlotWindowLegend(
                  color: Color(0xFFFFB04A),
                  label: 'Schnarchfenster',
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _MiniValue(
                label: 'Rate',
                value:
                    '${_formatNumber(widget.mg24.breathingRatePerMin, 0)} /min',
              ),
              _MiniValue(
                label: 'Qualitaet',
                value: '${_formatNumber(widget.mg24.breathingQuality, 0)} %',
              ),
              if (widget.showPlot) ...[
                _MiniValue(
                  label: 'Marker',
                  value: widget.peaks.length.toString(),
                ),
                _MiniValue(
                  label: 'Fenster sichtbar',
                  value: widget.snoreBreathWindows.length.toString(),
                ),
                if (plotLatencyS != null)
                  _MiniValue(
                    label: 'Plot-Latenz',
                    value: '${plotLatencyS.toStringAsFixed(1)} s',
                  ),
              ],
            ],
          ),
          if (widget.showPlot) ...[
            const SizedBox(height: 6),
            Text(
              'Letzte bestaetigte Fenster: ${_formatRecentSnoreAssessments(widget.recentSnoreAssessments)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlotWindowLegend extends StatelessWidget {
  const _PlotWindowLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 8,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.28),
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _ImuBreathingPlotPainter extends CustomPainter {
  const _ImuBreathingPlotPainter({
    required this.samples,
    required this.peaks,
    required this.snoreBreathWindows,
    required this.inhaleBreathWindows,
    required this.lineColor,
    required this.peakColor,
    required this.snoreBreathWindowColor,
    required this.inhaleBreathWindowColor,
    required this.gridColor,
    required this.windowSeconds,
    required this.yCenter,
    required this.yExtent,
    required this.measurementStartedAt,
    required this.plotEndS,
  });

  final List<SignalSample> samples;
  final List<PlotPoint> peaks;
  final List<TimeWindow> snoreBreathWindows;
  final List<TimeWindow> inhaleBreathWindows;
  final Color lineColor;
  final Color peakColor;
  final Color snoreBreathWindowColor;
  final Color inhaleBreathWindowColor;
  final Color gridColor;
  final double windowSeconds;
  final double yCenter;
  final double yExtent;
  final DateTime? measurementStartedAt;
  final double? plotEndS;

  @override
  void paint(Canvas canvas, Size size) {
    const axisLabelHeight = 15.0;
    const plotTopPadding = 4.0;
    final plotBottom =
        math.max(plotTopPadding + 1.0, size.height - axisLabelHeight);
    final plotHeight = math.max(1.0, plotBottom - plotTopPadding);
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = plotTopPadding + plotHeight * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (samples.length < 2) {
      final y = plotTopPadding + plotHeight / 2;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = gridColor
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    final maxX = plotEndS ?? samples.last.timeS;
    if (!maxX.isFinite) return;
    final requestedMinX = math.max(0.0, maxX - windowSeconds);
    var firstVisibleIndex = 0;
    while (firstVisibleIndex < samples.length &&
        samples[firstVisibleIndex].timeS < requestedMinX) {
      firstVisibleIndex++;
    }
    if (samples.length - firstVisibleIndex < 2) return;

    final minX = requestedMinX;
    final xRange = math.max(0.001, maxX - minX);

    double mapX(double xValue) =>
        ((xValue - minX) / xRange).clamp(0.0, 1.0) * size.width;

    final verticalGridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.26)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(
        Offset(x, plotTopPadding),
        Offset(x, plotBottom),
        verticalGridPaint,
      );
    }

    if (inhaleBreathWindows.isNotEmpty) {
      final inhaleFill = Paint()
        ..color = inhaleBreathWindowColor.withValues(alpha: 0.20)
        ..style = PaintingStyle.fill;
      final inhaleEdge = Paint()
        ..color = inhaleBreathWindowColor.withValues(alpha: 0.82)
        ..strokeWidth = 1.2;
      for (final window in inhaleBreathWindows) {
        final startS = window.startS;
        final endS = window.endS;
        if (!startS.isFinite ||
            !endS.isFinite ||
            endS < minX ||
            startS > maxX) {
          continue;
        }
        final left = mapX(math.max(startS, minX));
        final right = mapX(math.min(endS, maxX));
        if (right <= left) continue;
        final rect = Rect.fromLTRB(left, plotTopPadding, right, plotBottom);
        canvas.drawRect(rect, inhaleFill);
        canvas.drawLine(
          Offset(left, plotTopPadding),
          Offset(left, plotBottom),
          inhaleEdge,
        );
        canvas.drawLine(
          Offset(right, plotTopPadding),
          Offset(right, plotBottom),
          inhaleEdge,
        );
      }
    }

    if (snoreBreathWindows.isNotEmpty) {
      final breathFill = Paint()
        ..color = snoreBreathWindowColor.withValues(alpha: 0.36)
        ..style = PaintingStyle.fill;
      final breathEdge = Paint()
        ..color = snoreBreathWindowColor.withValues(alpha: 0.92)
        ..strokeWidth = 1.8;
      for (final window in snoreBreathWindows) {
        final startS = window.startS;
        final endS = window.endS;
        if (!startS.isFinite ||
            !endS.isFinite ||
            endS < minX ||
            startS > maxX) {
          continue;
        }
        final left = mapX(math.max(startS, minX));
        final right = mapX(math.min(endS, maxX));
        if (right <= left) continue;
        final rect = Rect.fromLTRB(left, plotTopPadding, right, plotBottom);
        canvas.drawRect(rect, breathFill);
        canvas.drawLine(
          Offset(left, plotTopPadding),
          Offset(left, plotBottom),
          breathEdge,
        );
        canvas.drawLine(
          Offset(right, plotTopPadding),
          Offset(right, plotBottom),
          breathEdge,
        );
      }
    }

    final extent = math.max(0.001, yExtent);
    final center = yCenter.isFinite ? yCenter : 0.0;
    final minY = center - extent;
    final maxY = center + extent;

    Offset mapPoint(double xValue, double yValue) {
      final yRange = math.max(0.001, maxY - minY);
      final x = mapX(xValue);
      final y = plotTopPadding +
          (1.0 - ((yValue - minY) / yRange).clamp(0.0, 1.0)) * plotHeight;
      return Offset(x, y);
    }

    Path buildPath() {
      final path = Path();
      var moved = false;
      double? previousX;
      for (var i = firstVisibleIndex; i < samples.length; i++) {
        final sample = samples[i];
        if (!sample.timeS.isFinite || !sample.resp.isFinite) {
          continue;
        }
        if (sample.timeS < minX || sample.timeS > maxX) continue;
        final offset = mapPoint(sample.timeS, sample.resp);
        if (!moved || (previousX != null && sample.timeS - previousX > 1.25)) {
          path.moveTo(offset.dx, offset.dy);
          moved = true;
        } else {
          path.lineTo(offset.dx, offset.dy);
        }
        previousX = sample.timeS;
      }
      return path;
    }

    final path = buildPath();

    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final haloPaint = Paint()
      ..color = peakColor.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;
    final peakPaint = Paint()
      ..color = peakColor
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final peak in peaks) {
      if (peak.x < minX || peak.x > maxX || !peak.y.isFinite) continue;
      final offset = mapPoint(peak.x, peak.y);
      canvas.drawCircle(offset, 5.6, haloPaint);
      canvas.drawCircle(offset, 3.4, peakPaint);
      canvas.drawCircle(offset, 3.4, strokePaint);
    }

    final labelStyle = TextStyle(
      color: gridColor.withValues(alpha: 0.92),
      fontSize: 9,
      height: 1,
    );
    for (var i = 0; i <= 4; i++) {
      final tickS = minX + xRange * i / 4;
      final label = _formatPlotClockLabel(measurementStartedAt, tickS);
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final rawX = size.width * i / 4 - painter.width / 2;
      final x =
          rawX.clamp(0.0, math.max(0.0, size.width - painter.width)).toDouble();
      painter.paint(canvas, Offset(x, plotBottom + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _ImuBreathingPlotPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.peaks != peaks ||
        oldDelegate.snoreBreathWindows != snoreBreathWindows ||
        oldDelegate.inhaleBreathWindows != inhaleBreathWindows ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.peakColor != peakColor ||
        oldDelegate.snoreBreathWindowColor != snoreBreathWindowColor ||
        oldDelegate.inhaleBreathWindowColor != inhaleBreathWindowColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.windowSeconds != windowSeconds ||
        oldDelegate.yCenter != yCenter ||
        oldDelegate.yExtent != yExtent ||
        oldDelegate.measurementStartedAt != measurementStartedAt ||
        oldDelegate.plotEndS != plotEndS;
  }
}

class _Mg24OximeterOverview extends StatefulWidget {
  const _Mg24OximeterOverview({
    required this.mg24,
    required this.showPlot,
  });

  final Mg24State mg24;
  final bool showPlot;

  @override
  State<_Mg24OximeterOverview> createState() => _Mg24OximeterOverviewState();
}

class _Mg24OximeterOverviewState extends State<_Mg24OximeterOverview> {
  String? _scaleSensorKey;
  int _previousValueLength = 0;
  final _plotScale = _AdaptiveSignalScale(
    minSpan: 1.0,
    contractionAlpha: 0.07,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mg24 = widget.mg24;
    final sensor = _oximeterSensor(mg24);
    final displayValues = sensor.ppgWaveform;
    final scale = _updatePpgScale(sensor, displayValues);
    final maxActive = mg24.max30102Connected == true;
    final ppgColor = theme.colorScheme.primary;
    final stateColor =
        maxActive ? theme.colorScheme.primary : theme.colorScheme.outline;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.monitor_heart,
                size: 18,
                color: stateColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text('MAX30102', style: theme.textTheme.labelLarge),
              ),
              Text(
                maxActive ? 'aktiv' : _formatMax30102State(mg24),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: stateColor,
                ),
              ),
            ],
          ),
          if (!maxActive) ...[
            const SizedBox(height: 6),
            Text(
              mg24.max30102Connected == false
                  ? 'Kein I2C-Signal: D4/SDA, D5/SCL, 3V3 und GND pruefen.'
                  : 'MAX30102 wird direkt nach der Bluetooth-Verbindung geprueft.',
              style: theme.textTheme.bodySmall?.copyWith(color: stateColor),
            ),
          ],
          if (widget.showPlot) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 92,
              width: double.infinity,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _PpgWaveformPainter(
                    values: displayValues,
                    peaks: sensor.ppgPeaks,
                    color: ppgColor,
                    gridColor: theme.colorScheme.outlineVariant,
                    yMin: scale?.min,
                    yMax: scale?.max,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _MiniValue(
                label: 'Herzfrequenz',
                value: '${_formatNumber(mg24.heartRateBpm, 0)} bpm',
              ),
              _MiniValue(
                label: 'SpO2',
                value: '${_formatNumber(mg24.spo2Percent, 0)} %',
              ),
            ],
          ),
        ],
      ),
    );
  }

  _PpgPlotScale? _updatePpgScale(
    Mg24SensorSummary sensor,
    List<double> displayValues,
  ) {
    final values = displayValues;
    final sensorKey = sensor.remoteId ?? sensor.name ?? 'ppg';
    if (_scaleSensorKey != sensorKey ||
        values.length < _previousValueLength - 2 ||
        values.length < 8) {
      _scaleSensorKey = sensorKey;
      _plotScale.reset();
    }
    _previousValueLength = values.length;

    if (displayValues.length < 8) return null;
    final scaleCount = math.min(displayValues.length, 75);
    final scaleValues =
        displayValues.sublist(displayValues.length - scaleCount);
    final scale = _plotScale.update(scaleValues);
    return _PpgPlotScale(
      scale.center - scale.extent,
      scale.center + scale.extent,
    );
  }
}

Mg24SensorSummary _oximeterSensor(Mg24State mg24) {
  final bellyHasPpg =
      mg24.belly.ppgIr != null || mg24.belly.ppgWaveform.isNotEmpty;
  if (bellyHasPpg) return mg24.belly;
  return mg24.forehead;
}

class _PpgPlotScale {
  const _PpgPlotScale(this.min, this.max);

  final double min;
  final double max;
}

class _AdaptiveSignalScale {
  _AdaptiveSignalScale({
    required this.minSpan,
    this.contractionAlpha = 0.025,
  });

  final double minSpan;
  final double contractionAlpha;
  double? _minimum;
  double? _maximum;

  void reset() {
    _minimum = null;
    _maximum = null;
  }

  ({double center, double extent}) current({
    required double centerFallback,
    required double extentFallback,
  }) {
    final minimum = _minimum;
    final maximum = _maximum;
    if (minimum == null || maximum == null || maximum <= minimum) {
      return (center: centerFallback, extent: extentFallback);
    }
    return (
      center: (minimum + maximum) / 2,
      extent: (maximum - minimum) / 2,
    );
  }

  ({double center, double extent}) update(Iterable<double> input) {
    final values =
        input.where((value) => value.isFinite).toList(growable: false);
    if (values.length < 2) {
      return current(centerFallback: 0, extentFallback: minSpan / 2);
    }

    final sorted = List<double>.from(values)..sort();
    final rawMin = sorted.first;
    final rawMax = sorted.last;
    final robustLow = _quantile(sorted, 0.05);
    final robustHigh = _quantile(sorted, 0.95);
    final robustSpan = math.max(minSpan, robustHigh - robustLow);
    final padding = math.max(minSpan * 0.08, robustSpan * 0.12);
    final targetMin = math.min(rawMin - padding * 0.35, robustLow - padding);
    final targetMax = math.max(rawMax + padding * 0.35, robustHigh + padding);

    final previousMin = _minimum;
    final previousMax = _maximum;
    if (previousMin == null ||
        previousMax == null ||
        previousMax <= previousMin) {
      _minimum = targetMin;
      _maximum = targetMax;
    } else {
      final previousSpan = math.max(minSpan, previousMax - previousMin);
      final deadBand = previousSpan * 0.035;
      final settledTargetMin =
          (targetMin - previousMin).abs() < deadBand ? previousMin : targetMin;
      final settledTargetMax =
          (targetMax - previousMax).abs() < deadBand ? previousMax : targetMax;
      _minimum = settledTargetMin < previousMin
          ? targetMin
          : previousMin + (settledTargetMin - previousMin) * contractionAlpha;
      _maximum = settledTargetMax > previousMax
          ? targetMax
          : previousMax + (settledTargetMax - previousMax) * contractionAlpha;
    }

    var minimum = _minimum!;
    var maximum = _maximum!;
    if (maximum - minimum < minSpan) {
      final center = (minimum + maximum) / 2;
      minimum = center - minSpan / 2;
      maximum = center + minSpan / 2;
      _minimum = minimum;
      _maximum = maximum;
    }
    return (
      center: (minimum + maximum) / 2,
      extent: (maximum - minimum) / 2,
    );
  }

  double _quantile(List<double> sorted, double fraction) {
    final rank = fraction.clamp(0.0, 1.0) * (sorted.length - 1);
    final lower = rank.floor();
    final upper = rank.ceil();
    if (lower == upper) return sorted[lower];
    final weight = rank - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }
}

class _PpgWaveformPainter extends CustomPainter {
  const _PpgWaveformPainter({
    required this.values,
    required this.peaks,
    required this.color,
    required this.gridColor,
    required this.yMin,
    required this.yMax,
  });

  final List<double> values;
  final List<bool> peaks;
  final Color color;
  final Color gridColor;
  final double? yMin;
  final double? yMax;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) {
      final paint = Paint()
        ..color = gridColor
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      final y = size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }

    final visibleCount = values.length;
    final rawMinValue = values.reduce(math.min);
    final rawMaxValue = values.reduce(math.max);
    final minValue = yMin?.isFinite == true ? yMin! : rawMinValue;
    final maxValue = yMax?.isFinite == true ? yMax! : rawMaxValue;
    final span = math.max(1.0, maxValue - minValue);
    final path = Path();
    final denominator = math.max(1.0, visibleCount - 1.0);
    const verticalPadding = 4.0;
    final drawableHeight = math.max(1.0, size.height - verticalPadding * 2);
    for (var i = 0; i < visibleCount; i++) {
      final x = size.width * i / denominator;
      final normalized = ((values[i] - minValue) / span).clamp(0.0, 1.0);
      final y = verticalPadding + (1 - normalized) * drawableHeight;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    const peakColor = Color(0xFFE0822D);
    final haloPaint = Paint()
      ..color = peakColor.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;
    final peakPaint = Paint()
      ..color = peakColor
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final count = math.min(visibleCount, peaks.length);
    for (var i = 0; i < count; i++) {
      if (!peaks[i]) continue;
      final x = size.width * i / denominator;
      final normalized = ((values[i] - minValue) / span).clamp(0.0, 1.0);
      final y = verticalPadding + (1 - normalized) * drawableHeight;
      final offset = Offset(x, y);
      canvas.drawCircle(offset, 5.6, haloPaint);
      canvas.drawCircle(offset, 3.4, peakPaint);
      canvas.drawCircle(offset, 3.4, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PpgWaveformPainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.peaks != peaks ||
        oldDelegate.color != color ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.yMin != yMin ||
        oldDelegate.yMax != yMax;
  }
}

class _Mg24BodyPainter extends CustomPainter {
  const _Mg24BodyPainter({
    required this.head,
    required this.chest,
    required this.relativeYawDeg,
    required this.headColor,
    required this.chestColor,
    required this.outlineColor,
    required this.textColor,
    required this.viewYawDeg,
    required this.viewPitchDeg,
  });

  final Mg24SensorSummary head;
  final Mg24SensorSummary chest;
  final double? relativeYawDeg;
  final Color headColor;
  final Color chestColor;
  final Color outlineColor;
  final Color textColor;
  final double viewYawDeg;
  final double viewPitchDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.53);
    final scale = math.min(size.width / 340, size.height / 270);
    const headCenter = _Vec3(30, -2, 0);
    const chestCenter = _Vec3(-30, 4, 0);

    _drawSceneShadow(canvas, origin, scale);
    _drawTorso(canvas, center: chestCenter, origin: origin, scale: scale);
    _drawHead(canvas, center: headCenter, origin: origin, scale: scale);
  }

  void _drawSceneShadow(Canvas canvas, Offset origin, double scale) {
    final shadow = _projectScene(const _Vec3(0, 116, 34), origin, scale);
    final paint = Paint()
      ..color = outlineColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: shadow.offset,
        width: 150 * scale * shadow.perspective,
        height: 22 * scale * shadow.perspective,
      ),
      paint,
    );
  }

  void _drawTorso(
    Canvas canvas, {
    required _Vec3 center,
    required Offset origin,
    required double scale,
  }) {
    final active = chest.connected;
    final color = active ? chestColor : outlineColor;
    final localVertices = <_Vec3>[
      const _Vec3(-78, -52, -26),
      const _Vec3(78, -52, -26),
      const _Vec3(58, 52, -22),
      const _Vec3(-58, 52, -22),
      const _Vec3(-78, -52, 26),
      const _Vec3(78, -52, 26),
      const _Vec3(58, 52, 22),
      const _Vec3(-58, 52, 22),
    ];
    final points = localVertices
        .map(
          (point) => _projectLocal(
            center,
            chest,
            point,
            origin,
            scale,
            isForehead: false,
          ),
        )
        .toList(growable: false);
    _drawFaces(
      canvas,
      points,
      const [
        _Face3D([0, 1, 2, 3], 0.18),
        _Face3D([4, 5, 6, 7], 0.08),
        _Face3D([0, 4, 7, 3], 0.10),
        _Face3D([1, 5, 6, 2], 0.10),
        _Face3D([0, 1, 5, 4], 0.12),
        _Face3D([3, 2, 6, 7], 0.07),
      ],
      color: color,
      active: active,
    );
    _drawEdges(
      canvas,
      points,
      const [
        [0, 1],
        [1, 2],
        [2, 3],
        [3, 0],
        [4, 5],
        [5, 6],
        [6, 7],
        [7, 4],
        [0, 4],
        [1, 5],
        [2, 6],
        [3, 7],
      ],
      color: color,
      active: active,
      scale: scale,
    );
    _drawOrientationAxes(
      canvas,
      center,
      chest,
      origin,
      scale,
      active,
      isForehead: false,
    );
  }

  void _drawHead(
    Canvas canvas, {
    required _Vec3 center,
    required Offset origin,
    required double scale,
  }) {
    final active = head.connected;
    final color = active ? headColor : outlineColor;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.15 : 0.16)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = color.withValues(alpha: active ? 0.90 : 0.64)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.1 : 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final innerStroke = Paint()
      ..color = color.withValues(alpha: active ? 0.40 : 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    final silhouette = _ringPath(
      center: center,
      sensor: head,
      axisA: const _Vec3(36, 0, 0),
      axisB: const _Vec3(0, 42, 0),
      origin: origin,
      scale: scale,
      isForehead: true,
    );
    canvas.drawPath(silhouette, fillPaint);
    canvas.drawPath(silhouette, strokePaint);
    canvas.drawPath(
      _ringPath(
        center: center,
        sensor: head,
        axisA: const _Vec3(0, 40, 0),
        axisB: const _Vec3(0, 0, 25),
        origin: origin,
        scale: scale,
        isForehead: true,
      ),
      innerStroke,
    );
    canvas.drawPath(
      _ringPath(
        center: center,
        sensor: head,
        axisA: const _Vec3(34, 0, 0),
        axisB: const _Vec3(0, 0, 25),
        origin: origin,
        scale: scale,
        isForehead: true,
      ),
      innerStroke,
    );

    _drawLocalLine(
      canvas,
      center,
      head,
      const _Vec3(16, 0, 0),
      const _Vec3(58, 0, 0),
      origin,
      scale,
      color.withValues(alpha: active ? 0.95 : 0.50),
      2.4,
      isForehead: true,
      endDot: 3.6,
    );
    _drawLocalDot(
      canvas,
      center,
      head,
      const _Vec3(0, -39, 0),
      origin,
      scale,
      color.withValues(alpha: active ? 0.95 : 0.50),
      3.2,
      isForehead: true,
    );
    _drawOrientationAxes(
      canvas,
      center,
      head,
      origin,
      scale,
      active,
      isForehead: true,
    );
  }

  void _drawFaces(
    Canvas canvas,
    List<_ProjectedPoint> points,
    List<_Face3D> faces, {
    required Color color,
    required bool active,
  }) {
    final ordered = [...faces]
      ..sort((a, b) => b.depth(points).compareTo(a.depth(points)));
    for (final face in ordered) {
      final path = Path();
      for (var i = 0; i < face.indices.length; i++) {
        final point = points[face.indices[i]].offset;
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: active ? face.alpha : 0.12)
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _drawEdges(
    Canvas canvas,
    List<_ProjectedPoint> points,
    List<List<int>> edges, {
    required Color color,
    required bool active,
    required double scale,
  }) {
    final paint = Paint()
      ..color = color.withValues(alpha: active ? 0.90 : 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.1 : 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final edge in edges) {
      canvas.drawLine(points[edge[0]].offset, points[edge[1]].offset, paint);
    }
  }

  void _drawOrientationAxes(
    Canvas canvas,
    _Vec3 center,
    Mg24SensorSummary sensor,
    Offset origin,
    double scale,
    bool active, {
    required bool isForehead,
  }) {
    final alpha = active ? 0.88 : 0.34;
    _drawLocalLine(
      canvas,
      center,
      sensor,
      _Vec3.zero,
      const _Vec3(34, 0, 0),
      origin,
      scale,
      const Color(0xFFD64F3B).withValues(alpha: alpha),
      1.8,
      isForehead: isForehead,
      endDot: 2.6,
    );
    _drawLocalLine(
      canvas,
      center,
      sensor,
      _Vec3.zero,
      const _Vec3(0, -34, 0),
      origin,
      scale,
      const Color(0xFF2E9D72).withValues(alpha: alpha),
      1.8,
      isForehead: isForehead,
      endDot: 2.6,
    );
    _drawLocalLine(
      canvas,
      center,
      sensor,
      _Vec3.zero,
      const _Vec3(0, 0, -34),
      origin,
      scale,
      const Color(0xFF3B77D8).withValues(alpha: alpha),
      1.8,
      isForehead: isForehead,
      endDot: 2.6,
    );
  }

  void _drawLocalLine(
    Canvas canvas,
    _Vec3 center,
    Mg24SensorSummary sensor,
    _Vec3 start,
    _Vec3 end,
    Offset origin,
    double scale,
    Color color,
    double strokeWidth, {
    required bool isForehead,
    double endDot = 0,
  }) {
    final a = _projectLocal(
      center,
      sensor,
      start,
      origin,
      scale,
      isForehead: isForehead,
    );
    final b = _projectLocal(
      center,
      sensor,
      end,
      origin,
      scale,
      isForehead: isForehead,
    );
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth * scale
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a.offset, b.offset, paint);
    if (endDot > 0) {
      canvas.drawCircle(b.offset, endDot * scale, Paint()..color = color);
    }
  }

  void _drawLocalDot(Canvas canvas, _Vec3 center, Mg24SensorSummary sensor,
      _Vec3 local, Offset origin, double scale, Color color, double radius,
      {required bool isForehead}) {
    final point = _projectLocal(
      center,
      sensor,
      local,
      origin,
      scale,
      isForehead: isForehead,
    );
    canvas.drawCircle(point.offset, radius * scale, Paint()..color = color);
  }

  Path _ringPath({
    required _Vec3 center,
    required Mg24SensorSummary sensor,
    required _Vec3 axisA,
    required _Vec3 axisB,
    required Offset origin,
    required double scale,
    required bool isForehead,
  }) {
    const steps = 44;
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final t = 2 * math.pi * i / steps;
      final local = axisA.scaled(math.cos(t)) + axisB.scaled(math.sin(t));
      final point = _projectLocal(
        center,
        sensor,
        local,
        origin,
        scale,
        isForehead: isForehead,
      ).offset;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path;
  }

  _ProjectedPoint _projectLocal(_Vec3 center, Mg24SensorSummary sensor,
      _Vec3 local, Offset origin, double scale,
      {required bool isForehead}) {
    return _projectScene(
      center + _rotateSensor(local, sensor, isForehead: isForehead),
      origin,
      scale,
    );
  }

  _ProjectedPoint _projectScene(_Vec3 point, Offset origin, double scale) {
    final viewed = _rotateView(point);
    const distance = 520.0;
    final perspective = distance / (distance + viewed.z);
    return _ProjectedPoint(
      Offset(
        origin.dx + viewed.x * scale * perspective,
        origin.dy + viewed.y * scale * perspective,
      ),
      viewed.z,
      perspective,
    );
  }

  _Vec3 _rotateSensor(
    _Vec3 point,
    Mg24SensorSummary sensor, {
    required bool isForehead,
  }) {
    final quaternion = _visualQuaternion(
      sensor,
      isForehead: isForehead,
      relativeYawDeg: relativeYawDeg,
    );
    if (quaternion != null) {
      return quaternion.rotate(_visualZeroPoseQuaternion().rotate(point));
    }
    return _rotateEuler(
      _visualZeroPoseQuaternion().rotate(point),
      rollDeg: _finiteAngle(sensor.rollDeg ?? sensor.angleDeg),
      pitchDeg: _finiteAngle(sensor.pitchDeg),
      yawDeg: 0,
    );
  }

  _Vec3 _rotateView(_Vec3 point) {
    return _rotateEuler(
      point,
      rollDeg: viewPitchDeg,
      pitchDeg: viewYawDeg,
      yawDeg: 0,
    );
  }

  _Vec3 _rotateEuler(
    _Vec3 point, {
    required double rollDeg,
    required double pitchDeg,
    required double yawDeg,
  }) {
    final roll = rollDeg * math.pi / 180;
    final pitch = pitchDeg * math.pi / 180;
    final yaw = yawDeg * math.pi / 180;

    var x = point.x;
    var y = point.y * math.cos(roll) - point.z * math.sin(roll);
    var z = point.y * math.sin(roll) + point.z * math.cos(roll);

    final pitchX = x * math.cos(pitch) + z * math.sin(pitch);
    z = -x * math.sin(pitch) + z * math.cos(pitch);
    x = pitchX;

    final yawX = x * math.cos(yaw) - y * math.sin(yaw);
    y = x * math.sin(yaw) + y * math.cos(yaw);
    x = yawX;

    return _Vec3(x, y, z);
  }

  double _finiteAngle(double? value) {
    if (value == null || !value.isFinite) return 0;
    return value;
  }

  @override
  bool shouldRepaint(covariant _Mg24BodyPainter oldDelegate) {
    return oldDelegate.head != head ||
        oldDelegate.chest != chest ||
        oldDelegate.relativeYawDeg != relativeYawDeg ||
        oldDelegate.headColor != headColor ||
        oldDelegate.chestColor != chestColor ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.viewYawDeg != viewYawDeg ||
        oldDelegate.viewPitchDeg != viewPitchDeg;
  }
}

class _MiniValue extends StatelessWidget {
  const _MiniValue({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label $value',
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _Mg24MeshPair {
  const _Mg24MeshPair({
    required this.head,
    required this.chest,
  });

  final _Mg24MeshAsset head;
  final _Mg24MeshAsset chest;
}

class _Mg24MeshAsset {
  const _Mg24MeshAsset({
    required this.vertices,
    required this.faces,
    required this.center,
  });

  final List<_Vec3> vertices;
  final List<_MeshTriangle> faces;
  final _Vec3 center;

  static Future<_Mg24MeshAsset> load(String asset) async {
    final text = await rootBundle.loadString(asset);
    final data = jsonDecode(text) as Map<String, dynamic>;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var maxZ = -double.infinity;
    final vertices = (data['vertices'] as List).map((entry) {
      final values = entry as List;
      final vertex = _Vec3(
        (values[0] as num).toDouble(),
        (values[1] as num).toDouble(),
        (values[2] as num).toDouble(),
      );
      minX = math.min(minX, vertex.x);
      minY = math.min(minY, vertex.y);
      minZ = math.min(minZ, vertex.z);
      maxX = math.max(maxX, vertex.x);
      maxY = math.max(maxY, vertex.y);
      maxZ = math.max(maxZ, vertex.z);
      return vertex;
    }).toList(growable: false);
    final faces = (data['faces'] as List).map((entry) {
      final values = entry as List;
      return _MeshTriangle(
        (values[0] as num).toInt(),
        (values[1] as num).toInt(),
        (values[2] as num).toInt(),
      );
    }).toList(growable: false);
    final center = _Vec3(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
      (minZ + maxZ) / 2,
    );
    return _Mg24MeshAsset(vertices: vertices, faces: faces, center: center);
  }
}

class _MeshTriangle {
  const _MeshTriangle(this.a, this.b, this.c);

  final int a;
  final int b;
  final int c;
}

class _MeshPaintFace {
  const _MeshPaintFace({
    required this.path,
    required this.depth,
    required this.color,
    required this.alpha,
  });

  final Path path;
  final double depth;
  final Color color;
  final double alpha;
}

_Quaternion? _visualQuaternion(
  Mg24SensorSummary sensor, {
  required bool isForehead,
  double? relativeYawDeg,
}) {
  // The 6-DoF boards cannot provide a drift-free heading. Keep the argument
  // for the shared scene API, but do not add relative yaw back after removing
  // rotation around gravity.
  return _visualPose(sensor, isForehead: isForehead)?.quaternion;
}

_VisualPose? _visualPose(
  Mg24SensorSummary sensor, {
  required bool isForehead,
}) {
  if (!sensor.connected) {
    _resetGravityYawFilter(isForehead);
    return null;
  }
  // Journal and correlation poses contain snapshots without a BLE identity or
  // board quaternion. They must not advance the stateful live-pose filter:
  // otherwise rendering another card changes the pose of this snapshot.
  if (sensor.remoteId == null && _sensorQuaternion(sensor) == null) {
    return _statelessArchivedVisualPose(sensor, isForehead: isForehead);
  }
  final state = _gravityYawFilterState(isForehead);
  if (state.poseCalibrationEpoch != sensor.poseCalibrationEpoch) {
    state.reset();
    state.poseCalibrationEpoch = sensor.poseCalibrationEpoch;
  }
  final key = _visualPoseKey(sensor);
  if (state.cachedPoseKey == key) return state.cachedPose;

  final base = _baseVisualQuaternion(sensor);
  if (base == null) return null;
  var visual = _sceneYawlessVisualQuaternion(
    base,
    state,
    isForehead: isForehead,
  );
  if (visual == null) return null;
  if (state.visual != null && visual.dot(state.visual!) < 0) {
    visual = visual.negated();
  }
  final leftRightRad = state.integratedLeftRightRad;
  final depthRad = state.integratedDepthRad;
  if (leftRightRad == null || depthRad == null) return null;
  final displayVisual = _invertDisplayedRotationAxis(visual);
  final pose = _VisualPose(
    quaternion: displayVisual,
    leftRightRad: -leftRightRad,
    depthRad: depthRad,
  );
  state
    ..visual = visual
    ..cachedPoseKey = key
    ..cachedPose = pose;
  return pose;
}

_VisualPose? _statelessArchivedVisualPose(
  Mg24SensorSummary sensor, {
  required bool isForehead,
}) {
  final base = _baseVisualQuaternion(sensor);
  if (base == null) return null;
  var visual = _sensorRotationToVisualRotation(base).normalized();
  if (visual == null) return null;
  if (isForehead) visual = _mapForeheadSceneAxes(visual);
  final yawless = _sceneGravityTiltQuaternion(visual) ?? visual;
  final tilt = _continuousVisualTiltAnglesFromSceneQuaternion(yawless);
  if (tilt == null) return null;
  return _VisualPose(
    quaternion: _invertDisplayedRotationAxis(yawless),
    leftRightRad: -tilt.leftRightRad,
    depthRad: tilt.depthRad,
  );
}

_Quaternion _invertDisplayedRotationAxis(_Quaternion visual) {
  const halfTurnAroundDepthAxis = _Quaternion(0, 1, 0, 0);
  return (halfTurnAroundDepthAxis *
              visual *
              halfTurnAroundDepthAxis.conjugated())
          .normalized() ??
      visual;
}

@visibleForTesting
({double rotationDeg, double tiltDeg}) visualAxisInversionForTest({
  required double rotationDeg,
  required double tiltDeg,
}) {
  final source = _orderedSceneTiltQuaternion(
    rotationDeg * math.pi / 180,
    tiltDeg * math.pi / 180,
  );
  final mapped = _invertDisplayedRotationAxis(source);
  final angles = _continuousVisualTiltAnglesFromSceneQuaternion(mapped)!;
  return (
    rotationDeg: angles.leftRightRad * 180 / math.pi,
    tiltDeg: angles.depthRad * 180 / math.pi,
  );
}

@visibleForTesting
({
  double w,
  double x,
  double y,
  double z,
  double rotationDeg,
  double tiltDeg,
}) visualArchivedPoseForTest({
  required double rollDeg,
  required double pitchDeg,
  required double yawDeg,
  required bool isForehead,
}) {
  final sensor = const Mg24SensorSummary.empty().copyWith(
    connected: true,
    rollDeg: rollDeg,
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    angleDeg: rollDeg,
  );
  final pose = _statelessArchivedVisualPose(sensor, isForehead: isForehead)!;
  return (
    w: pose.quaternion.w,
    x: pose.quaternion.x,
    y: pose.quaternion.y,
    z: pose.quaternion.z,
    rotationDeg: _wrapAngleDeg(pose.leftRightRad * 180 / math.pi),
    tiltDeg: _wrapAngleDeg(pose.depthRad * 180 / math.pi),
  );
}

_Quaternion _orderedSceneTiltQuaternion(double leftRightRad, double depthRad) {
  final depth = _axisAngleQuaternion(const _Vec3(1, 0, 0), depthRad);
  final leftRight = _axisAngleQuaternion(const _Vec3(0, 0, 1), leftRightRad);
  // Preserve the established LASLI scene convention.
  return (leftRight * depth).normalized() ?? leftRight;
}

_Quaternion _axisAngleQuaternion(_Vec3 axis, double angleRad) {
  final unit = axis.normalized();
  final half = angleRad * 0.5;
  final sinHalf = math.sin(half);
  return _Quaternion(
    math.cos(half),
    unit.x * sinHalf,
    unit.y * sinHalf,
    unit.z * sinHalf,
  );
}

Object _visualPoseKey(Mg24SensorSummary sensor) {
  return (
    connected: sensor.connected,
    updatedAtUs: sensor.lastUpdate?.microsecondsSinceEpoch,
    roll: sensor.rollDeg,
    pitch: sensor.pitchDeg,
    yaw: sensor.yawDeg,
    qw: sensor.qw,
    qx: sensor.qx,
    qy: sensor.qy,
    qz: sensor.qz,
    poseCalibrationEpoch: sensor.poseCalibrationEpoch,
  );
}

_Quaternion? _baseVisualQuaternion(Mg24SensorSummary sensor) {
  final sensorQuaternion = _sensorQuaternion(sensor);
  if (sensorQuaternion != null) return sensorQuaternion;

  final rollDeg = sensor.rollDeg ?? sensor.angleDeg;
  final pitchDeg = sensor.pitchDeg;
  if (rollDeg == null || pitchDeg == null) return null;
  if (!rollDeg.isFinite || !pitchDeg.isFinite) return null;

  return _bodyVisualSensorQuaternion(
    _quaternionFromEulerDegrees(
      rollDeg: rollDeg,
      pitchDeg: pitchDeg,
      yawDeg: _finiteVisualDeg(sensor.yawDeg),
    ),
  );
}

_Quaternion? _bodyVisualSensorQuaternion(_Quaternion quaternion) {
  final q = quaternion.normalized();
  if (q == null) return null;

  // Keep the board quaternion in the firmware/body convention. The UI maps
  // this quaternion into scene coordinates later; changing axes here couples
  // otherwise clean board roll into both visual tilt axes.
  return q;
}

_Quaternion? _sensorQuaternion(Mg24SensorSummary sensor) {
  final w = sensor.qw;
  final x = sensor.qx;
  final y = sensor.qy;
  final z = sensor.qz;
  if (w == null || x == null || y == null || z == null) return null;
  if (!w.isFinite || !x.isFinite || !y.isFinite || !z.isFinite) return null;
  return _bodyVisualSensorQuaternion(_Quaternion(w, x, y, z));
}

_Quaternion? _sceneYawlessVisualQuaternion(
  _Quaternion sensorRotation,
  _GravityYawFilterState state, {
  required bool isForehead,
}) {
  var visualRotation =
      _sensorRotationToVisualRotation(sensorRotation).normalized();
  if (visualRotation == null) return null;
  if (isForehead) {
    visualRotation = _mapForeheadSceneAxes(visualRotation);
  }
  return _sceneGravityTiltQuaternion(visualRotation, state: state);
}

_Quaternion? _sceneGravityTiltQuaternion(_Quaternion rawRotation,
    {_GravityYawFilterState? state}) {
  final raw = rawRotation.normalized();
  if (raw == null) return null;

  var continuousRaw = raw;
  final previousRaw = state?.lastRawRotation;
  if (previousRaw != null && continuousRaw.dot(previousRaw) < 0) {
    continuousRaw = continuousRaw.negated();
  }

  final yawless = _lockWorldYawToHeadAxis(
    continuousRaw,
    previousVisual: state?.visual,
  );
  if (yawless == null) return null;
  var visual = yawless;
  final tilt = _continuousVisualTiltAnglesFromSceneQuaternion(
    visual,
    previousLeftRightRad: state?.integratedLeftRightRad,
    previousDepthRad: state?.integratedDepthRad,
  );
  if (tilt == null) return null;
  final previousVisual = state?.visual;
  if (previousVisual != null && visual.dot(previousVisual) < 0) {
    visual = visual.negated();
  }

  if (state != null) {
    state
      ..lastRawRotation = continuousRaw
      ..integratedLeftRightRad = tilt.leftRightRad
      ..integratedDepthRad = tilt.depthRad;
  }
  return visual;
}

_Quaternion? _lockWorldYawToHeadAxis(
  _Quaternion rawRotation, {
  _Quaternion? previousVisual,
}) {
  final q = rawRotation.normalized();
  if (q == null) return null;

  // The calibrated torso-to-head direction is scene +X. Its horizontal
  // projection defines the displayed heading, so the same full quaternion
  // always produces the same yaw-free pose and no closed path can accumulate
  // a visual yaw residue.
  final headAxis = q.rotate(const _Vec3(1, 0, 0));
  final headHorizontalSq = headAxis.x * headAxis.x + headAxis.z * headAxis.z;
  late final double worldYawRad;
  if (headHorizontalSq > 0.007596123493895969) {
    worldYawRad = math.atan2(-headAxis.z, headAxis.x);
  } else {
    // Within five degrees of the unavoidable head-axis singularity, use the
    // orthogonal depth axis. This makes the branch deterministic and avoids
    // noise-driven heading flutter while the anatomical heading is undefined.
    final depthAxis = q.rotate(const _Vec3(0, 0, 1));
    worldYawRad = math.atan2(depthAxis.x, depthAxis.z);
  }
  final removeYaw = _axisAngleQuaternion(const _Vec3(0, 1, 0), -worldYawRad);
  var visual = (removeYaw * q).normalized();
  if (visual == null) return null;
  if (previousVisual != null && visual.dot(previousVisual) < 0) {
    visual = visual.negated();
  }
  return visual;
}

_Quaternion _mapForeheadSceneAxes(_Quaternion visualRotation) {
  // The forehead board is mounted 90 degrees around the scene's gravity axis
  // relative to the belly board. Transform the complete quaternion before
  // heading removal; swapping decomposed angles afterward becomes nonlinear
  // and over-amplifies rotation when the head is already strongly tilted.
  final mounting = _foreheadSceneMountingQuaternion();
  return (mounting * visualRotation * mounting.conjugated()).normalized() ??
      visualRotation;
}

_Quaternion _foreheadSceneMountingQuaternion() {
  final half = -math.pi / 4;
  return _Quaternion(math.cos(half), 0, math.sin(half), 0);
}

@visibleForTesting
({
  double foreheadRotationDeg,
  double foreheadTiltDeg,
  double bellyRotationDeg,
  double bellyTiltDeg,
}) visualTiltMountingComparisonForTest({
  required double rotationDeg,
  required double tiltDeg,
}) {
  final intendedScene = _orderedSceneTiltQuaternion(
    rotationDeg * math.pi / 180,
    tiltDeg * math.pi / 180,
  );
  final half = -math.pi / 4;
  final foreheadMounting = _Quaternion(math.cos(half), 0, math.sin(half), 0);
  final unmountedForeheadScene =
      foreheadMounting.conjugated() * intendedScene * foreheadMounting;

  _Quaternion sceneToSensor(_Quaternion scene) {
    final basis = _sensorToVisualBasisQuaternion();
    final mounted = basis.conjugated() * scene * basis;
    final sensorMounting = _visualMountingSwapQuaternion();
    return (sensorMounting * mounted * sensorMounting.conjugated())
            .normalized() ??
        mounted;
  }

  ({double rotationDeg, double tiltDeg}) calculate(
    _Quaternion scene, {
    required bool isForehead,
  }) {
    var visual = _sensorRotationToVisualRotation(sceneToSensor(scene));
    if (isForehead) visual = _mapForeheadSceneAxes(visual);
    final yawless = _sceneGravityTiltQuaternion(visual) ?? visual;
    final tilt = _continuousVisualTiltAnglesFromSceneQuaternion(yawless);
    return (
      rotationDeg: (tilt?.leftRightRad ?? 0) * 180 / math.pi,
      tiltDeg: (tilt?.depthRad ?? 0) * 180 / math.pi,
    );
  }

  final forehead = calculate(
    unmountedForeheadScene,
    isForehead: true,
  );
  final belly = calculate(intendedScene, isForehead: false);
  return (
    foreheadRotationDeg: forehead.rotationDeg,
    foreheadTiltDeg: forehead.tiltDeg,
    bellyRotationDeg: belly.rotationDeg,
    bellyTiltDeg: belly.tiltDeg,
  );
}

@visibleForTesting
List<
    ({
      double w,
      double x,
      double y,
      double z,
      double rotationDeg,
      double tiltDeg,
    })> visualGravityFilteredTrajectoryForTest(
    List<
            ({
              double worldYawDeg,
              double rotationDeg,
              double tiltDeg,
            })>
        samples,
    {bool quantizeLikeBle = false}) {
  final state = _GravityYawFilterState();
  final result = <({
    double w,
    double x,
    double y,
    double z,
    double rotationDeg,
    double tiltDeg,
  })>[];
  for (final sample in samples) {
    final yaw = _axisAngleQuaternion(
      const _Vec3(0, 1, 0),
      sample.worldYawDeg * math.pi / 180,
    );
    final depth = _axisAngleQuaternion(
      const _Vec3(1, 0, 0),
      sample.tiltDeg * math.pi / 180,
    );
    final rotation = _axisAngleQuaternion(
      const _Vec3(0, 0, 1),
      sample.rotationDeg * math.pi / 180,
    );
    final sensorOrder = (rotation * depth).normalized() ?? depth;
    var raw = (yaw * sensorOrder).normalized() ?? sensorOrder;
    if (quantizeLikeBle) {
      double quantize(double value) =>
          (value.clamp(-1.0, 1.0) * 32767).round() / 32767;
      raw = _Quaternion(
            quantize(raw.w),
            quantize(raw.x),
            quantize(raw.y),
            quantize(raw.z),
          ).normalized() ??
          raw;
    }
    final visual = _sceneGravityTiltQuaternion(raw, state: state)!;
    state.visual = visual;
    result.add((
      w: visual.w,
      x: visual.x,
      y: visual.y,
      z: visual.z,
      rotationDeg: (state.integratedLeftRightRad ?? 0) * 180 / math.pi,
      tiltDeg: (state.integratedDepthRad ?? 0) * 180 / math.pi,
    ));
  }
  return result;
}

@visibleForTesting
({
  double w,
  double x,
  double y,
  double z,
  double rotationDeg,
  double tiltDeg,
}) visualGravityFilterNeutralRecoveryForTest() {
  final inverted = _orderedSceneTiltQuaternion(math.pi, math.pi);
  final state = _GravityYawFilterState()
    ..lastRawRotation = const _Quaternion(1, 0, 0, 0)
    ..visual = inverted
    ..integratedLeftRightRad = math.pi
    ..integratedDepthRad = math.pi;
  final visual = _sceneGravityTiltQuaternion(
    const _Quaternion(1, 0, 0, 0),
    state: state,
  )!;
  return (
    w: visual.w,
    x: visual.x,
    y: visual.y,
    z: visual.z,
    rotationDeg: (state.integratedLeftRightRad ?? 0) * 180 / math.pi,
    tiltDeg: (state.integratedDepthRad ?? 0) * 180 / math.pi,
  );
}

({double leftRightRad, double depthRad})?
    _continuousVisualTiltAnglesFromSceneQuaternion(
  _Quaternion quaternion, {
  double? previousLeftRightRad,
  double? previousDepthRad,
}) {
  var q = quaternion.normalized();
  if (q == null) return null;
  if (q.w < 0) q = q.negated();

  final rotationLength = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
  if (rotationLength < 1e-9) return (leftRightRad: 0, depthRad: 0);

  final angle = 2 * math.atan2(rotationLength, q.w);
  final primary = (
    leftRightRad: angle * q.z / rotationLength,
    depthRad: angle * q.x / rotationLength,
  );
  if (previousLeftRightRad == null || previousDepthRad == null) {
    return primary;
  }

  final alternateAngle = -(2 * math.pi - angle);
  final alternate = (
    leftRightRad: alternateAngle * q.z / rotationLength,
    depthRad: alternateAngle * q.x / rotationLength,
  );

  return _tiltDistanceSquared(
            primary,
            previousLeftRightRad,
            previousDepthRad,
          ) <=
          _tiltDistanceSquared(
            alternate,
            previousLeftRightRad,
            previousDepthRad,
          )
      ? primary
      : alternate;
}

double _tiltDistanceSquared(
  ({double leftRightRad, double depthRad}) tilt,
  double previousLeftRightRad,
  double previousDepthRad,
) {
  final dLeftRight = tilt.leftRightRad - previousLeftRightRad;
  final dDepth = tilt.depthRad - previousDepthRad;
  return dLeftRight * dLeftRight + dDepth * dDepth;
}

_GravityYawFilterState _gravityYawFilterState(bool isForehead) {
  return isForehead ? _foreheadGravityYawFilter : _bellyGravityYawFilter;
}

void _resetGravityYawFilter(bool isForehead) {
  _gravityYawFilterState(isForehead).reset();
}

void _calibrateMg24VisualFlatPose(Mg24State mg24) {
  _calibrateMg24VisualFlatPoseForSensor(
    mg24.forehead,
    isForehead: true,
  );
  _calibrateMg24VisualFlatPoseForSensor(
    mg24.belly,
    isForehead: false,
  );
}

void _calibrateMg24VisualFlatPoseForSensor(
  Mg24SensorSummary sensor, {
  required bool isForehead,
}) {
  final current = _baseVisualQuaternion(sensor)?.normalized();
  if (!sensor.connected || current == null) {
    _resetGravityYawFilter(isForehead);
    return;
  }
  _gravityYawFilterState(isForehead)
    ..lastRawRotation = null
    ..visual = const _Quaternion(1, 0, 0, 0)
    ..integratedLeftRightRad = 0
    ..integratedDepthRad = 0
    ..poseCalibrationEpoch = sensor.poseCalibrationEpoch
    ..cachedPoseKey = null
    ..cachedPose = null;
}

final _foreheadGravityYawFilter = _GravityYawFilterState();
final _bellyGravityYawFilter = _GravityYawFilterState();

class _GravityYawFilterState {
  _Quaternion? lastRawRotation;
  _Quaternion? visual;
  double? integratedLeftRightRad;
  double? integratedDepthRad;
  int? poseCalibrationEpoch;
  Object? cachedPoseKey;
  _VisualPose? cachedPose;

  void reset() {
    lastRawRotation = null;
    visual = null;
    integratedLeftRightRad = null;
    integratedDepthRad = null;
    poseCalibrationEpoch = null;
    cachedPoseKey = null;
    cachedPose = null;
  }
}

class _VisualPose {
  const _VisualPose({
    required this.quaternion,
    required this.leftRightRad,
    required this.depthRad,
  });

  final _Quaternion quaternion;
  final double leftRightRad;
  final double depthRad;
}

_Quaternion _visualZeroPoseQuaternion() {
  return _quaternionFromEulerDegrees(
    rollDeg: 0,
    pitchDeg: 90,
    yawDeg: 90,
  );
}

_Quaternion _sensorRotationToVisualRotation(_Quaternion sensorRotation) {
  final mountedSensorRotation = _visualMountingSwapQuaternion().conjugated() *
      sensorRotation *
      _visualMountingSwapQuaternion();
  final basis = _sensorToVisualBasisQuaternion();
  return basis * mountedSensorRotation * basis.conjugated();
}

_Quaternion _visualMountingSwapQuaternion() {
  // The physical forehead/belly mounting is rotated 90 degrees around the
  // sensor normal compared with the board's roll/pitch convention. Apply that
  // only to the 3D visualization so raw values and signal processing stay in
  // the board convention.
  final half = math.pi / 4;
  return _Quaternion(math.cos(half), 0, 0, math.sin(half));
}

_Quaternion _sensorToVisualBasisQuaternion() {
  // Sensor fusion convention: gravity/yaw axis is Z.
  // LASLI scene convention: gravity is vertical on screen, the Y axis.
  return _quaternionFromEulerRadians(
    roll: -math.pi / 2,
    pitch: 0,
    yaw: 0,
  );
}

String _visualModelOrientation(
  Mg24SensorSummary sensor, {
  required bool isForehead,
  double? relativeYawDeg,
}) {
  final sensorQuaternion = _visualQuaternion(
    sensor,
    isForehead: isForehead,
    relativeYawDeg: relativeYawDeg,
  );
  final quaternion = sensorQuaternion == null
      ? null
      : (sensorQuaternion * _visualZeroPoseQuaternion()).normalized();
  final euler =
      quaternion == null ? null : _modelViewerEulerFromQuaternion(quaternion);
  final roll = euler?.$1 ?? _finiteVisualDeg(sensor.rollDeg ?? sensor.angleDeg);
  final pitch = euler?.$2 ?? _finiteVisualDeg(sensor.pitchDeg);
  final yaw = euler?.$3 ?? 0;
  return '${roll.toStringAsFixed(1)}deg '
      '${pitch.toStringAsFixed(1)}deg '
      '${yaw.toStringAsFixed(1)}deg';
}

(double, double, double)? _modelViewerEulerFromQuaternion(
  _Quaternion quaternion,
) {
  final q = quaternion.normalized();
  if (q == null) return null;

  // model-viewer applies orientation as Y(yaw) * X(pitch) * Z(roll), while
  // the common quaternion-to-Euler formula is ZYX. Extract the exact YXZ
  // order expected by its `$roll $pitch $yaw` attribute.
  final r00 = 1 - 2 * (q.y * q.y + q.z * q.z);
  final r01 = 2 * (q.x * q.y - q.w * q.z);
  final r02 = 2 * (q.x * q.z + q.w * q.y);
  final r10 = 2 * (q.x * q.y + q.w * q.z);
  final r11 = 1 - 2 * (q.x * q.x + q.z * q.z);
  final r12 = 2 * (q.y * q.z - q.w * q.x);
  final r22 = 1 - 2 * (q.x * q.x + q.y * q.y);

  final sinPitch = (-r12).clamp(-1.0, 1.0).toDouble();
  final pitch = math.asin(sinPitch);
  final cosPitch = math.cos(pitch);
  final double roll;
  final double yaw;
  if (cosPitch.abs() > 1e-7) {
    roll = math.atan2(r10, r11);
    yaw = math.atan2(r02, r22);
  } else {
    // At model-viewer's own Euler singularity, yaw and roll are equivalent.
    // Choosing roll=0 yields the same quaternion and avoids an arbitrary
    // split between both displayed model axes.
    roll = 0;
    yaw = math.atan2(sinPitch * r01, r00);
  }

  return (
    _normalizeVisualAngleDeg(roll * 180 / math.pi),
    _normalizeVisualAngleDeg(pitch * 180 / math.pi),
    _normalizeVisualAngleDeg(yaw * 180 / math.pi),
  );
}

_Quaternion _quaternionFromModelViewerEulerDegrees({
  required double rollDeg,
  required double pitchDeg,
  required double yawDeg,
}) {
  final roll = _axisAngleQuaternion(
    const _Vec3(0, 0, 1),
    rollDeg * math.pi / 180,
  );
  final pitch = _axisAngleQuaternion(
    const _Vec3(1, 0, 0),
    pitchDeg * math.pi / 180,
  );
  final yaw = _axisAngleQuaternion(
    const _Vec3(0, 1, 0),
    yawDeg * math.pi / 180,
  );
  return (yaw * pitch * roll).normalized() ?? yaw;
}

@visibleForTesting
double modelViewerOrientationRoundTripErrorDegForTest({
  required double worldYawDeg,
  required double rotationDeg,
  required double tiltDeg,
}) {
  final worldYaw = _axisAngleQuaternion(
    const _Vec3(0, 1, 0),
    worldYawDeg * math.pi / 180,
  );
  final source = (worldYaw *
          _orderedSceneTiltQuaternion(
            rotationDeg * math.pi / 180,
            tiltDeg * math.pi / 180,
          ))
      .normalized()!;
  final visual = _sceneGravityTiltQuaternion(source)!;
  final model = (visual * _visualZeroPoseQuaternion()).normalized()!;
  final euler = _modelViewerEulerFromQuaternion(model)!;
  final rebuilt = _quaternionFromModelViewerEulerDegrees(
    rollDeg: euler.$1,
    pitchDeg: euler.$2,
    yawDeg: euler.$3,
  );
  final dot = model.dot(rebuilt).abs().clamp(0.0, 1.0).toDouble();
  return 2 * math.acos(dot) * 180 / math.pi;
}

_Quaternion _quaternionFromEulerDegrees({
  required double rollDeg,
  required double pitchDeg,
  required double yawDeg,
}) {
  return _quaternionFromEulerRadians(
    roll: rollDeg * math.pi / 180,
    pitch: pitchDeg * math.pi / 180,
    yaw: yawDeg * math.pi / 180,
  );
}

_Quaternion _quaternionFromEulerRadians({
  required double roll,
  required double pitch,
  required double yaw,
}) {
  final cr = math.cos(roll * 0.5);
  final sr = math.sin(roll * 0.5);
  final cp = math.cos(pitch * 0.5);
  final sp = math.sin(pitch * 0.5);
  final cy = math.cos(yaw * 0.5);
  final sy = math.sin(yaw * 0.5);

  return _Quaternion(
    cy * cp * cr + sy * sp * sr,
    cy * cp * sr - sy * sp * cr,
    sy * cp * sr + cy * sp * cr,
    sy * cp * cr - cy * sp * sr,
  );
}

double _finiteVisualDeg(double? value) {
  if (value == null || !value.isFinite) return 0;
  return value;
}

double _normalizeVisualAngleDeg(double value) {
  if (!value.isFinite) return 0;
  var result = value % 360;
  if (result > 180) result -= 360;
  if (result < -180) result += 360;
  return result;
}

class _Quaternion {
  const _Quaternion(this.w, this.x, this.y, this.z);

  final double w;
  final double x;
  final double y;
  final double z;

  _Quaternion? normalized() {
    final length = math.sqrt(w * w + x * x + y * y + z * z);
    if (!length.isFinite || length <= 1e-9) return null;
    return _Quaternion(w / length, x / length, y / length, z / length);
  }

  _Quaternion conjugated() {
    return _Quaternion(w, -x, -y, -z);
  }

  _Quaternion negated() {
    return _Quaternion(-w, -x, -y, -z);
  }

  double dot(_Quaternion other) {
    return w * other.w + x * other.x + y * other.y + z * other.z;
  }

  _Quaternion operator *(_Quaternion other) {
    return _Quaternion(
      w * other.w - x * other.x - y * other.y - z * other.z,
      w * other.x + x * other.w + y * other.z - z * other.y,
      w * other.y - x * other.z + y * other.w + z * other.x,
      w * other.z + x * other.y - y * other.x + z * other.w,
    );
  }

  _Vec3 rotate(_Vec3 point) {
    final qv = _Vec3(x, y, z);
    final uv = qv.cross(point);
    final uuv = qv.cross(uv);
    return point + uv.scaled(2 * w) + uuv.scaled(2);
  }
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);

  static const zero = _Vec3(0, 0, 0);

  final double x;
  final double y;
  final double z;

  _Vec3 operator +(_Vec3 other) {
    return _Vec3(x + other.x, y + other.y, z + other.z);
  }

  _Vec3 operator -(_Vec3 other) {
    return _Vec3(x - other.x, y - other.y, z - other.z);
  }

  _Vec3 scaled(double factor) {
    return _Vec3(x * factor, y * factor, z * factor);
  }

  double dot(_Vec3 other) {
    return x * other.x + y * other.y + z * other.z;
  }

  _Vec3 cross(_Vec3 other) {
    return _Vec3(
      y * other.z - z * other.y,
      z * other.x - x * other.z,
      x * other.y - y * other.x,
    );
  }

  _Vec3 normalized() {
    final length = math.sqrt(x * x + y * y + z * z);
    if (length <= 1e-9 || !length.isFinite) return zero;
    return _Vec3(x / length, y / length, z / length);
  }
}

class _ProjectedPoint {
  const _ProjectedPoint(this.offset, this.z, this.perspective);

  final Offset offset;
  final double z;
  final double perspective;
}

class _Face3D {
  const _Face3D(this.indices, this.alpha);

  final List<int> indices;
  final double alpha;

  double depth(List<_ProjectedPoint> points) {
    var total = 0.0;
    for (final index in indices) {
      total += points[index].z;
    }
    return total / indices.length;
  }
}

String _formatVisualTiltCompact(
  Mg24SensorSummary sensor, {
  required bool isForehead,
}) {
  final tilt = _visualTiltComponents(sensor, isForehead: isForehead);
  final leftRightAxis = _formatShortDeg(tilt?.$1);
  final depthAxis = _formatShortDeg(tilt?.$2);
  if (leftRightAxis == '--' && depthAxis == '--') return '--';
  return 'Drehung $leftRightAxis / Neigung $depthAxis';
}

String _formatRelativeVisualTiltCompact(Mg24State mg24) {
  final forehead = _visualTiltComponents(mg24.forehead, isForehead: true);
  final belly = _visualTiltComponents(mg24.belly, isForehead: false);
  if (forehead == null || belly == null) return '--';
  final rotation = _formatShortDeg(_wrapAngleDeg(forehead.$1 - belly.$1));
  final tilt = _formatShortDeg(_wrapAngleDeg(forehead.$2 - belly.$2));
  return 'Drehung $rotation / Neigung $tilt';
}

(double, double)? _visualTiltComponents(
  Mg24SensorSummary sensor, {
  required bool isForehead,
}) {
  if (!sensor.connected) {
    _resetGravityYawFilter(isForehead);
    return null;
  }

  final pose = _visualPose(sensor, isForehead: isForehead);
  if (pose == null) return null;
  final leftRightRad = pose.leftRightRad;
  final depthRad = pose.depthRad;
  final leftRightDeg = _wrapAngleDeg(leftRightRad * 180 / math.pi);
  final depthDeg = _wrapAngleDeg(depthRad * 180 / math.pi);
  return (
    leftRightDeg,
    depthDeg,
  );
}

String _formatShortDeg(double? value) {
  if (value == null || !value.isFinite) return '--';
  return value.toStringAsFixed(0);
}

double _wrapAngleDeg(double value) {
  if (!value.isFinite) return value;
  var wrapped = value;
  while (wrapped > 180) {
    wrapped -= 360;
  }
  while (wrapped < -180) {
    wrapped += 360;
  }
  return wrapped;
}

String _formatTemperatureCompact(double? value) {
  if (value == null || !value.isFinite) return '--';
  return '${value.toStringAsFixed(2)} C';
}

// ignore: unused_element
class _RadarPanel extends StatelessWidget {
  const _RadarPanel({
    required this.controller,
    required this.snapshot,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radar = snapshot.radar;
    final running = snapshot.running;
    final canEdit = !running && !radar.connecting;
    final canConnect = canEdit && !radar.connected;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.settings_input_antenna,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Text('MR60BHA2 Radar', style: theme.textTheme.titleSmall),
                ),
                if (radar.connected)
                  Text(
                    radar.host ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: canConnect
                      ? () => controller.connectRadar(
                            hostOverride: radarDefaultHost,
                          )
                      : null,
                  icon: radar.connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('Sensor suchen'),
                ),
                OutlinedButton.icon(
                  onPressed: canEdit
                      ? () => _showHomeWifiSetup(context, controller)
                      : null,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Sensor-WLAN einrichten'),
                ),
                OutlinedButton.icon(
                  onPressed: radar.connected || radar.connecting
                      ? () => controller.disconnectRadar()
                      : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Trennen'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Messdaten laufen ueber ein gemeinsames 2,4-GHz Home-/Handy-WLAN. Das Sensor-WLAN $radarSensorSsidHint ist nur zum Einrichten.',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              radar.status,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            if (radar.metrics.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: radar.metrics
                    .map((metric) => _RadarMetricPill(metric: metric))
                    .toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showHomeWifiSetup(
    BuildContext context,
    MeasurementController controller,
  ) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _HomeWifiRadarSheet(controller: controller),
      );
}

class _HomeWifiRadarSheet extends StatefulWidget {
  const _HomeWifiRadarSheet({required this.controller});

  final MeasurementController controller;

  @override
  State<_HomeWifiRadarSheet> createState() => _HomeWifiRadarSheetState();
}

class _HomeWifiRadarSheetState extends State<_HomeWifiRadarSheet> {
  final TextEditingController _portalController =
      TextEditingController(text: radarDirectHost);
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _hostController =
      TextEditingController(text: radarDefaultHost);

  bool _submitting = false;
  bool _connecting = false;
  bool _obscurePassword = true;
  String? _localStatus;

  @override
  void dispose() {
    _portalController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final busy = _submitting || _connecting;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Home-/Handy-WLAN',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Wenn der Sensor schon im 2,4-GHz Home-/Handy-WLAN ist, unten "Sensor suchen" tippen. Das Sensor-WLAN ist nur fuer die Einrichtung der WLAN-Daten.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : widget.controller.openWifiSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Android-WLAN oeffnen'),
              ),
              const SizedBox(height: 16),
              Text('Sensor-WLAN einrichten', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _portalController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Sensor-Adresse',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _ssidController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Home-/Handy-WLAN-Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passwordController,
                enabled: !busy,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Home-/Handy-WLAN-Passwort',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    onPressed: busy
                        ? null
                        : () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: busy ? null : _sendWifiCredentials,
                  icon: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_password_outlined),
                  label: const Text('An Sensor senden'),
                ),
              ),
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 16),
              Text('Sensor im Home-/Handy-WLAN verbinden',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _hostController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Radar-IP oder auto',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: busy ? null : _connectHomeWifi,
                  icon: _connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('Sensor suchen'),
                ),
              ),
              if (_localStatus != null) ...[
                const SizedBox(height: 12),
                Text(
                  _localStatus!,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendWifiCredentials() async {
    final portalHost = _portalController.text;
    final ssid = _ssidController.text;
    final password = _passwordController.text;

    setState(() {
      _submitting = true;
      _localStatus = 'Sende Home-/Handy-WLAN-Daten an den Sensor ...';
    });

    final ok = await widget.controller.provisionRadarWifi(
      portalHost: portalHost,
      ssid: ssid,
      password: password,
    );
    if (!mounted) return;

    setState(() {
      _submitting = false;
      _hostController.text = radarDefaultHost;
      _localStatus = ok
          ? 'Gespeichert. Jetzt Handy wieder mit demselben 2,4-GHz WLAN verbinden und danach "Sensor suchen" tippen.'
          : widget.controller.snapshot.status;
    });
  }

  Future<void> _connectHomeWifi() async {
    final host = _hostController.text.trim().isEmpty
        ? radarDefaultHost
        : _hostController.text.trim();

    setState(() {
      _connecting = true;
      _localStatus = 'Suche Sensor im Home-/Handy-WLAN ...';
    });

    final ok = await widget.controller.connectRadar(hostOverride: host);
    if (!mounted) return;

    setState(() {
      _connecting = false;
      _localStatus = widget.controller.snapshot.status;
    });
    if (ok && mounted) Navigator.of(context).pop();
  }
}

class _RadarMetricPill extends StatelessWidget {
  const _RadarMetricPill({required this.metric});

  final RadarMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 118, maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.70),
        ),
        color: theme.colorScheme.surface.withValues(alpha: 0.65),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            metric.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  metric.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (metric.unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(metric.unit, style: theme.textTheme.bodySmall),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CsvFilePanel extends StatelessWidget {
  const _CsvFilePanel({
    required this.controller,
    required this.snapshot,
  });

  final MeasurementController controller;
  final MeasurementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = snapshot.csvPath;
    final directory = snapshot.csvDirectoryPath;
    final hasFile = path != null;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('CSV-Datei', style: theme.textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () => controller.refreshCsvInfo(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Aktualisieren'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              hasFile
                  ? path
                  : directory == null
                      ? 'Noch keine CSV-Datei vorhanden.'
                      : 'Speicherordner: $directory',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: hasFile
                      ? () => _showCsvPreview(context, controller)
                      : null,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Vorschau'),
                ),
                OutlinedButton.icon(
                  onPressed: hasFile ? () => controller.openCurrentCsv() : null,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Oeffnen'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      hasFile ? () => controller.shareCurrentCsv() : null,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Teilen'),
                ),
                OutlinedButton.icon(
                  onPressed: hasFile || directory != null
                      ? () => Clipboard.setData(
                            ClipboardData(text: path ?? directory!),
                          )
                      : null,
                  icon: const Icon(Icons.copy),
                  label: const Text('Pfad kopieren'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCsvPreview(
    BuildContext context,
    MeasurementController controller,
  ) async {
    final preview = await controller.readCurrentCsvPreview();
    if (!context.mounted || preview == null) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'CSV-Vorschau',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.70,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        preview.isEmpty
                            ? 'Die CSV-Datei ist noch leer.'
                            : preview,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    required this.width,
    required this.label,
    required this.value,
    required this.unit,
    this.showScore = false,
    this.score,
    super.key,
  });

  final double width;
  final String label;
  final String value;
  final String unit;
  final bool showScore;
  final double? score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget valueRow(TextStyle? valueStyle) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (unit.isNotEmpty) ...[
            const SizedBox(width: 5),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(unit, style: theme.textTheme.bodySmall),
            ),
          ],
        ],
      );
    }

    return SizedBox(
      width: width,
      height: showScore ? 104 : null,
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 12, showScore ? 8 : 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: showScore ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: showScore
                          ? theme.textTheme.labelSmall?.copyWith(fontSize: 12)
                          : theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    valueRow(
                      showScore
                          ? theme.textTheme.titleMedium?.copyWith(fontSize: 18)
                          : theme.textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
              if (showScore) ...[
                const SizedBox(width: 6),
                _SleepScoreGauge(
                  score: score,
                  size: width < 175 ? 43 : 53,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SleepOverallScore extends StatelessWidget {
  const _SleepOverallScore({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _SleepScoreGauge(score: score, size: 82),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Gesamtscore', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Herzfrequenz, Atemfrequenz, Schnarchen und Ohrtemperatur',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SleepScoreGauge extends StatelessWidget {
  const _SleepScoreGauge({required this.score, required this.size});

  final double? score;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = score?.clamp(1.0, 100.0).toDouble();
    final theme = Theme.of(context);
    final isOverallScore = size >= 70;
    final numberFontSize = isOverallScore ? 24.0 : 15.0;
    final labelFontSize = isOverallScore ? 12.0 : 8.0;
    return Tooltip(
      message: value == null ? 'Kein verlaesslicher Score' : 'Score 1 bis 100',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _SleepScoreGaugePainter(
            score: value,
            trackColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          child: Center(
            child: Transform.translate(
              offset: Offset(0, isOverallScore ? -1 : -2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value == null ? '--' : value.round().toString(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: numberFontSize,
                      height: 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'Score',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: labelFontSize,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SleepScoreGaugePainter extends CustomPainter {
  const _SleepScoreGaugePainter({
    required this.score,
    required this.trackColor,
  });

  final double? score;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const startAngle = -math.pi / 2;
    const totalSweep = math.pi * 2;
    final strokeWidth = math.max(5.0, size.shortestSide * 0.09);
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, totalSweep, false, trackPaint);

    final value = score;
    if (value == null) return;
    final scoreColor = _sleepScoreColor(value);
    final progressPaint = Paint()
      ..color = scoreColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = value >= 99.95 ? StrokeCap.butt : StrokeCap.round;
    canvas.drawArc(
      rect,
      startAngle,
      totalSweep * (value / 100),
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SleepScoreGaugePainter oldDelegate) {
    return oldDelegate.score != score || oldDelegate.trackColor != trackColor;
  }
}

Color _sleepScoreColor(double score) {
  final value = score.clamp(1.0, 100.0).toDouble();
  if (value <= 55) {
    return Color.lerp(
          const Color(0xFFE5484D),
          const Color(0xFFF3B61F),
          value / 55,
        ) ??
        const Color(0xFFE5484D);
  }
  return Color.lerp(
        const Color(0xFFF3B61F),
        const Color(0xFF2E7D32),
        (value - 55) / 45,
      ) ??
      const Color(0xFF2E7D32);
}

class ChartPanel extends StatelessWidget {
  const ChartPanel({
    required this.title,
    required this.series,
    this.fixedMinY,
    this.fixedMaxY,
    this.stableScale = false,
    this.symmetricY = false,
    this.minYSpan,
    this.yStep,
    this.xWindowSeconds,
    super.key,
  });

  final String title;
  final List<ChartSeries> series;
  final double? fixedMinY;
  final double? fixedMaxY;
  final bool stableScale;
  final bool symmetricY;
  final double? minYSpan;
  final double? yStep;
  final double? xWindowSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SizedBox(
              height: 170,
              child: SignalChart(
                series: series,
                fixedMinY: fixedMinY,
                fixedMaxY: fixedMaxY,
                stableScale: stableScale,
                symmetricY: symmetricY,
                minYSpan: minYSpan,
                yStep: yStep,
                xWindowSeconds: xWindowSeconds,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChartSeries {
  const ChartSeries({
    required this.points,
    required this.color,
    this.dotsOnly = false,
  });

  final List<PlotPoint> points;
  final Color color;
  final bool dotsOnly;
}

class SignalChart extends StatefulWidget {
  const SignalChart({
    required this.series,
    this.fixedMinY,
    this.fixedMaxY,
    this.stableScale = false,
    this.symmetricY = false,
    this.minYSpan,
    this.yStep,
    this.xWindowSeconds,
    super.key,
  });

  final List<ChartSeries> series;
  final double? fixedMinY;
  final double? fixedMaxY;
  final bool stableScale;
  final bool symmetricY;
  final double? minYSpan;
  final double? yStep;
  final double? xWindowSeconds;

  @override
  State<SignalChart> createState() => _SignalChartState();
}

class _SignalChartState extends State<SignalChart> {
  double? _stableMinY;
  double? _stableMaxY;
  double? _previousMaxX;

  @override
  Widget build(BuildContext context) {
    final allPoints = widget.series.expand((entry) => entry.points).toList();
    if (allPoints.length < 2) {
      _resetStableScale();
      return const Center(child: Text('Warte auf Daten ...'));
    }

    final maxX = allPoints.map((p) => p.x).reduce(math.max);
    if (_previousMaxX != null && maxX + 0.001 < _previousMaxX!) {
      _resetStableScale();
    }
    _previousMaxX = maxX;

    final minX = math.max(0.0, maxX - (widget.xWindowSeconds ?? plotSeconds));
    final visibleScalePoints = _scalePoints(minX);
    final minDataY = visibleScalePoints.map((p) => p.y).reduce(math.min);
    final maxDataY = visibleScalePoints.map((p) => p.y).reduce(math.max);
    final bounds = _resolveBounds(minDataY, maxDataY);

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX + 0.1,
        minY: bounds.min,
        maxY: bounds.max,
        lineTouchData: const LineTouchData(enabled: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.22),
            strokeWidth: 1,
          ),
        ),
        titlesData: const FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        clipData: const FlClipData.all(),
        lineBarsData: widget.series.map((entry) {
          final spots = entry.points
              .where((p) => p.x >= minX)
              .map((p) => FlSpot(p.x, p.y))
              .toList(growable: false);
          return LineChartBarData(
            spots: spots,
            isCurved: !entry.dotsOnly,
            barWidth: entry.dotsOnly ? 0 : 1.6,
            color:
                entry.dotsOnly ? entry.color.withValues(alpha: 0) : entry.color,
            dotData: FlDotData(
              show: entry.dotsOnly,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 3.8,
                color: entry.color,
                strokeWidth: 1.4,
                strokeColor: Theme.of(context).colorScheme.surface,
              ),
            ),
            belowBarData: BarAreaData(show: false),
          );
        }).toList(growable: false),
      ),
      duration: Duration.zero,
    );
  }

  List<PlotPoint> _scalePoints(double minX) {
    final signalPoints = widget.series
        .where((entry) => !entry.dotsOnly)
        .expand((entry) => entry.points)
        .where((p) => p.x >= minX)
        .toList(growable: false);
    if (signalPoints.isNotEmpty) return signalPoints;

    return widget.series
        .expand((entry) => entry.points)
        .where((p) => p.x >= minX)
        .toList(growable: false);
  }

  _AxisBounds _resolveBounds(double minDataY, double maxDataY) {
    final fixedMinY = widget.fixedMinY;
    final fixedMaxY = widget.fixedMaxY;
    if (fixedMinY != null && fixedMaxY != null) {
      return _AxisBounds(fixedMinY, fixedMaxY);
    }

    final target = _targetBounds(minDataY, maxDataY);
    if (!widget.stableScale) return target;

    final currentMin = _stableMinY;
    final currentMax = _stableMaxY;
    if (currentMin == null || currentMax == null) {
      _stableMinY = target.min;
      _stableMaxY = target.max;
      return target;
    }

    if (widget.symmetricY) {
      final currentExtent = math.max(currentMin.abs(), currentMax.abs());
      final targetExtent = math.max(target.min.abs(), target.max.abs());
      final nextExtent = targetExtent > currentExtent
          ? targetExtent
          : math.max(targetExtent, currentExtent * 0.985);
      _stableMinY = -nextExtent;
      _stableMaxY = nextExtent;
      return _AxisBounds(_stableMinY!, _stableMaxY!);
    }

    final nextMin = target.min < currentMin
        ? target.min
        : _lerp(currentMin, target.min, 0.015);
    final nextMax = target.max > currentMax
        ? target.max
        : _lerp(currentMax, target.max, 0.015);
    _stableMinY = nextMin;
    _stableMaxY = nextMax;
    return _AxisBounds(nextMin, nextMax);
  }

  _AxisBounds _targetBounds(double minDataY, double maxDataY) {
    final minYSpan = widget.minYSpan ?? 1.0;
    final yStep = widget.yStep;

    if (widget.symmetricY) {
      final rawExtent = math.max(minDataY.abs(), maxDataY.abs()) * 1.18;
      final extent = math.max(minYSpan / 2, _ceilToStep(rawExtent, yStep));
      return _AxisBounds(-extent, extent);
    }

    final span = math.max(minYSpan, maxDataY - minDataY);
    final paddedSpan = span * 1.24;
    final center = (minDataY + maxDataY) / 2;
    final min = center - paddedSpan / 2;
    final max = center + paddedSpan / 2;
    if (yStep == null || yStep <= 0) return _AxisBounds(min, max);
    return _AxisBounds(
      (min / yStep).floorToDouble() * yStep,
      (max / yStep).ceilToDouble() * yStep,
    );
  }

  void _resetStableScale() {
    _stableMinY = null;
    _stableMaxY = null;
    _previousMaxX = null;
  }

  double _ceilToStep(double value, double? step) {
    if (step == null || step <= 0) return value;
    return (value / step).ceilToDouble() * step;
  }

  double _lerp(double from, double to, double amount) {
    return from + (to - from) * amount;
  }
}

class _AxisBounds {
  const _AxisBounds(this.min, this.max);

  final double min;
  final double max;
}
