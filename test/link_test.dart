import 'dart:async';
import 'dart:typed_data';

import 'package:blue_room/models/models.dart';
import 'package:blue_room/protocol/link.dart';
import 'package:blue_room/transport/chat_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecorderTransport implements ChatTransport {
  _RecorderTransport(this.payloadSize);

  final int payloadSize;
  final List<Uint8List> sent = [];
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  bool get isSupported => true;

  @override
  bool get canHost => true;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async => _events.close();

  @override
  Future<void> startHosting(RoomInfo info) async {}

  @override
  Future<void> stopHosting() async {}

  @override
  Future<void> startScan() async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(DiscoveredRoom room) async {}

  @override
  Future<void> disconnect(String connectionId) async {}

  @override
  int maxPayloadSize(String connectionId) => payloadSize;

  @override
  Future<void> send(String connectionId, Uint8List data) async {
    sent.add(Uint8List.fromList(data));
  }
}

void main() {
  test('frames are split into chunks and reassembled out of order', () async {
    final senderTransport = _RecorderTransport(60);
    final receiverTransport = _RecorderTransport(60);
    final sender = Link(transport: senderTransport, connectionId: 'a');
    final receiver = Link(transport: receiverTransport, connectionId: 'b');
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    final payload = Uint8List.fromList(
      List<int>.generate(2000, (index) => index & 0xff),
    );

    final assembledFuture = receiver.frames.first.timeout(
      const Duration(seconds: 2),
    );
    await sender.sendFrame(payload);

    expect(senderTransport.sent.length, greaterThan(1));
    // Deliver in reverse order: reassembly must use the chunk index.
    for (final chunk in senderTransport.sent.reversed) {
      receiver.handleData(chunk);
    }

    final assembled = await assembledFuture;
    expect(assembled, equals(payload));
  });

  test('duplicate chunks are tolerated and gaps are dropped', () async {
    final senderTransport = _RecorderTransport(40);
    final receiverTransport = _RecorderTransport(40);
    final sender = Link(transport: senderTransport, connectionId: 'a');
    final receiver = Link(transport: receiverTransport, connectionId: 'b');
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    final payload = Uint8List.fromList(
      List<int>.generate(500, (index) => index & 0xff),
    );

    final assembledFuture = receiver.frames.first.timeout(
      const Duration(seconds: 2),
    );
    await sender.sendFrame(payload);

    for (final chunk in senderTransport.sent) {
      receiver.handleData(chunk);
      receiver.handleData(chunk);
    }

    final assembled = await assembledFuture;
    expect(assembled, equals(payload));
  });

  test('a frame larger than the protocol limit is rejected', () async {
    final transport = _RecorderTransport(180);
    final link = Link(transport: transport, connectionId: 'a');
    addTearDown(link.dispose);

    final tooLarge = Uint8List(32 * 1024 + 1);
    await expectLater(link.sendFrame(tooLarge), throwsA(isA<Exception>()));
    expect(transport.sent, isEmpty);
  });
}
