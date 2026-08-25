import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lasli_flutter/src/mg24_protocol.dart';
import 'package:lasli_flutter/src/models.dart';

void main() {
  test('parses CRC protected edge summary', () {
    final bytes = Uint8List(Mg24EdgeSummary.packetLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, mg24ProtocolMagic);
    data.setUint8(1, mg24ProtocolVersion);
    data.setUint8(2, mg24SummaryPacketType);
    data.setUint8(3, 1);
    data.setUint32(4, 42, Endian.little);
    data.setUint32(8, 12000, Endian.little);
    data.setUint16(
        12, 0x01 | 0x02 | 0x10 | 0x40 | 0x0400 | 0x0800, Endian.little);
    data.setUint16(18, 147, Endian.little);
    data.setInt16(22, 1250, Endian.little);
    data.setInt16(24, -325, Endian.little);
    data.setInt16(26, 9000, Endian.little);
    data.setInt16(28, 32767, Endian.little);
    data.setUint8(37, 82);
    data.setUint8(41, 57);
    data.setUint8(39, 91);
    data.setUint16(42, 17, Endian.little);
    data.setUint16(44, 120, Endian.little);
    data.setUint16(46, 480, Endian.little);
    data.setUint8(62, 138);
    data.setUint8(63, 47);
    data.setUint8(64, 61);
    data.setUint8(65, 72);
    data.setUint8(66, 54);
    data.setUint8(67, 0x01);
    _writeCrc(bytes);

    final summary = Mg24EdgeSummary.parse(bytes);

    expect(summary, isNotNull);
    expect(summary!.role, Mg24SensorRole.belly);
    expect(summary.sequence, 42);
    expect(summary.recording, isTrue);
    expect(summary.recordingArmed, isTrue);
    expect(summary.recordingStartFailed, isTrue);
    expect(summary.respirationRatePerMin, 14.7);
    expect(summary.rollDeg, 12.5);
    expect(summary.pitchDeg, -3.25);
    expect(summary.respirationQuality, 82);
    expect(summary.snoreVolumePercent, 57);
    expect(summary.sessionId, 17);
    expect(summary.archiveRecords, 120);
    expect(summary.archiveCapacity, 480);
    expect(summary.snoreEnvelopeLift, 1.38);
    expect(summary.snoreCrestFactor, 4.7);
    expect(summary.snoreModulationPercent, 61);
    expect(summary.snoreBlockScorePercent, 72);
    expect(summary.snoreContinuationScorePercent, 54);
    expect(summary.snoreAudioContactArtifact, isTrue);
    expect(summary.snoreMotionArtifact, isFalse);
  });

  test('keeps parsing the previous 64 byte edge summary', () {
    final bytes = Uint8List(Mg24EdgeSummary.liveWindowPacketLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, mg24ProtocolMagic);
    data.setUint8(1, mg24ProtocolVersion);
    data.setUint8(2, mg24SummaryPacketType);
    data.setUint8(3, 0);
    data.setUint8(61, 9);
    _writeCrc(bytes);

    final summary = Mg24EdgeSummary.parse(bytes);

    expect(summary, isNotNull);
    expect(summary!.snoreActiveWidthMs, 720);
    expect(summary.snoreEnvelopeLift, isNull);
  });

  test('decodes an ear-temperature summary when the temperature-valid bit is set',
      () {
    final bytes = Uint8List(Mg24EdgeSummary.packetLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, mg24ProtocolMagic);
    data.setUint8(1, mg24ProtocolVersion);
    data.setUint8(2, mg24SummaryPacketType);
    data.setUint8(3, 0);
    data.setUint16(12, 0x20, Endian.little);
    data.setInt16(20, 3650, Endian.little);
    _writeCrc(bytes);

    final summary = Mg24EdgeSummary.parse(bytes);

    expect(summary, isNotNull);
    expect(summary!.temperatureC, 36.5);
  });

  test('rejects a damaged summary', () {
    final bytes = Uint8List(Mg24EdgeSummary.packetLength);
    bytes[0] = mg24ProtocolMagic;
    bytes[1] = mg24ProtocolVersion;
    bytes[2] = mg24SummaryPacketType;
    _writeCrc(bytes);
    bytes[12] ^= 0x40;

    expect(Mg24EdgeSummary.parse(bytes), isNull);
  });

  test('parses signed 32-band log-mel feature slices', () {
    final bytes = Uint8List(Mg24MelFeaturePacket.packetLength);
    final data = ByteData.sublistView(bytes);
    data
      ..setUint8(0, mg24ProtocolMagic)
      ..setUint8(1, mg24ProtocolVersion)
      ..setUint8(2, mg24MelFeaturePacketType)
      ..setUint8(3, 0)
      ..setUint32(4, 17, Endian.little)
      ..setUint32(8, 1234, Endian.little)
      ..setUint16(12, 10000, Endian.little)
      ..setUint8(14, 5)
      ..setUint8(15, Mg24MelFeaturePacket.bandsPerSlice)
      ..setUint8(16, 73)
      ..setUint8(17, 0x07)
      ..setInt16(18, -35, Endian.little);
    for (var index = 0; index < 160; index++) {
      data.setInt8(20 + index, (index % 256) - 128);
    }
    _writeCrc(bytes);

    final packet = Mg24MelFeaturePacket.parse(bytes);

    expect(packet, isNotNull);
    expect(packet!.role, Mg24SensorRole.forehead);
    expect(packet.packetSequence, 17);
    expect(packet.firstFrameSequence, 1234);
    expect(packet.framePeriodUs, 10000);
    expect(packet.modelScorePercent, 73);
    expect(packet.modelAvailable, isTrue);
    expect(packet.modelActive, isTrue);
    expect(packet.boardDomainTrusted, isTrue);
    expect(packet.modelFrameSequence, 1199);
    expect(packet.slices, hasLength(5));
    expect(packet.slices.first.first, -128);
    expect(packet.slices.last.last, 31);
  });

  test('sample loss counts gaps but ignores packet arrival timing', () {
    final loss = Mg24SampleLossEstimator();
    expect(loss.add(firstSequence: 0, count: 5), 0);
    expect(loss.add(firstSequence: 5, count: 5), 0);
    expect(loss.add(firstSequence: 15, count: 5), closeTo(25, 0.001));
  });

  test('minute archive decodes snore volume from the forehead quality nibble',
      () {
    final bytes = Uint8List(Mg24MinuteRecord.wireLength);
    final data = ByteData.sublistView(bytes);
    data.setUint16(0, 7, Endian.little);
    data.setUint16(2, 19, Endian.little);
    data.setUint16(4, 0x20 | 0x80, Endian.little);
    data.setUint8(9, 12);
    data.setUint8(18, (11 << 4) | 9);
    data.setUint8(19, 73);
    _writeCrc(bytes);

    final record = Mg24MinuteRecord.parse(data, 0);

    expect(record, isNotNull);
    expect(record!.snoreSeconds, 12);
    expect(record.snoreVolumePercent, 63);
    expect(record.ppgQuality, 77);
    expect(record.respirationQuality, 0);
    expect(record.batteryPercent, 73);
  });

  test('old minute archive records keep respiration quality', () {
    final bytes = Uint8List(Mg24MinuteRecord.wireLength);
    final data = ByteData.sublistView(bytes);
    data.setUint16(4, 0x04, Endian.little);
    data.setUint8(8, 34);
    data.setUint8(18, 8);
    _writeCrc(bytes);

    final record = Mg24MinuteRecord.parse(data, 0);

    expect(record, isNotNull);
    expect(record!.respirationRatePerMin, 17);
    expect(record.respirationQuality, 56);
    expect(record.snoreVolumePercent, isNull);
  });

  for (final packetLength in [
    Mg24ArchivePacket.legacyPacketLength,
    Mg24ArchivePacket.packetLength,
  ]) {
    test('parses $packetLength byte indexed minute archive packets', () {
      final capacity = (packetLength - 12) ~/ Mg24MinuteRecord.wireLength;
      final bytes = Uint8List(packetLength);
      final data = ByteData.sublistView(bytes);
      data
        ..setUint8(0, mg24ProtocolMagic)
        ..setUint8(1, mg24ProtocolVersion)
        ..setUint8(2, mg24ArchivePacketType)
        ..setUint8(3, 1)
        ..setUint16(4, 23, Endian.little)
        ..setUint16(6, 40, Endian.little)
        ..setUint8(8, capacity);
      for (var index = 0; index < capacity; index++) {
        final offset = 10 + index * Mg24MinuteRecord.wireLength;
        data
          ..setUint16(offset, 23, Endian.little)
          ..setUint16(offset + 2, 40 + index, Endian.little);
        final record = Uint8List.sublistView(
          bytes,
          offset,
          offset + Mg24MinuteRecord.wireLength,
        );
        _writeCrc(record);
      }
      _writeCrc(bytes);

      final packet = Mg24ArchivePacket.parse(bytes);

      expect(packet, isNotNull);
      expect(packet!.firstRecord, 40);
      expect(packet.records.length, capacity);
      expect(packet.records.last.minuteIndex, 40 + capacity - 1);
    });
  }

  for (final packetLength in [
    Mg24EventArchivePacket.legacyPacketLength,
    Mg24EventArchivePacket.packetLength,
  ]) {
    test('parses $packetLength byte indexed event archive packets', () {
      final capacity = (packetLength - 12) ~/ Mg24EventRecord.wireLength;
      final bytes = Uint8List(packetLength);
      final data = ByteData.sublistView(bytes);
      data
        ..setUint8(0, mg24ProtocolMagic)
        ..setUint8(1, mg24ProtocolVersion)
        ..setUint8(2, mg24EventArchivePacketType)
        ..setUint8(3, 1)
        ..setUint16(4, 23, Endian.little)
        ..setUint16(6, 80, Endian.little)
        ..setUint8(8, capacity)
        ..setUint8(9, 2);
      for (var index = 0; index < capacity; index++) {
        final offset = 10 + index * Mg24EventRecord.wireLength;
        data
          ..setUint32(offset, 1000 + index * 10, Endian.little)
          ..setUint8(offset + 4, 10)
          ..setUint8(offset + 5, 90);
      }
      _writeCrc(bytes);

      final packet = Mg24EventArchivePacket.parse(bytes);

      expect(packet, isNotNull);
      expect(packet!.firstRecord, 80);
      expect(packet.kind, Mg24EventKind.breathCycle);
      expect(packet.records.length, capacity);
      expect(packet.records.last.startTick, 1000 + (capacity - 1) * 10);
    });
  }
}

void _writeCrc(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  data.setUint16(
    bytes.length - 2,
    mg24Crc16(bytes, 0, bytes.length - 2),
    Endian.little,
  );
}
