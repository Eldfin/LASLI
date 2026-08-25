import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

const radarDefaultHost = 'auto';
const radarDirectHost = '192.168.4.1';
const radarSensorSsidHint = 'seeedstudio-mr60bha2';
const radarApiPort = 6053;
const _clientInfo = 'LASLI Android';
const _apiVersionMajor = 1;
const _apiVersionMinor = 14;

const _helloRequest = 1;
const _helloResponse = 2;
const _authenticationRequest = 3;
const _authenticationResponse = 4;
const _disconnectRequest = 5;
const _disconnectResponse = 6;
const _pingRequest = 7;
const _pingResponse = 8;
const _deviceInfoRequest = 9;
const _deviceInfoResponse = 10;
const _listEntitiesRequest = 11;
const _listEntitiesBinarySensorResponse = 12;
const _listEntitiesSensorResponse = 16;
const _listEntitiesTextSensorResponse = 18;
const _listEntitiesDoneResponse = 19;
const _subscribeStatesRequest = 20;
const _binarySensorStateResponse = 21;
const _sensorStateResponse = 25;
const _textSensorStateResponse = 27;

enum _RadarEntityType {
  binarySensor,
  sensor,
  textSensor,
}

enum _RadarEntityKind {
  heartRate,
  breathingRate,
  distance,
  targetCount,
  personDetected,
  illuminance,
  other,
}

class RadarSensorClient {
  RadarSensorClient({
    required this.host,
    this.port = radarApiPort,
    this.onState,
    this.onStatus,
  });

  final String host;
  final int port;
  final void Function(RadarState state)? onState;
  final void Function(String status)? onStatus;

  final Map<int, _RadarEntity> _entities = {};
  final Map<int, _RadarValue> _values = {};

  Socket? _socket;
  _SocketByteReader? _reader;
  RadarState _state = const RadarState.empty();
  bool _stopping = false;

  RadarState get state => _state;
  bool get connected => _socket != null && _state.connected;

  Future<void> start() async {
    _stopping = false;
    _emitStatus('Suche Radar ...');

    final resolvedHost = await _resolveHost();
    _emitStatus('Verbinde mit Radar unter $resolvedHost ...');

    final socket = await Socket.connect(
      resolvedHost,
      port,
      timeout: const Duration(seconds: 5),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _reader = _SocketByteReader(socket);

    await _sendFrames([
      _OutgoingFrame(_helloRequest, _helloPayload()),
      const _OutgoingFrame(_authenticationRequest, []),
    ]);
    final hello = await _readExpectedPhase(
      _helloResponse,
      'ESPHome-Hello',
    );
    final helloFields = _ProtoFields.parse(hello.payload);
    final serverInfo = helloFields.stringValue(3);
    final helloName = helloFields.stringValue(4);
    _emitStatus('ESPHome antwortet: ${serverInfo ?? helloName ?? 'Radar'}');

    await _sendFrame(_deviceInfoRequest, const []);
    final deviceInfo = await _readExpectedPhase(
      _deviceInfoResponse,
      'Geraeteinformationen',
    );
    final deviceFields = _ProtoFields.parse(deviceInfo.payload);
    final friendlyName = deviceFields.stringValue(13);
    final deviceName = friendlyName?.isNotEmpty == true
        ? friendlyName!
        : deviceFields.stringValue(2) ?? helloName ?? serverInfo ?? 'MR60BHA2';

    await _sendFrame(_listEntitiesRequest, const []);
    await _readEntities(serverInfo: serverInfo);

    if (!_hasAnyUsefulEntity) {
      throw StateError(
        'Verbunden, aber keine MR60BHA2-Herz/Atem-Entities gefunden.',
      );
    }

    _state = _state.copyWith(
      connected: true,
      connecting: false,
      host: resolvedHost,
      deviceName: deviceName,
      status: 'Radar verbunden: $deviceName ($resolvedHost)',
      metrics: _buildMetrics(),
    );
    _emitState();

    await _sendFrame(_subscribeStatesRequest, const []);
    unawaited(_readLoop());
  }

  Future<void> stop() async {
    _stopping = true;
    try {
      await _sendFrame(_disconnectRequest, const []);
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    try {
      await _reader?.cancel();
    } catch (_) {}
    _socket = null;
    _reader = null;
    _state = _state.copyWith(
      connected: false,
      connecting: false,
      status: 'Radar getrennt',
    );
    _emitState();
  }

  static Future<String?> findSensorHost({
    int port = radarApiPort,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Pruefe Sensor-Hotspot $radarDirectHost ...');
    if (await _looksLikeEspHome(
      radarDirectHost,
      port,
      acceptAnyEspHome: true,
      connectTimeout: const Duration(seconds: 2),
      readTimeout: const Duration(seconds: 2),
    )) {
      return radarDirectHost;
    }
    final subnets = await _privateIpv4Subnets();
    if (subnets.isEmpty) return null;

    for (final subnet in subnets) {
      onStatus?.call('Suche Radar im Netz $subnet.0/24 ...');
      final hosts = List.generate(254, (index) => '$subnet.${index + 1}');
      for (var start = 0; start < hosts.length; start += 32) {
        final batch = hosts.skip(start).take(32).toList(growable: false);
        final checks = await Future.wait(
          batch.map(
            (host) => _looksLikeEspHome(
              host,
              port,
              connectTimeout: const Duration(milliseconds: 500),
              readTimeout: const Duration(milliseconds: 900),
            ),
          ),
        );
        for (var i = 0; i < batch.length; i++) {
          if (checks[i]) return batch[i];
        }
      }
    }
    return null;
  }

  Future<String> _resolveHost() async {
    final trimmed = host.trim();
    if (trimmed.isNotEmpty && trimmed.toLowerCase() != radarDefaultHost) {
      return trimmed;
    }

    final found = await findSensorHost(port: port, onStatus: _emitStatus);
    if (found == null) {
      throw StateError(
        'Kein ESPHome-Radar gefunden. Messdaten laufen ueber ein gemeinsames 2,4-GHz Home-/Handy-WLAN. Das Sensor-WLAN $radarSensorSsidHint ist nur fuer die Einrichtung; 5 GHz sieht der Sensor nicht.',
      );
    }
    return found;
  }

  Future<void> _readEntities({required String? serverInfo}) async {
    while (true) {
      final frame = await _readFramePhase(
        'Entity-Liste${serverInfo == null ? '' : ' von $serverInfo'}',
      );
      switch (frame.type) {
        case _listEntitiesDoneResponse:
          return;
        case _listEntitiesBinarySensorResponse:
          _registerEntity(frame.payload, _RadarEntityType.binarySensor);
        case _listEntitiesSensorResponse:
          _registerEntity(frame.payload, _RadarEntityType.sensor);
        case _listEntitiesTextSensorResponse:
          _registerEntity(frame.payload, _RadarEntityType.textSensor);
        case _pingRequest:
          await _sendFrame(_pingResponse, const []);
        case _disconnectRequest:
          await _sendFrame(_disconnectResponse, const []);
          throw StateError('Radar hat die Verbindung beendet.');
      }
    }
  }

  void _registerEntity(List<int> payload, _RadarEntityType type) {
    final fields = _ProtoFields.parse(payload);
    final key = fields.fixed32Value(2);
    if (key == null) return;

    final name = fields.stringValue(3) ?? fields.stringValue(1) ?? 'Radar $key';
    final objectId = fields.stringValue(1) ?? '';
    final unit = type == _RadarEntityType.sensor
        ? fields.stringValue(6) ?? _fallbackUnit(name)
        : '';
    final decimals = type == _RadarEntityType.sensor
        ? fields.varintValue(7) ?? _fallbackDecimals(name)
        : 0;

    _entities[key] = _RadarEntity(
      key: key,
      kind: _kindFor(name, objectId),
      name: name,
      objectId: objectId,
      unit: unit,
      accuracyDecimals: decimals,
    );
  }

  Future<void> _readLoop() async {
    try {
      while (!_stopping) {
        final frame = await _readFrame();
        switch (frame.type) {
          case _sensorStateResponse:
            _handleSensorState(frame.payload);
          case _binarySensorStateResponse:
            _handleBinarySensorState(frame.payload);
          case _textSensorStateResponse:
            _handleTextSensorState(frame.payload);
          case _pingRequest:
            await _sendFrame(_pingResponse, const []);
          case _disconnectRequest:
            await _sendFrame(_disconnectResponse, const []);
            throw StateError('Radar hat die Verbindung beendet.');
        }
      }
    } catch (error) {
      if (_stopping) return;
      _socket = null;
      _reader = null;
      _state = _state.copyWith(
        connected: false,
        connecting: false,
        status: 'Radar-Verbindung verloren: ${_friendlyError(error)}',
      );
      _emitState();
    }
  }

  void _handleSensorState(List<int> payload) {
    final fields = _ProtoFields.parse(payload);
    final key = fields.fixed32Value(1);
    final entity = key == null ? null : _entities[key];
    if (entity == null) return;

    final missing = fields.boolValue(3) ?? false;
    final value = missing ? null : fields.floatValue(2);
    _values[key!] = _RadarValue(value);
    _applyKnownValue(entity, value);
  }

  void _handleBinarySensorState(List<int> payload) {
    final fields = _ProtoFields.parse(payload);
    final key = fields.fixed32Value(1);
    final entity = key == null ? null : _entities[key];
    if (entity == null) return;

    final missing = fields.boolValue(3) ?? false;
    final value = missing ? null : fields.boolValue(2);
    _values[key!] = _RadarValue(value);
    _applyKnownValue(entity, value);
  }

  void _handleTextSensorState(List<int> payload) {
    final fields = _ProtoFields.parse(payload);
    final key = fields.fixed32Value(1);
    final entity = key == null ? null : _entities[key];
    if (entity == null) return;

    final missing = fields.boolValue(3) ?? false;
    final value = missing ? null : fields.stringValue(2);
    _values[key!] = _RadarValue(value);
    _applyKnownValue(entity, value);
  }

  void _applyKnownValue(_RadarEntity entity, Object? rawValue) {
    final number = rawValue is num ? rawValue.toDouble() : null;
    var next = _state.copyWith(
      connected: true,
      connecting: false,
      lastUpdate: DateTime.now(),
      metrics: _buildMetrics(),
    );

    switch (entity.kind) {
      case _RadarEntityKind.heartRate:
        next = next.copyWith(
          heartRateBpm: _positive(number),
          clearHeartRateBpm: _positive(number) == null,
        );
      case _RadarEntityKind.breathingRate:
        next = next.copyWith(
          breathingRatePerMin: _positive(number),
          clearBreathingRatePerMin: _positive(number) == null,
        );
      case _RadarEntityKind.distance:
        next = next.copyWith(
          distanceCm: _positive(number),
          clearDistanceCm: _positive(number) == null,
        );
      case _RadarEntityKind.targetCount:
        next = next.copyWith(
          targetCount: number?.isFinite == true ? number : null,
          clearTargetCount: number?.isFinite != true,
        );
      case _RadarEntityKind.personDetected:
        final person = rawValue is bool ? rawValue : _personFromText(rawValue);
        next = next.copyWith(
          personDetected: person,
          clearPersonDetected: person == null,
        );
      case _RadarEntityKind.illuminance:
        next = next.copyWith(
          illuminanceLux: number?.isFinite == true ? number : null,
          clearIlluminanceLux: number?.isFinite != true,
        );
      case _RadarEntityKind.other:
        break;
    }

    _state = next.copyWith(metrics: _buildMetrics());
    _emitState();
  }

  bool get _hasAnyUsefulEntity {
    return _entities.values.any((entity) =>
        entity.kind == _RadarEntityKind.heartRate ||
        entity.kind == _RadarEntityKind.breathingRate ||
        entity.kind == _RadarEntityKind.distance ||
        entity.kind == _RadarEntityKind.targetCount ||
        entity.kind == _RadarEntityKind.personDetected);
  }

  List<RadarMetric> _buildMetrics() {
    final metrics = <RadarMetric>[];
    for (final entity in _entities.values) {
      final value = _values[entity.key];
      metrics.add(
        RadarMetric(
          label: _displayName(entity),
          value: _formatValue(entity, value?.value),
          unit: entity.unit,
        ),
      );
    }
    metrics.sort((a, b) {
      final priority =
          _metricPriority(a.label).compareTo(_metricPriority(b.label));
      if (priority != 0) return priority;
      return a.label.compareTo(b.label);
    });
    return metrics;
  }

  int _metricPriority(String label) {
    final text = label.toLowerCase();
    if (text.contains('herz') || text.contains('heart')) return 0;
    if (text.contains('atm') ||
        text.contains('breath') ||
        text.contains('resp')) {
      return 1;
    }
    if (text.contains('person') || text.contains('human')) return 2;
    if (text.contains('ziel') || text.contains('target')) return 3;
    if (text.contains('distanz') || text.contains('distance')) return 4;
    return 5;
  }

  String _displayName(_RadarEntity entity) {
    switch (entity.kind) {
      case _RadarEntityKind.heartRate:
        return 'Radar-Herz';
      case _RadarEntityKind.breathingRate:
        return 'Radar-Atmung';
      case _RadarEntityKind.distance:
        return 'Distanz';
      case _RadarEntityKind.targetCount:
        return 'Ziele';
      case _RadarEntityKind.personDetected:
        return 'Person';
      case _RadarEntityKind.illuminance:
        return 'Licht';
      case _RadarEntityKind.other:
        return entity.name;
    }
  }

  String _formatValue(_RadarEntity entity, Object? value) {
    if (value == null) return '--';
    if (value is bool) return value ? 'ja' : 'nein';
    if (value is String) return value.isEmpty ? '--' : value;
    if (value is num) {
      final number = value.toDouble();
      if (!number.isFinite) return '--';
      final decimals = entity.kind == _RadarEntityKind.targetCount
          ? 0
          : math.max(0, math.min(2, entity.accuracyDecimals));
      return number.toStringAsFixed(decimals);
    }
    return value.toString();
  }

  Future<_Frame> _readExpectedPhase(int expectedType, String phase) async {
    while (true) {
      final frame = await _readFramePhase(phase).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError('$phase: Zeitueberschreitung.'),
      );
      if (frame.type == expectedType) return frame;
      if (frame.type == _pingRequest) {
        await _sendFrame(_pingResponse, const []);
      } else if (frame.type == _authenticationResponse) {
        _handleAuthenticationResponse(frame.payload);
      } else if (frame.type == _disconnectRequest) {
        await _sendFrame(_disconnectResponse, const []);
        throw StateError('Radar hat die Verbindung beendet.');
      }
    }
  }

  Future<_Frame> _readFrame() => _readFramePhase('Radar-API');

  Future<_Frame> _readFramePhase(String phase) async {
    final reader = _reader;
    if (reader == null) throw StateError('Radar-Socket ist nicht verbunden.');

    late final int preamble;
    try {
      preamble = await reader.readByte();
    } catch (error) {
      final text = error.toString();
      if (text.contains('Radar-Socket wurde geschlossen')) {
        throw StateError(
          '$phase: Sensor hat die Verbindung geschlossen. Wahrscheinlich passen ESPHome-API-Modus, Passwort oder Encryption-Key nicht zur App.',
        );
      }
      rethrow;
    }
    if (preamble == 0x01) {
      throw StateError(
        'Dieser ESPHome-Sensor verlangt API-Verschluesselung. Bitte Encryption-Key entfernen oder App erweitern.',
      );
    }
    if (preamble != 0x00) {
      throw StateError(
          'Ungueltiger ESPHome-Frame: 0x${preamble.toRadixString(16)}');
    }

    final length = await reader.readVarint();
    final type = await reader.readVarint();
    final payload = length == 0 ? Uint8List(0) : await reader.readBytes(length);
    return _Frame(type, payload);
  }

  Future<void> _sendFrame(int type, List<int> payload) async {
    await _sendFrames([_OutgoingFrame(type, payload)]);
  }

  Future<void> _sendFrames(List<_OutgoingFrame> frames) async {
    final socket = _socket;
    if (socket == null) return;

    final bytes = <int>[];
    for (final frame in frames) {
      bytes.addAll([
        0x00,
        ..._encodeVarint(frame.payload.length),
        ..._encodeVarint(frame.type),
        ...frame.payload,
      ]);
    }
    socket.add(bytes);
    await socket.flush();
  }

  List<int> _helloPayload() {
    return [
      ..._encodeStringField(1, _clientInfo),
      ..._encodeVarintField(2, _apiVersionMajor),
      ..._encodeVarintField(3, _apiVersionMinor),
    ];
  }

  void _emitStatus(String status) {
    onStatus?.call(status);
    _state = _state.copyWith(
      connecting: true,
      connected: false,
      status: status,
    );
    _emitState();
  }

  void _handleAuthenticationResponse(List<int> payload) {
    final fields = _ProtoFields.parse(payload);
    if (fields.boolValue(1) ?? false) {
      throw StateError(
        'Diese ESPHome-Firmware verlangt ein API-Passwort. Bitte API-Passwort in der Firmware entfernen oder die App um Passwort-Eingabe erweitern.',
      );
    }
  }

  void _emitState() => onState?.call(_state);

  String _friendlyError(Object error) {
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '')
        .replaceFirst('SocketException: ', '');
  }

  static Future<bool> _looksLikeEspHome(
    String host,
    int port, {
    bool acceptAnyEspHome = false,
    Duration connectTimeout = const Duration(milliseconds: 280),
    Duration readTimeout = const Duration(milliseconds: 650),
  }) async {
    Socket? socket;
    _SocketByteReader? reader;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: connectTimeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketByteReader(socket);
      final helloPayload = [
        ..._encodeStringField(1, _clientInfo),
        ..._encodeVarintField(2, _apiVersionMajor),
        ..._encodeVarintField(3, _apiVersionMinor),
      ];
      socket.add([
        0x00,
        ..._encodeVarint(helloPayload.length),
        ..._encodeVarint(_helloRequest),
        ...helloPayload,
        0x00,
        ..._encodeVarint(0),
        ..._encodeVarint(_authenticationRequest),
      ]);
      await socket.flush();

      final preamble = await reader.readByte().timeout(readTimeout);
      if (preamble != 0x00) return false;
      final length = await reader.readVarint();
      final type = await reader.readVarint();
      if (length > 0) {
        await reader.readBytes(length);
      }
      if (type != _helloResponse) return false;

      socket.add([
        0x00,
        ..._encodeVarint(0),
        ..._encodeVarint(_deviceInfoRequest),
      ]);
      await socket.flush();

      Uint8List? payload;
      for (var attempt = 0; attempt < 4; attempt++) {
        final infoPreamble = await reader.readByte().timeout(readTimeout);
        if (infoPreamble != 0x00) return false;
        final infoLength = await reader.readVarint();
        final infoType = await reader.readVarint();
        final infoPayload =
            infoLength == 0 ? Uint8List(0) : await reader.readBytes(infoLength);
        if (infoType == _deviceInfoResponse) {
          payload = infoPayload;
          break;
        }
        if (infoType != _authenticationResponse && infoType != _pingRequest) {
          return false;
        }
      }
      if (payload == null) return false;
      final fields = _ProtoFields.parse(payload);
      final name = [
        fields.stringValue(2),
        fields.stringValue(13),
        fields.stringValue(8),
        fields.stringValue(9),
      ].whereType<String>().join(' ').toLowerCase();
      if (acceptAnyEspHome && name.isNotEmpty) return true;
      return name.contains('mr60') ||
          name.contains('radar') ||
          name.contains('seeed');
    } catch (_) {
      return false;
    } finally {
      try {
        await reader?.cancel();
      } catch (_) {}
      try {
        await socket?.close();
      } catch (_) {}
    }
  }
}

class _RadarEntity {
  const _RadarEntity({
    required this.key,
    required this.kind,
    required this.name,
    required this.objectId,
    required this.unit,
    required this.accuracyDecimals,
  });

  final int key;
  final _RadarEntityKind kind;
  final String name;
  final String objectId;
  final String unit;
  final int accuracyDecimals;
}

class _RadarValue {
  const _RadarValue(this.value);

  final Object? value;
}

class _Frame {
  const _Frame(this.type, this.payload);

  final int type;
  final Uint8List payload;
}

class _OutgoingFrame {
  const _OutgoingFrame(this.type, this.payload);

  final int type;
  final List<int> payload;
}

class _SocketByteReader {
  _SocketByteReader(Socket socket) {
    _subscription = socket.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onError: (Object error) {
        _error = error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  final Queue<int> _buffer = Queue<int>();
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  Future<int> readByte() async {
    while (_buffer.isEmpty) {
      if (_error != null) throw StateError(_error.toString());
      if (_done) throw StateError('Radar-Socket wurde geschlossen.');
      _waiter ??= Completer<void>();
      await _waiter!.future;
    }
    return _buffer.removeFirst();
  }

  Future<int> readVarint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = await readByte();
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw StateError('Varint ist zu lang.');
    }
  }

  Future<Uint8List> readBytes(int count) async {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = await readByte();
    }
    return bytes;
  }

  Future<void> cancel() => _subscription.cancel();

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _waiter = null;
  }
}

class _ProtoFields {
  _ProtoFields(this._values);

  final Map<int, List<_ProtoValue>> _values;

  static _ProtoFields parse(List<int> bytes) {
    final values = <int, List<_ProtoValue>>{};
    var index = 0;
    while (index < bytes.length) {
      final tagRead = _readVarintAt(bytes, index);
      final tag = tagRead.value;
      index = tagRead.nextIndex;
      final field = tag >> 3;
      final wireType = tag & 0x07;

      _ProtoValue value;
      switch (wireType) {
        case 0:
          final read = _readVarintAt(bytes, index);
          value = _ProtoValue(varint: read.value);
          index = read.nextIndex;
        case 1:
          if (index + 8 > bytes.length) return _ProtoFields(values);
          value = _ProtoValue(
              bytes: Uint8List.fromList(bytes.sublist(index, index + 8)));
          index += 8;
        case 2:
          final lengthRead = _readVarintAt(bytes, index);
          final length = lengthRead.value;
          index = lengthRead.nextIndex;
          if (index + length > bytes.length) return _ProtoFields(values);
          value = _ProtoValue(
            bytes: Uint8List.fromList(bytes.sublist(index, index + length)),
          );
          index += length;
        case 5:
          if (index + 4 > bytes.length) return _ProtoFields(values);
          final raw = Uint8List.fromList(bytes.sublist(index, index + 4));
          value = _ProtoValue(bytes: raw);
          index += 4;
        default:
          return _ProtoFields(values);
      }
      values.putIfAbsent(field, () => []).add(value);
    }
    return _ProtoFields(values);
  }

  int? varintValue(int field) => _last(_values[field])?.varint;

  bool? boolValue(int field) {
    final value = varintValue(field);
    return value == null ? null : value != 0;
  }

  int? fixed32Value(int field) {
    final bytes = _last(_values[field])?.bytes;
    if (bytes == null || bytes.length < 4) return null;
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  double? floatValue(int field) {
    final bytes = _last(_values[field])?.bytes;
    if (bytes == null || bytes.length < 4) return null;
    return ByteData.sublistView(bytes).getFloat32(0, Endian.little);
  }

  String? stringValue(int field) {
    final bytes = _last(_values[field])?.bytes;
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class _ProtoValue {
  const _ProtoValue({this.varint, this.bytes});

  final int? varint;
  final Uint8List? bytes;
}

T? _last<T>(List<T>? values) {
  if (values == null || values.isEmpty) return null;
  return values.last;
}

class _VarintRead {
  const _VarintRead(this.value, this.nextIndex);

  final int value;
  final int nextIndex;
}

_VarintRead _readVarintAt(List<int> bytes, int start) {
  var result = 0;
  var shift = 0;
  var index = start;
  while (index < bytes.length) {
    final byte = bytes[index++];
    result |= (byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) return _VarintRead(result, index);
    shift += 7;
  }
  return _VarintRead(result, index);
}

List<int> _encodeStringField(int field, String value) {
  final bytes = utf8.encode(value);
  return [
    ..._encodeVarint((field << 3) | 2),
    ..._encodeVarint(bytes.length),
    ...bytes,
  ];
}

List<int> _encodeVarintField(int field, int value) {
  return [
    ..._encodeVarint(field << 3),
    ..._encodeVarint(value),
  ];
}

List<int> _encodeVarint(int value) {
  final bytes = <int>[];
  var remaining = value;
  while (true) {
    var byte = remaining & 0x7F;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    bytes.add(byte);
    if (remaining == 0) break;
  }
  return bytes;
}

_RadarEntityKind _kindFor(String name, String objectId) {
  final text = '$name $objectId'.toLowerCase();
  if ((text.contains('heart') || text.contains('herz')) &&
      (text.contains('rate') || text.contains('bpm'))) {
    return _RadarEntityKind.heartRate;
  }
  if (text.contains('respiratory') ||
      text.contains('breathing') ||
      text.contains('breath_rate') ||
      text.contains('breath rate') ||
      text.contains('atmung')) {
    return _RadarEntityKind.breathingRate;
  }
  if (text.contains('distance') || text.contains('distanz')) {
    return _RadarEntityKind.distance;
  }
  if ((text.contains('target') || text.contains('ziel')) &&
      (text.contains('number') ||
          text.contains('count') ||
          text.contains('num') ||
          text.contains('anzahl'))) {
    return _RadarEntityKind.targetCount;
  }
  if (text.contains('person') ||
      text.contains('human') ||
      text.contains('presence')) {
    return _RadarEntityKind.personDetected;
  }
  if (text.contains('illuminance') ||
      text.contains('lux') ||
      text.contains('licht')) {
    return _RadarEntityKind.illuminance;
  }
  return _RadarEntityKind.other;
}

String _fallbackUnit(String name) {
  final text = name.toLowerCase();
  if (text.contains('heart')) return 'bpm';
  if (text.contains('respiratory') || text.contains('breath')) return '/min';
  if (text.contains('distance')) return 'cm';
  if (text.contains('illuminance')) return 'lx';
  return '';
}

int _fallbackDecimals(String name) {
  final text = name.toLowerCase();
  if (text.contains('target')) return 0;
  if (text.contains('heart') ||
      text.contains('respiratory') ||
      text.contains('breath')) {
    return 1;
  }
  return 1;
}

double? _positive(double? value) {
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}

bool? _personFromText(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim().toLowerCase();
  if (text.isEmpty) return null;
  if (text == '0' ||
      text == 'false' ||
      text.contains('none') ||
      text.contains('no target') ||
      text.contains('nobody') ||
      text.contains('not detected')) {
    return false;
  }
  if (text == '1' ||
      text == 'true' ||
      text.contains('detected') ||
      text.contains('person') ||
      text.contains('human')) {
    return true;
  }
  return null;
}

Future<List<String>> _privateIpv4Subnets() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  final subnets = <String>{};
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final parts = address.address.split('.');
      if (parts.length != 4) continue;
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      if (a == null || b == null) continue;
      final privateAddress =
          a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
      if (!privateAddress) continue;
      subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
  }
  return subnets.toList(growable: false)..sort();
}

Future<bool> isOnRadarDirectSubnet() async {
  final subnets = await _privateIpv4Subnets();
  return subnets.contains('192.168.4');
}
