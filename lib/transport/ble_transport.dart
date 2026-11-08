import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../core/constants.dart';
import '../models/models.dart';
import '../util/bytes.dart';
import 'chat_transport.dart';

/// Real BLE transport: hosts advertise a GATT service, members connect as
/// centrals. Mobile platforms support both roles; Linux supports the central
/// (member) role only, because the Linux plugin has no peripheral manager.
class BleTransport implements ChatTransport {
  BleTransport({this.canHost = true}) {
    if (canHost && !(Platform.isAndroid || Platform.isIOS)) {
      throw const AppException('Hosting is not supported on this platform');
    }
  }

  /// Whether this instance should advertise and host rooms.
  @override
  final bool canHost;

  late final CentralManager _central;
  PeripheralManager? _peripheral;

  final UUID _serviceUuid = UUID.short(Protocol.serviceShortId);
  final UUID _infoUuid = UUID.fromString(Protocol.infoUuid);
  final UUID _rxUuid = UUID.fromString(Protocol.rxUuid);
  final UUID _txUuid = UUID.fromString(Protocol.txUuid);

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  final Map<String, Peripheral> _peripherals = {};
  final Map<String, Central> _centrals = {};
  final Map<String, GATTCharacteristic> _clientWriteCharacteristics = {};
  final Map<String, GATTCharacteristic> _hostNotifyCharacteristics = {};
  final Map<String, int> _maxPayloadSizes = {};
  final Map<String, Future<void>> _writeQueues = {};
  final Set<String> _hostConnections = {};

  GATTCharacteristic? _hostTxCharacteristic;
  RoomInfo? _hostedInfo;
  bool _advertising = false;
  bool _scanning = false;
  bool _disposed = false;
  BluetoothLowEnergyState _lastState = BluetoothLowEnergyState.unknown;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || (Platform.isLinux && !canHost);

  @override
  Future<void> init() async {
    _central = CentralManager();
    if (canHost) {
      _peripheral = PeripheralManager();
    }
    _wireEvents();
    _emitState(_central.state);
  }

  void _wireEvents() {
    _subscriptions.add(
      _central.stateChanged.listen((event) => _emitState(event.state)),
    );
    if (canHost) {
      _subscriptions.add(
        _peripheral!.stateChanged.listen((event) => _emitState(event.state)),
      );
    }

    _subscriptions.add(
      _central.discovered.listen((event) {
        if (!_scanning || _disposed) return;
        final id = event.peripheral.uuid.toString();
        _peripherals[id] = event.peripheral;
        final advertisement = event.advertisement;
        var displayName = advertisement.name?.trim() ?? '';
        if (displayName.isEmpty) displayName = 'Nearby room';
        String? roomId;
        bool? requiresPin;
        if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
          try {
            for (final data in advertisement.manufacturerSpecificData) {
              if (data.id != Protocol.manufacturerId || data.data.length < 8) {
                continue;
              }
              final bytes = data.data;
              if (bytes[0] != Protocol.version) continue;
              requiresPin = (bytes[1] & 1) == 1;
              roomId = hex(bytes.sublist(2, 8));
            }
          } catch (_) {
            // Some platforms do not expose manufacturer data.
          }
        }
        _events.add(
          TransportDiscovered(
            DiscoveredRoom(
              peripheralId: id,
              displayName: displayName,
              roomId: roomId,
              requiresPin: requiresPin,
              rssi: event.rssi,
              lastSeen: DateTime.now(),
            ),
          ),
        );
      }),
    );

    _subscriptions.add(
      _central.characteristicNotified.listen((event) {
        final id = event.peripheral.uuid.toString();
        final tx = _hostNotifyCharacteristics[id];
        if (tx == null || event.characteristic.uuid != tx.uuid) return;
        _events.add(TransportData(id, event.value));
      }),
    );

    _subscriptions.add(
      _central.connectionStateChanged.listen((event) {
        final id = event.peripheral.uuid.toString();
        if (event.state == ConnectionState.disconnected) {
          _cleanupClientConnection(id);
          _events.add(
            TransportDisconnected(id, reason: 'Bluetooth disconnected'),
          );
        }
      }),
    );

    if (Platform.isAndroid || Platform.isWindows) {
      _subscriptions.add(
        _central.mtuChanged.listen((event) {
          final id = event.peripheral.uuid.toString();
          unawaited(_refreshClientPayloadSize(event.peripheral, id));
        }),
      );
    }

    // Everything below is the peripheral (host) side, which the Linux plugin
    // does not implement.
    if (!canHost) return;

    _subscriptions.add(
      _peripheral!.characteristicReadRequested.listen((event) async {
        final info = _hostedInfo;
        if (info == null || event.characteristic.uuid != _infoUuid) {
          try {
            await _peripheral!.respondReadRequestWithError(
              event.request,
              error: GATTError.readNotPermitted,
            );
          } catch (_) {
            // Ignore.
          }
          return;
        }
        final value = info.toBytes();
        final offset = event.request.offset.clamp(0, value.length).toInt();
        try {
          await _peripheral!.respondReadRequestWithValue(
            event.request,
            value: Uint8List.sublistView(value, offset),
          );
        } catch (_) {
          // Ignore.
        }
      }),
    );

    _subscriptions.add(
      _peripheral!.characteristicWriteRequested.listen((event) async {
        final id = event.central.uuid.toString();
        _centrals[id] = event.central;
        try {
          await _peripheral!.respondWriteRequest(event.request);
        } catch (_) {
          // Write-without-response requests do not need a reply.
        }
        if (!_hostConnections.contains(id)) {
          _hostConnections.add(id);
          _events.add(TransportConnected(connectionId: id, hostSide: true));
          unawaited(_refreshHostPayloadSize(event.central, id));
        }
        if (event.characteristic.uuid == _rxUuid) {
          _events.add(TransportData(id, event.request.value));
        }
      }),
    );

    _subscriptions.add(
      _peripheral!.characteristicNotifyStateChanged.listen((event) async {
        final id = event.central.uuid.toString();
        _centrals[id] = event.central;
        if (event.state) {
          if (!_hostConnections.contains(id)) {
            _hostConnections.add(id);
            _events.add(TransportConnected(connectionId: id, hostSide: true));
          }
          await _refreshHostPayloadSize(event.central, id);
        }
      }),
    );

    if (Platform.isAndroid) {
      _subscriptions.add(
        _peripheral!.connectionStateChanged.listen((event) {
          final id = event.central.uuid.toString();
          if (event.state == ConnectionState.disconnected) {
            _cleanupHostConnection(id);
            _events.add(
              TransportDisconnected(id, reason: 'Member disconnected'),
            );
          }
        }),
      );
    }

    if (Platform.isAndroid || Platform.isWindows) {
      _subscriptions.add(
        _peripheral!.mtuChanged.listen((event) {
          final id = event.central.uuid.toString();
          unawaited(_refreshHostPayloadSize(event.central, id));
        }),
      );
    }
  }

  void _emitState(BluetoothLowEnergyState state) {
    if (_disposed || state == _lastState) return;
    _lastState = state;
    String? error;
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        error = null;
      case BluetoothLowEnergyState.poweredOff:
        error = 'Bluetooth is turned off';
      case BluetoothLowEnergyState.unauthorized:
        error = 'Bluetooth permission was denied';
      case BluetoothLowEnergyState.unsupported:
        error = 'Bluetooth LE is not supported on this device';
      case BluetoothLowEnergyState.unknown:
        error = 'Bluetooth state is unknown';
    }
    _events.add(
      TransportStateChanged(
        enabled: state == BluetoothLowEnergyState.poweredOn,
        error: error,
      ),
    );
  }

  Future<void> _ensureReady() async {
    if (!isSupported) {
      throw const AppException('Bluetooth LE is not supported here');
    }
    // BlueZ connects to the system bus asynchronously after startup, so the
    // first scan can race the initial state read.
    if (Platform.isLinux && _central.state == BluetoothLowEnergyState.unknown) {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (_central.state == BluetoothLowEnergyState.unknown &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (_central.state != BluetoothLowEnergyState.poweredOn) {
      if (_central.state == BluetoothLowEnergyState.unauthorized) {
        throw const AppException('Bluetooth permission was denied');
      }
      throw const AppException('Turn on Bluetooth to continue');
    }
  }

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      await _central.authorize();
    } catch (_) {
      // Ignore; state checks will report the real problem.
    }
  }

  @override
  Future<void> startScan() async {
    await _requestPermissions();
    await _ensureReady();
    if (_scanning) return;
    _scanning = true;
    _peripherals.clear();
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    } catch (error) {
      _scanning = false;
      throw AppException(_messageOf(error));
    }
  }

  @override
  Future<void> stopScan() async {
    if (!_scanning) return;
    _scanning = false;
    try {
      await _central.stopDiscovery();
    } catch (_) {
      // Ignore.
    }
  }

  @override
  Future<void> connect(DiscoveredRoom room) async {
    await _ensureReady();
    final peripheral = _peripherals[room.peripheralId];
    if (peripheral == null) {
      throw const AppException('That room is no longer nearby');
    }
    final id = room.peripheralId;
    try {
      await _central.connect(peripheral);
      if (Platform.isAndroid) {
        // Larger MTU makes history sync dramatically faster. iOS negotiates
        // this automatically and rejects explicit requests.
        try {
          await _central.requestMTU(peripheral, mtu: 517);
        } catch (_) {
          // Keep the default MTU.
        }
      }
      final services = await _central.discoverGATT(peripheral);
      final service = services.firstWhere((item) => item.uuid == _serviceUuid);
      final infoCharacteristic = service.characteristics.firstWhere(
        (item) => item.uuid == _infoUuid,
      );
      final rx = service.characteristics.firstWhere(
        (item) => item.uuid == _rxUuid,
      );
      final tx = service.characteristics.firstWhere(
        (item) => item.uuid == _txUuid,
      );
      final rawInfo = await _central.readCharacteristic(
        peripheral,
        infoCharacteristic,
      );
      final info = RoomInfo.fromBytes(rawInfo);
      await _central.setCharacteristicNotifyState(peripheral, tx, state: true);
      _clientWriteCharacteristics[id] = rx;
      _hostNotifyCharacteristics[id] = tx;
      await _refreshClientPayloadSize(peripheral, id);
      _events.add(
        TransportConnected(connectionId: id, hostSide: false, roomInfo: info),
      );
    } catch (error) {
      await _safeCentralDisconnect(peripheral);
      _cleanupClientConnection(id);
      throw AppException('Could not join the room: ${_messageOf(error)}');
    }
  }

  Future<void> _refreshClientPayloadSize(
    Peripheral peripheral,
    String id,
  ) async {
    try {
      final size = await _central.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
      _maxPayloadSizes[id] = size
          .clamp(
            Protocol.chunkHeaderSize + Protocol.minChunkSize,
            Protocol.maxBlePayload,
          )
          .toInt();
    } catch (_) {
      _maxPayloadSizes[id] = Protocol.defaultBlePayload;
    }
  }

  Future<void> _refreshHostPayloadSize(Central central, String id) async {
    final manager = _peripheral;
    if (manager == null) {
      _maxPayloadSizes[id] = Protocol.defaultBlePayload;
      return;
    }
    try {
      final size = await manager.getMaximumNotifyLength(central);
      _maxPayloadSizes[id] = size
          .clamp(
            Protocol.chunkHeaderSize + Protocol.minChunkSize,
            Protocol.maxBlePayload,
          )
          .toInt();
    } catch (_) {
      _maxPayloadSizes[id] = Protocol.defaultBlePayload;
    }
  }

  @override
  Future<void> startHosting(RoomInfo info) async {
    if (!canHost) {
      throw const AppException('Hosting is only available on phones');
    }
    final manager = _peripheral;
    if (manager == null) {
      throw const AppException('Hosting is not available here');
    }
    await _requestPermissions();
    await _ensureReady();
    if (_advertising) {
      throw const AppException('This device is already hosting a room');
    }
    try {
      await manager.removeAllServices();
      final infoCharacteristic = GATTCharacteristic.mutable(
        uuid: _infoUuid,
        properties: [GATTCharacteristicProperty.read],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: const [],
      );
      final rx = GATTCharacteristic.mutable(
        uuid: _rxUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );
      final tx = GATTCharacteristic.mutable(
        uuid: _txUuid,
        properties: [GATTCharacteristicProperty.notify],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: const [],
      );
      final service = GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: const [],
        characteristics: [infoCharacteristic, rx, tx],
      );
      await manager.addService(service);
      _hostTxCharacteristic = tx;

      final roomIdBytes = fromHex(info.roomId);
      final advertisement = Advertisement(
        name: shortRoomName(info.roomName),
        serviceUUIDs: [_serviceUuid],
        manufacturerSpecificData:
            (Platform.isAndroid || Platform.isWindows) &&
                roomIdBytes.length == 6
            ? [
                ManufacturerSpecificData(
                  id: Protocol.manufacturerId,
                  data: Uint8List.fromList([
                    Protocol.version,
                    info.requiresPin ? 1 : 0,
                    ...roomIdBytes,
                  ]),
                ),
              ]
            : const [],
      );
      await manager.startAdvertising(advertisement);
      _hostedInfo = info;
      _advertising = true;
    } catch (error) {
      await stopHosting();
      throw AppException('Could not start the room: ${_messageOf(error)}');
    }
  }

  @override
  Future<void> stopHosting() async {
    _advertising = false;
    _hostedInfo = null;
    _hostTxCharacteristic = null;
    final manager = _peripheral;
    if (manager == null) {
      _hostConnections.clear();
      return;
    }
    for (final id in _hostConnections.toList()) {
      final central = _centrals[id];
      if (central != null) {
        try {
          await manager.disconnect(central);
        } catch (_) {
          // Ignore.
        }
      }
      _cleanupHostConnection(id);
    }
    _hostConnections.clear();
    try {
      await manager.stopAdvertising();
    } catch (_) {
      // Ignore.
    }
    try {
      await manager.removeAllServices();
    } catch (_) {
      // Ignore.
    }
  }

  @override
  Future<void> disconnect(String connectionId) async {
    final peripheral = _peripherals[connectionId];
    if (peripheral != null) {
      await _safeCentralDisconnect(peripheral);
      _cleanupClientConnection(connectionId);
      return;
    }
    final central = _centrals[connectionId];
    final manager = _peripheral;
    if (central != null && manager != null) {
      try {
        await manager.disconnect(central);
      } catch (_) {
        // Ignore.
      }
      _cleanupHostConnection(connectionId);
    }
  }

  Future<void> _safeCentralDisconnect(Peripheral peripheral) async {
    try {
      await _central.disconnect(peripheral);
    } catch (_) {
      // Ignore.
    }
  }

  @override
  int maxPayloadSize(String connectionId) =>
      _maxPayloadSizes[connectionId] ?? Protocol.defaultBlePayload;

  @override
  Future<void> send(String connectionId, Uint8List data) {
    final previous = _writeQueues[connectionId] ?? Future<void>.value();
    final next = previous.then((_) async {
      final peripheral = _peripherals[connectionId];
      if (peripheral != null) {
        final characteristic = _clientWriteCharacteristics[connectionId];
        if (characteristic == null) {
          throw const AppException('Connection is not ready');
        }
        await _central.writeCharacteristic(
          peripheral,
          characteristic,
          value: data,
          type: GATTCharacteristicWriteType.withResponse,
        );
        return;
      }
      final central = _centrals[connectionId];
      final tx = _hostTxCharacteristic;
      final manager = _peripheral;
      if (central == null || tx == null || manager == null) {
        throw const AppException('Connection is not ready');
      }
      await manager.notifyCharacteristic(central, tx, value: data);
    });
    _writeQueues[connectionId] = next.catchError((_) {});
    return next;
  }

  void _cleanupClientConnection(String id) {
    final peripheral = _peripherals[id];
    final tx = _hostNotifyCharacteristics[id];
    if (peripheral != null && tx != null) {
      try {
        unawaited(
          _central.setCharacteristicNotifyState(peripheral, tx, state: false),
        );
      } catch (_) {
        // Ignore.
      }
    }
    _clientWriteCharacteristics.remove(id);
    _hostNotifyCharacteristics.remove(id);
    _maxPayloadSizes.remove(id);
    _writeQueues.remove(id);
    _peripherals.remove(id);
  }

  void _cleanupHostConnection(String id) {
    _hostConnections.remove(id);
    _centrals.remove(id);
    _maxPayloadSizes.remove(id);
    _writeQueues.remove(id);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await stopHosting();
    await stopScan();
    for (final peripheral in _peripherals.values) {
      await _safeCentralDisconnect(peripheral);
    }
    _peripherals.clear();
    await _events.close();
  }
}

String _messageOf(Object error) {
  if (error is AppException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
