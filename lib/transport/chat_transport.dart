import 'dart:typed_data';

import '../models/models.dart';

sealed class TransportEvent {
  const TransportEvent();
}

class TransportDiscovered extends TransportEvent {
  const TransportDiscovered(this.room);

  final DiscoveredRoom room;
}

class TransportConnected extends TransportEvent {
  const TransportConnected({
    required this.connectionId,
    required this.hostSide,
    this.roomInfo,
  });

  final String connectionId;
  final bool hostSide;

  /// Present on the central (joining) side after the INFO characteristic has
  /// been read.
  final RoomInfo? roomInfo;
}

class TransportData extends TransportEvent {
  const TransportData(this.connectionId, this.data);

  final String connectionId;
  final Uint8List data;
}

class TransportDisconnected extends TransportEvent {
  const TransportDisconnected(this.connectionId, {this.reason});

  final String connectionId;
  final String? reason;
}

class TransportStateChanged extends TransportEvent {
  const TransportStateChanged({required this.enabled, this.error});

  final bool enabled;
  final String? error;
}

abstract class ChatTransport {
  Stream<TransportEvent> get events;

  bool get isSupported;

  /// Whether this transport can advertise/host a room. Linux BLE supports the
  /// central role only, so it can join but not host.
  bool get canHost;

  Future<void> init();

  Future<void> dispose();

  Future<void> startHosting(RoomInfo info);

  Future<void> stopHosting();

  Future<void> startScan();

  Future<void> stopScan();

  Future<void> connect(DiscoveredRoom room);

  Future<void> disconnect(String connectionId);

  /// Largest payload that fits in one BLE write/notification for this link.
  int maxPayloadSize(String connectionId);

  Future<void> send(String connectionId, Uint8List data);
}
