import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../crypto/identity.dart';
import '../data/chat_repository.dart';
import '../data/local_store.dart';
import '../models/models.dart';
import '../protocol/room_session.dart';
import '../transport/chat_transport.dart';
import '../util/bytes.dart';

class ChatService extends ChangeNotifier {
  ChatService({
    required this.identity,
    required this.store,
    required this.repository,
    required this.transport,
  });

  final DeviceIdentity identity;
  final LocalStore store;
  final ChatRepository repository;
  final ChatTransport transport;

  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final List<Chat> _chats = [];
  final List<DiscoveredRoom> _nearby = [];
  final List<ChatMessage> _activeMessages = [];
  final List<ChatMember> _activeMembers = [];

  StreamSubscription<TransportEvent>? _transportSubscription;
  Timer? _pruneTimer;
  RoomSession? _session;
  _Probe? _probe;
  bool _ready = false;
  bool _disposed = false;
  bool _scanning = false;
  bool _bluetoothEnabled = true;
  String? _bluetoothError;
  String? _activeChatId;
  String? _displayName;

  bool get ready => _ready;
  bool get scanning => _scanning;
  bool get canHost => transport.canHost;
  bool get bluetoothEnabled => _bluetoothEnabled;
  String? get bluetoothError => _bluetoothError;
  String get displayName => _displayName ?? '';
  String? get activeChatId => _activeChatId;
  bool get hasLiveSession => _session != null;
  String? get liveChatId => _session?.chatId;
  List<Chat> get chats => List.unmodifiable(_chats);
  List<DiscoveredRoom> get nearbyRooms => List.unmodifiable(_nearby);
  List<ChatMessage> get activeMessages => List.unmodifiable(_activeMessages);
  List<ChatMember> get activeMembers => List.unmodifiable(_activeMembers);
  Stream<String> get notices => _notices.stream;

  Future<void> init() async {
    _displayName = store.readPref('identity.name') ?? '';
    _transportSubscription = transport.events.listen(_onTransportEvent);
    await transport.init();
    await _refreshChats();
    // A live room cannot survive a process restart: mark stale sessions
    // offline so the UI offers a reconnect instead of pretending to be live.
    final stale = _chats
        .where((chat) => chat.status == ChatStatus.live)
        .toList();
    if (stale.isNotEmpty) {
      for (final chat in stale) {
        await repository.setStatus(chat.id, ChatStatus.offline);
        await repository.setAllMembersOffline(chat.id);
      }
      await _refreshChats();
    }
    _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final before = _nearby.length;
      _nearby.removeWhere((room) => room.isStale);
      if (_nearby.length != before) _notify();
    });
    _ready = true;
    _notify();
  }

  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const AppException('Enter a display name');
    if (trimmed.length > 48) throw const AppException('Name is too long');
    _displayName = trimmed;
    await store.writePref('identity.name', trimmed);
    _notify();
  }

  Future<void> _refreshChats() async {
    final selfId = await identity.deviceId;
    final chats = await repository.loadChats(selfDeviceId: selfId);
    _chats
      ..clear()
      ..addAll(chats);
  }

  Future<void> _refreshActive() async {
    final id = _activeChatId;
    if (id == null) return;
    Chat? chat;
    for (final candidate in _chats) {
      if (candidate.id == id) {
        chat = candidate;
        break;
      }
    }
    chat ??= await repository.loadChat(id);
    if (_activeChatId != id) return;
    if (chat != null) {
      await repository.markRead(id, chat.lastSeq);
    }
    final messages = await repository.recentMessages(id, limit: 300);
    final members = await repository.loadMembers(id);
    if (_activeChatId != id) return;
    _activeMessages
      ..clear()
      ..addAll(messages);
    _activeMembers
      ..clear()
      ..addAll(members);
  }

  Future<void> _refreshAll() async {
    await _refreshActive();
    await _refreshChats();
    _notify();
  }

  Future<void> openChat(String chatId) async {
    _activeChatId = chatId;
    await _refreshActive();
    await _refreshChats();
    _notify();
  }

  Future<void> closeChat([String? chatId]) async {
    final id = chatId ?? _activeChatId;
    if (id == null) return;
    final chat = await repository.loadChat(id);
    if (chat != null) {
      await repository.markRead(id, chat.lastSeq);
    }
    if (_activeChatId == id) {
      _activeChatId = null;
      _activeMessages.clear();
      _activeMembers.clear();
    }
    await _refreshChats();
    _notify();
  }

  Future<void> startScan() async {
    if (_scanning) return;
    _nearby.clear();
    _scanning = true;
    _notify();
    try {
      await transport.startScan();
    } catch (error) {
      _scanning = false;
      _bluetoothError = _messageOf(error);
      _notify();
      rethrow;
    }
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    _scanning = false;
    _nearby.clear();
    _notify();
    try {
      await transport.stopScan();
    } catch (_) {
      // Ignore.
    }
  }

  Future<RoomInfo> probeRoom(DiscoveredRoom room) async {
    if (_session != null) {
      throw const AppException('Disconnect from the current room first');
    }
    if (_probe != null) {
      throw const AppException('Another room is being checked');
    }
    final probe = _Probe();
    _probe = probe;
    String? connectionId;
    try {
      await transport.connect(room);
      final result = await probe.completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const AppException('Could not reach that room'),
      );
      connectionId = result.connectionId;
      return result.info;
    } finally {
      if (identical(_probe, probe)) _probe = null;
      final id = connectionId ?? probe.connectionId;
      if (id != null) {
        try {
          await transport.disconnect(id);
        } catch (_) {
          // Ignore.
        }
      }
    }
  }

  Future<Chat> createRoom({required String name, String? pin}) async {
    if (!transport.canHost) {
      throw const AppException('Hosting is only available on phones');
    }
    await _ensureNoSession();
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const AppException('Enter a room name');
    if (trimmed.length > 48) throw const AppException('Room name is too long');
    final normalizedPin = _normalizePin(pin);
    final roomId = generateRoomId();
    final deviceId = await identity.deviceId;
    final info = RoomInfo(
      roomId: roomId,
      roomName: trimmed,
      hostId: deviceId,
      hostName: displayName,
      hostSigningKey: b64(await identity.signingPublicKey),
      hostDhKey: b64(await identity.dhPublicKey),
      requiresPin: normalizedPin != null,
    );
    final chat = Chat(
      id: roomId,
      name: trimmed,
      role: ChatRole.host,
      requiresPin: normalizedPin != null,
      hostId: deviceId,
      hostName: displayName,
      hostSigningKey: info.hostSigningKey,
      hostDhKey: info.hostDhKey,
      createdAt: DateTime.now(),
      status: ChatStatus.offline,
    );
    await repository.saveChat(chat);
    if (normalizedPin != null) {
      await store.writeSecret(
        '${Protocol.pinSecretPrefix}$roomId',
        normalizedPin,
      );
    }

    final session = HostRoomSession(
      chatId: roomId,
      identity: identity,
      repository: repository,
      transport: transport,
      callbacks: _callbacks(roomId),
      displayName: displayName,
      info: info,
      pin: normalizedPin,
    );
    _session = session;
    _notify();
    try {
      await session.start();
    } catch (error) {
      _session = null;
      await repository.setStatus(roomId, ChatStatus.offline);
      _notify();
      rethrow;
    }
    await _refreshAll();
    return _chat(roomId) ?? chat;
  }

  Future<Chat> joinRoom({
    required DiscoveredRoom room,
    required RoomInfo info,
    String? pin,
  }) async {
    await _ensureNoSession();
    final normalizedPin = _normalizePin(pin);
    if (info.requiresPin && normalizedPin == null) {
      throw const AppException('This room requires a PIN');
    }
    final existing = await repository.loadChat(info.roomId);
    final chat =
        existing ??
        Chat(
          id: info.roomId,
          name: info.roomName,
          role: ChatRole.member,
          requiresPin: info.requiresPin,
          hostId: info.hostId,
          hostName: info.hostName,
          hostSigningKey: info.hostSigningKey,
          hostDhKey: info.hostDhKey,
          createdAt: DateTime.now(),
          status: ChatStatus.offline,
        );
    if (normalizedPin != null) {
      await store.writeSecret(
        '${Protocol.pinSecretPrefix}${info.roomId}',
        normalizedPin,
      );
    }

    final session = MemberRoomSession(
      chatId: info.roomId,
      identity: identity,
      repository: repository,
      transport: transport,
      callbacks: _callbacks(info.roomId),
      displayName: displayName,
      chat: chat,
      room: room,
      info: info,
      pin: normalizedPin,
    );
    _session = session;
    _notify();
    try {
      await session.start();
    } catch (error) {
      _session = null;
      _notify();
      rethrow;
    }
    await _refreshAll();
    return await repository.loadChat(info.roomId) ?? chat;
  }

  Future<void> resume(Chat chat) async {
    await _ensureNoSession();
    if (chat.isHost) {
      await _resumeHost(chat);
    } else {
      await _resumeMember(chat);
    }
  }

  Future<void> _resumeHost(Chat chat) async {
    if (!transport.canHost) {
      throw const AppException('Hosting is only available on phones');
    }
    final pin = await store.readSecret('${Protocol.pinSecretPrefix}${chat.id}');
    final info = RoomInfo(
      roomId: chat.id,
      roomName: chat.name,
      hostId: chat.hostId,
      hostName: chat.hostName,
      hostSigningKey: chat.hostSigningKey,
      hostDhKey: chat.hostDhKey,
      requiresPin: chat.requiresPin,
    );
    final session = HostRoomSession(
      chatId: chat.id,
      identity: identity,
      repository: repository,
      transport: transport,
      callbacks: _callbacks(chat.id),
      displayName: displayName,
      info: info,
      pin: pin,
    );
    _session = session;
    _notify();
    try {
      await session.start();
    } catch (error) {
      _session = null;
      _notify();
      rethrow;
    }
    await _refreshAll();
  }

  Future<void> _resumeMember(Chat chat) async {
    final pin = await store.readSecret('${Protocol.pinSecretPrefix}${chat.id}');
    if (chat.requiresPin && (pin == null || pin.isEmpty)) {
      throw const AppException('This room requires a PIN');
    }
    await startScan();
    try {
      final room = await _waitForRoom(chat);
      if (room == null) {
        throw const AppException('Room is not nearby right now');
      }
      final info = RoomInfo(
        roomId: chat.id,
        roomName: chat.name,
        hostId: chat.hostId,
        hostName: chat.hostName,
        hostSigningKey: chat.hostSigningKey,
        hostDhKey: chat.hostDhKey,
        requiresPin: chat.requiresPin,
      );
      await joinRoom(room: room, info: info, pin: pin);
    } finally {
      await stopScan();
    }
  }

  Future<DiscoveredRoom?> _waitForRoom(Chat chat) async {
    final deadline = DateTime.now().add(const Duration(seconds: 18));
    final tried = <String>{};
    while (DateTime.now().isBefore(deadline)) {
      for (final room in _nearby) {
        if (room.roomId == chat.id) return room;
      }
      final untried = _nearby
          .where(
            (room) => room.roomId == null && !tried.contains(room.peripheralId),
          )
          .toList();
      for (final room in untried) {
        tried.add(room.peripheralId);
        try {
          final info = await probeRoom(room);
          if (info.roomId == chat.id &&
              info.hostSigningKey == chat.hostSigningKey) {
            return room;
          }
        } catch (_) {
          // Try the next candidate.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  Future<void> disconnectChat(Chat chat) async {
    final session = _session;
    if (session != null && session.chatId == chat.id) {
      await session.close();
    } else {
      await repository.setStatus(chat.id, ChatStatus.offline);
      await repository.setAllMembersOffline(chat.id);
      await _refreshAll();
    }
  }

  Future<void> deleteChat(Chat chat) async {
    final session = _session;
    if (session != null && session.chatId == chat.id) {
      await session.close(deleted: true);
    }
    await store.deleteSecret('${Protocol.pinSecretPrefix}${chat.id}');
    await repository.deleteChat(chat.id);
    if (_activeChatId == chat.id) {
      _activeChatId = null;
      _activeMessages.clear();
      _activeMembers.clear();
    }
    await _refreshChats();
    _notify();
  }

  Future<void> sendMessage(String chatId, String text) async {
    final session = _session;
    if (session == null || session.chatId != chatId) {
      throw const AppException('You are offline');
    }
    await session.sendText(text);
    await _refreshAll();
  }

  Future<void> _ensureNoSession() async {
    final session = _session;
    if (session == null) return;
    final chat = await repository.loadChat(session.chatId);
    throw AppException(
      'Disconnect from "${chat?.name ?? 'the current room'}" first',
    );
  }

  RoomCallbacks _callbacks(String chatId) => RoomCallbacks(
    onChanged: _refreshAll,
    onNotice: (message) {
      if (!_notices.isClosed) _notices.add(message);
    },
    onClosed: ({String? error, bool ended = false}) {
      if (_session?.chatId == chatId) _session = null;
      if (error != null && !_notices.isClosed) {
        _notices.add(error);
      }
      unawaited(_refreshAll());
    },
  );

  void _onTransportEvent(TransportEvent event) {
    switch (event) {
      case TransportStateChanged():
        _bluetoothEnabled = event.enabled;
        _bluetoothError = event.error;
        _notify();
      case TransportDiscovered():
        final index = _nearby.indexWhere(
          (room) => room.peripheralId == event.room.peripheralId,
        );
        if (index >= 0) {
          _nearby[index] = event.room;
        } else {
          _nearby.add(event.room);
        }
        _notify();
      case TransportConnected():
        final probe = _probe;
        if (probe != null && !event.hostSide && event.roomInfo != null) {
          probe.connectionId ??= event.connectionId;
          if (!probe.completer.isCompleted) {
            probe.completer.complete(
              _ProbeResult(event.connectionId, event.roomInfo!),
            );
          }
          return;
        }
        final session = _session;
        if (session != null) {
          unawaited(
            session.onConnected(event).catchError((Object error) {
              if (!_notices.isClosed) _notices.add(_messageOf(error));
            }),
          );
        }
      case TransportData():
        _session?.onData(event);
      case TransportDisconnected():
        final probe = _probe;
        if (probe != null && !probe.completer.isCompleted) {
          probe.completer.completeError(
            const AppException('Connection was closed'),
          );
          _probe = null;
        }
        final session = _session;
        if (session != null) {
          unawaited(session.onDisconnected(event));
        }
    }
  }

  Chat? _chat(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  String? _normalizePin(String? pin) {
    final trimmed = pin?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length < 4 || trimmed.length > 12) {
      throw const AppException('Use a PIN with 4 to 12 characters');
    }
    return trimmed;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pruneTimer?.cancel();
    _transportSubscription?.cancel();
    unawaited(_session?.dispose());
    unawaited(transport.dispose());
    unawaited(_notices.close());
    super.dispose();
  }
}

class _Probe {
  final Completer<_ProbeResult> completer = Completer<_ProbeResult>();
  String? connectionId;
}

class _ProbeResult {
  const _ProbeResult(this.connectionId, this.info);

  final String connectionId;
  final RoomInfo info;
}

String _messageOf(Object error) {
  if (error is AppException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
