import 'dart:async';
import 'dart:typed_data';

import '../models/models.dart';
import 'chat_transport.dart';

/// In-process transport used on desktop and in tests. Multiple instances share
/// a hub and behave like nearby devices.
class FakeHub {
  FakeHub();

  final Map<FakeTransport, RoomInfo> _hosts = {};
  final Set<FakeTransport> _devices = {};
  int _linkCounter = 0;

  void registerDevice(FakeTransport device) => _devices.add(device);

  void unregisterDevice(FakeTransport device) => _devices.remove(device);

  void publishHost(FakeTransport device, RoomInfo info) {
    _hosts[device] = info;
    _broadcastDiscoveries();
  }

  void unpublishHost(FakeTransport device) {
    _hosts.remove(device);
  }

  void _broadcastDiscoveries() {
    for (final device in _devices.toList()) {
      if (!device.scanning) continue;
      for (final entry in _hosts.entries) {
        if (entry.key == device) continue;
        device.emitDiscovery(entry.key.address, entry.value);
      }
    }
  }

  FakeTransport? hostForAddress(String address) {
    for (final host in _hosts.keys) {
      if (host.address == address) return host;
    }
    return null;
  }

  String nextLinkId() => 'link-${_linkCounter++}';
}

class FakeTransport implements ChatTransport {
  FakeTransport(this.hub, {this.chunkSize = 180, String? address})
    : address = address ?? 'fake-${_counter++}';

  static int _counter = 0;

  final FakeHub hub;
  final String address;
  final int chunkSize;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  final Map<String, _FakeLink> _links = {};

  RoomInfo? _hosted;
  bool _scanning = false;
  bool _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  bool get isSupported => true;

  @override
  bool get canHost => true;

  bool get scanning => _scanning;

  @override
  Future<void> init() async {
    hub.registerDevice(this);
    scheduleMicrotask(() {
      if (!_disposed) {
        _events.add(const TransportStateChanged(enabled: true));
      }
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await stopHosting();
    await stopScan();
    hub.unregisterDevice(this);
    await _events.close();
  }

  @override
  Future<void> startHosting(RoomInfo info) async {
    if (_hosted != null) {
      throw const AppException('This device is already hosting a room');
    }
    _hosted = info;
    hub.publishHost(this, info);
  }

  @override
  Future<void> stopHosting() async {
    if (_hosted == null) return;
    _hosted = null;
    hub.unpublishHost(this);
    for (final link in _links.values.toList()) {
      _closeLink(link);
    }
    _links.clear();
  }

  @override
  Future<void> startScan() async {
    _scanning = true;
    scheduleMicrotask(() {
      if (!_disposed && _scanning) {
        hub._broadcastDiscoveries();
      }
    });
  }

  @override
  Future<void> stopScan() async {
    _scanning = false;
  }

  @override
  Future<void> connect(DiscoveredRoom room) async {
    final host = hub.hostForAddress(room.peripheralId);
    final info = host?._hosted;
    if (host == null || info == null) {
      throw const AppException('That room is no longer available');
    }
    if (host == this) {
      throw const AppException('Cannot join your own room');
    }

    final linkId = hub.nextLinkId();
    final clientConnection = 'fake-c:$linkId';
    final hostConnection = 'fake-h:$linkId';
    final link = _FakeLink(
      client: this,
      host: host,
      clientConnectionId: clientConnection,
      hostConnectionId: hostConnection,
    );
    _links[clientConnection] = link;
    host._links[hostConnection] = link;

    scheduleMicrotask(() {
      if (!link.active || _disposed || host._disposed) return;
      _events.add(
        TransportConnected(
          connectionId: clientConnection,
          hostSide: false,
          roomInfo: info,
        ),
      );
      host._events.add(
        TransportConnected(connectionId: hostConnection, hostSide: true),
      );
    });
  }

  @override
  Future<void> disconnect(String connectionId) async {
    final link = _links.remove(connectionId);
    if (link != null) {
      _closeLink(link);
    }
  }

  @override
  int maxPayloadSize(String connectionId) => chunkSize;

  @override
  Future<void> send(String connectionId, Uint8List data) async {
    final link = _links[connectionId];
    if (link == null || !link.active) {
      throw const AppException('Connection is closed');
    }
    final peer = link.peerOf(this);
    final peerConnectionId = link.peerConnectionIdOf(this);
    final copy = Uint8List.fromList(data);
    scheduleMicrotask(() {
      if (!link.active || peer._disposed) return;
      peer._events.add(TransportData(peerConnectionId, copy));
    });
  }

  void emitDiscovery(String hostAddress, RoomInfo info) {
    if (!_scanning || _disposed) return;
    _events.add(
      TransportDiscovered(
        DiscoveredRoom(
          peripheralId: hostAddress,
          displayName: info.roomName,
          roomId: info.roomId,
          requiresPin: info.requiresPin,
          rssi: -48,
          lastSeen: DateTime.now(),
        ),
      ),
    );
  }

  void _closeLink(_FakeLink link) {
    if (!link.active) return;
    link.active = false;
    link.client._links.remove(link.clientConnectionId);
    link.host._links.remove(link.hostConnectionId);
    if (!link.client._disposed) {
      link.client._events.add(
        TransportDisconnected(link.clientConnectionId, reason: 'link closed'),
      );
    }
    if (!link.host._disposed) {
      link.host._events.add(
        TransportDisconnected(link.hostConnectionId, reason: 'link closed'),
      );
    }
  }
}

class _FakeLink {
  _FakeLink({
    required this.client,
    required this.host,
    required this.clientConnectionId,
    required this.hostConnectionId,
  });

  final FakeTransport client;
  final FakeTransport host;
  final String clientConnectionId;
  final String hostConnectionId;
  bool active = true;

  FakeTransport peerOf(FakeTransport side) => side == client ? host : client;

  String peerConnectionIdOf(FakeTransport side) =>
      side == client ? hostConnectionId : clientConnectionId;
}
