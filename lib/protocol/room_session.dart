import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../crypto/handshake.dart';
import '../crypto/identity.dart';
import '../crypto/secure_channel.dart';
import '../data/chat_repository.dart';
import '../models/models.dart';
import '../transport/chat_transport.dart';
import '../util/bytes.dart';
import 'frames.dart';
import 'link.dart';

class RoomCallbacks {
  const RoomCallbacks({
    required this.onChanged,
    required this.onNotice,
    required this.onClosed,
  });

  final Future<void> Function() onChanged;
  final void Function(String message) onNotice;
  final void Function({String? error, bool ended}) onClosed;
}

abstract class RoomSession {
  RoomSession({
    required this.chatId,
    required this.identity,
    required this.repository,
    required this.transport,
    required this.callbacks,
    required this.displayName,
  });

  final String chatId;
  final DeviceIdentity identity;
  final ChatRepository repository;
  final ChatTransport transport;
  final RoomCallbacks callbacks;
  final String displayName;

  bool get isLive;

  Future<void> start();

  Future<void> sendText(String text);

  Future<void> close({String? reason, bool deleted = false});

  Future<void> onConnected(TransportConnected event);

  void onData(TransportData event);

  Future<void> onDisconnected(TransportDisconnected event);

  Future<void> dispose();

  Future<bool> verifyMessage(ChatMessage message) async {
    if (message.chatId != chatId) return false;
    if (message.msgId.isEmpty || message.msgId.length > 64) return false;
    if (message.text.isEmpty || message.text.length > Protocol.maxTextLength) {
      return false;
    }
    if (message.senderName.isEmpty || message.senderName.length > 48) {
      return false;
    }
    try {
      final publicKey = unb64(message.senderKey);
      if (deviceIdFor(publicKey) != message.senderId) return false;
      final payload = messageSigningPayload(
        chatId: message.chatId,
        msgId: message.msgId,
        senderId: message.senderId,
        senderName: message.senderName,
        sentAtMs: message.sentAt.millisecondsSinceEpoch,
        text: message.text,
      );
      return await DeviceIdentity.verify(
        message: payload,
        signature: unb64(message.signature),
        publicKey: publicKey,
      );
    } catch (_) {
      return false;
    }
  }

  Future<ChatMessage> createSignedMessage(String text) async {
    final deviceId = await identity.deviceId;
    final signingKey = await identity.signingPublicKey;
    final sentAt = DateTime.now();
    final msgId = const Uuid().v4();
    final payload = messageSigningPayload(
      chatId: chatId,
      msgId: msgId,
      senderId: deviceId,
      senderName: displayName,
      sentAtMs: sentAt.millisecondsSinceEpoch,
      text: text,
    );
    final signature = await identity.sign(payload);
    return ChatMessage(
      chatId: chatId,
      msgId: msgId,
      senderId: deviceId,
      senderName: displayName,
      senderKey: b64(signingKey),
      sentAt: sentAt,
      receivedAt: sentAt,
      text: text,
      signature: b64(signature),
      state: MessageState.pending,
    );
  }
}

class _HostPeer {
  _HostPeer({required this.connectionId, required this.link});

  final String connectionId;
  final Link link;
  HostHandshake? handshake;
  SecureChannel? channel;
  ChatMember? member;
  bool joined = false;
  bool accepted = false;
  bool dropped = false;
  bool syncing = false;
  DateTime lastSeen = DateTime.now();
  Future<void> queue = Future<void>.value();
}

class HostRoomSession extends RoomSession {
  HostRoomSession({
    required super.chatId,
    required super.identity,
    required super.repository,
    required super.transport,
    required super.callbacks,
    required super.displayName,
    required this.info,
    required this.pin,
  });

  final RoomInfo info;
  final String? pin;

  final Map<String, _HostPeer> _peers = {};
  Timer? _timer;
  int _seq = 0;
  bool _closing = false;
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  Future<void> start() async {
    final chat = await repository.loadChat(chatId);
    if (chat == null) {
      throw const AppException('Chat not found');
    }
    _seq = max(chat.lastSeq, await repository.maxSeq(chatId));

    final deviceId = await identity.deviceId;
    await repository.upsertMember(
      ChatMember(
        chatId: chatId,
        deviceId: deviceId,
        name: displayName,
        publicKey: b64(await identity.signingPublicKey),
        isHost: true,
        isOnline: true,
        lastSeen: DateTime.now(),
      ),
    );
    await repository.setStatus(chatId, ChatStatus.live);
    await repository.setAllMembersOffline(chatId);
    await repository.setMemberOnline(chatId, deviceId, true);

    try {
      await transport.startHosting(info);
    } catch (error) {
      await repository.setStatus(chatId, ChatStatus.offline);
      rethrow;
    }
    _live = true;
    _timer = Timer.periodic(Protocol.pingInterval, (_) => _tick());
    await callbacks.onChanged();
  }

  void _tick() {
    if (_closing) return;
    final now = DateTime.now();
    for (final peer in _peers.values.toList()) {
      if (!peer.joined) {
        if (now.difference(peer.lastSeen) > Protocol.handshakeTimeout) {
          _dropPeer(peer, reason: 'Handshake timed out');
        }
        continue;
      }
      if (now.difference(peer.lastSeen) > Protocol.peerTimeout) {
        _dropPeer(peer, reason: 'Member timed out');
        continue;
      }
      unawaited(_sendSecure(peer, FrameType.ping, const {}));
    }
  }

  @override
  Future<void> onConnected(TransportConnected event) async {
    if (_closing || !event.hostSide) return;
    if (_peers.containsKey(event.connectionId)) return;
    final peer = _HostPeer(
      connectionId: event.connectionId,
      link: Link(transport: transport, connectionId: event.connectionId),
    );
    _peers[event.connectionId] = peer;
    peer.link.frames.listen((frame) {
      peer.queue = peer.queue.then((_) async {
        if (peer.dropped || _closing) return;
        try {
          await _handleFrame(peer, frame);
        } catch (error) {
          try {
            await _failPeer(peer, _messageOf(error));
          } catch (_) {
            // Ignore secondary failures.
          }
        }
      });
    });
  }

  @override
  void onData(TransportData event) {
    _peers[event.connectionId]?.link.handleData(event.data);
  }

  @override
  Future<void> onDisconnected(TransportDisconnected event) async {
    final peer = _peers[event.connectionId];
    if (peer != null) {
      await _dropPeer(peer, reason: event.reason);
    }
  }

  Future<void> _handleFrame(_HostPeer peer, Uint8List frameBytes) async {
    if (!peer.joined) {
      final frame = Frame.decode(frameBytes);
      switch (frame.type) {
        case FrameType.hello:
          if (peer.handshake != null) {
            throw const AppException('Duplicate handshake');
          }
          final handshake = await HostHandshake.begin(
            info: info,
            identity: identity,
            pin: pin,
          );
          final ack = await handshake.handleHello(frame.body);
          peer.handshake = handshake;
          peer.lastSeen = DateTime.now();
          await peer.link.sendFrame(ack);
        case FrameType.auth:
          final handshake = peer.handshake;
          if (handshake == null) {
            throw const AppException('Handshake order violation');
          }
          final result = await handshake.handleAuth(frame.body);
          final member = ChatMember(
            chatId: chatId,
            deviceId: result.deviceId,
            name: result.name,
            publicKey: b64(result.signingPublicKey),
            isHost: false,
            isOnline: true,
            lastSeen: DateTime.now(),
          );
          peer
            ..channel = SecureChannel(keys: result.keys, isHost: true)
            ..member = member
            ..joined = true
            ..lastSeen = DateTime.now();
          await repository.upsertMember(member);
          await _sendJoinAccept(peer);
          peer.accepted = true;
          await callbacks.onChanged();
          callbacks.onNotice('${member.name} joined');
          await _broadcastMember(member, 'joined', except: peer);
        case FrameType.plainError:
          await _dropPeer(peer);
        default:
          throw const AppException('Unexpected handshake frame');
      }
      return;
    }

    final channel = peer.channel!;
    final plaintext = await channel.open(frameBytes);
    final frame = Frame.decode(plaintext);
    peer.lastSeen = DateTime.now();

    switch (frame.type) {
      case FrameType.message:
        await _handleMessage(peer, frame.body);
      case FrameType.syncRequest:
        await _handleSync(peer, frame.body);
      case FrameType.ping:
        await _sendSecure(peer, FrameType.pong, const {});
      case FrameType.pong:
        break;
      case FrameType.leave:
        await _dropPeer(peer, reason: 'left');
      case FrameType.error:
        await _dropPeer(peer, reason: frame.body['message'] as String?);
      default:
        throw const AppException('Unsupported frame');
    }
  }

  Future<void> _sendJoinAccept(_HostPeer peer) async {
    final members = await repository.loadMembers(chatId);
    final deviceId = await identity.deviceId;
    final wire = <Map<String, Object?>>[];
    var selfIncluded = false;
    for (final member in members) {
      if (member.deviceId == deviceId) {
        selfIncluded = true;
        wire.add(member.copyWith(isOnline: true).toWire());
      } else {
        wire.add(member.toWire());
      }
    }
    if (!selfIncluded) {
      wire.add(
        ChatMember(
          chatId: chatId,
          deviceId: deviceId,
          name: displayName,
          publicKey: b64(await identity.signingPublicKey),
          isHost: true,
          isOnline: true,
          lastSeen: DateTime.now(),
        ).toWire(),
      );
    }
    await _sendSecure(peer, FrameType.joinAccept, {
      'info': info.toJson(),
      'members': wire,
      'latestSeq': _seq,
    });
  }

  Future<void> _handleMessage(_HostPeer peer, Map<String, Object?> body) async {
    final peerMember = peer.member;
    if (peerMember == null) {
      throw const AppException('Message before join');
    }
    final incoming = ChatMessage.fromWire(body);
    if (incoming.senderId != peerMember.deviceId) {
      throw const AppException('Sender does not match the connection');
    }
    if (!await verifyMessage(incoming)) {
      throw const AppException('Invalid message signature');
    }

    final existing = await repository.messageById(chatId, incoming.msgId);
    if (existing != null) {
      await _sendSecure(peer, FrameType.ack, {
        'msgId': existing.msgId,
        'seq': existing.seq,
      });
      return;
    }

    final seq = ++_seq;
    final message = incoming.copyWith(
      seq: seq,
      state: MessageState.sent,
      receivedAt: DateTime.now(),
    );
    await repository.insertMessage(message);
    await _sendSecure(peer, FrameType.ack, {
      'msgId': message.msgId,
      'seq': seq,
    });
    await _broadcastMessage(message, except: peer);
    await callbacks.onChanged();
  }

  Future<void> _handleSync(_HostPeer peer, Map<String, Object?> body) async {
    if (peer.syncing) return;
    peer.syncing = true;
    try {
      final afterSeq = (body['afterSeq'] as num?)?.toInt() ?? 0;
      var truncated = false;
      if (afterSeq <= 0) {
        final all = await repository.recentMessages(
          chatId,
          limit: Protocol.initialHistoryLimit,
        );
        final sequenced = all.where((message) => message.seq != null).length;
        truncated = _seq > 0 && sequenced < _seq;
        for (
          var start = 0;
          start < all.length;
          start += Protocol.syncPageSize
        ) {
          final end = min(start + Protocol.syncPageSize, all.length);
          final batch = all.sublist(start, end);
          await _sendSecure(peer, FrameType.syncBatch, {
            'messages': batch.map((m) => m.toWire()).toList(),
          });
        }
      } else {
        var cursor = afterSeq;
        while (!_closing) {
          final batch = await repository.messagesAfter(
            chatId,
            cursor,
            limit: Protocol.syncPageSize,
          );
          if (batch.isEmpty) break;
          await _sendSecure(peer, FrameType.syncBatch, {
            'messages': batch.map((m) => m.toWire()).toList(),
          });
          cursor = batch.last.seq ?? cursor;
        }
      }
      await _sendSecure(peer, FrameType.syncDone, {
        'latestSeq': _seq,
        'truncated': truncated,
      });
    } finally {
      peer.syncing = false;
    }
  }

  Future<void> _sendSecure(
    _HostPeer peer,
    int type,
    Map<String, Object?> body,
  ) async {
    final channel = peer.channel;
    if (!peer.joined || channel == null || peer.dropped) return;
    try {
      final frame = Frame(type, body).encode();
      await peer.link.sendFrame(await channel.seal(frame));
    } catch (error) {
      await _dropPeer(peer, reason: _messageOf(error));
    }
  }

  Future<void> _broadcastMessage(
    ChatMessage message, {
    _HostPeer? except,
  }) async {
    for (final peer in _peers.values.toList()) {
      if (peer == except || !peer.accepted) continue;
      await _sendSecure(peer, FrameType.message, message.toWire());
    }
  }

  Future<void> _broadcastMember(
    ChatMember member,
    String event, {
    _HostPeer? except,
  }) async {
    for (final peer in _peers.values.toList()) {
      if (peer == except || !peer.accepted) continue;
      await _sendSecure(peer, FrameType.memberEvent, {
        'event': event,
        'member': member.toWire(),
      });
    }
  }

  Future<void> _failPeer(_HostPeer peer, String message) async {
    if (peer.dropped) return;
    if (!peer.joined) {
      try {
        await peer.link.sendFrame(
          Frame(FrameType.plainError, {'message': message}).encode(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      } catch (_) {
        // Ignore.
      }
    } else {
      await _sendSecure(peer, FrameType.error, {'message': message});
    }
    await _dropPeer(peer, reason: message);
  }

  Future<void> _dropPeer(_HostPeer peer, {String? reason}) async {
    if (peer.dropped) return;
    peer.dropped = true;
    _peers.remove(peer.connectionId);
    final member = peer.member;
    if (peer.joined && member != null) {
      await repository.setMemberOnline(chatId, member.deviceId, false);
      await _broadcastMember(member.copyWith(isOnline: false), 'left');
      callbacks.onNotice('${member.name} left');
      await callbacks.onChanged();
    }
    await peer.link.dispose();
    try {
      await transport.disconnect(peer.connectionId);
    } catch (_) {
      // Ignore.
    }
  }

  @override
  Future<void> sendText(String text) async {
    if (!_live || _closing) {
      throw const AppException('You are offline');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > Protocol.maxTextLength) {
      throw const AppException('Message is too long');
    }
    final message = (await createSignedMessage(trimmed))
        .copyWith(seq: ++_seq, state: MessageState.sent);
    await repository.insertMessage(message);
    await _broadcastMessage(message);
    await callbacks.onChanged();
  }

  @override
  Future<void> close({String? reason, bool deleted = false}) async {
    if (_closing) return;
    _closing = true;
    _live = false;
    _timer?.cancel();
    final peers = _peers.values.toList();
    for (final peer in peers) {
      if (peer.joined) {
        await _sendSecure(peer, FrameType.roomClosed, {
          'reason': deleted ? 'deleted' : 'host_left',
        });
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    for (final peer in peers) {
      peer.dropped = true;
      await peer.link.dispose();
    }
    _peers.clear();
    try {
      await transport.stopHosting();
    } catch (_) {
      // Ignore.
    }
    await repository.setStatus(
      chatId,
      deleted ? ChatStatus.ended : ChatStatus.offline,
    );
    await repository.setAllMembersOffline(chatId);
    callbacks.onClosed(ended: deleted);
    await callbacks.onChanged();
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    for (final peer in _peers.values.toList()) {
      peer.dropped = true;
      await peer.link.dispose();
    }
    _peers.clear();
    try {
      await transport.stopHosting();
    } catch (_) {
      // Ignore.
    }
  }
}

class MemberRoomSession extends RoomSession {
  MemberRoomSession({
    required super.chatId,
    required super.identity,
    required super.repository,
    required super.transport,
    required super.callbacks,
    required super.displayName,
    required this.chat,
    required this.room,
    required this.info,
    required this.pin,
  });

  final Chat chat;
  final DiscoveredRoom room;
  final RoomInfo info;
  final String? pin;

  late Chat _chat = chat;
  final Completer<void> _joined = Completer<void>();
  Link? _link;
  ClientHandshake? _handshake;
  SecureChannel? _channel;
  Timer? _pingTimer;
  Timer? _watchdog;
  Timer? _connectTimeout;
  final Map<String, Timer> _pendingTimers = {};
  DateTime _lastReceived = DateTime.now();
  bool _closing = false;
  bool _joinedOnce = false;
  bool _syncing = false;
  String? _connectionId;
  Future<void> _queue = Future<void>.value();

  @override
  bool get isLive => _joinedOnce && !_closing;

  @override
  Future<void> start() async {
    _connectTimeout = Timer(Protocol.connectionTimeout, () {
      _failBeforeJoin('Could not reach the room');
    });
    try {
      await transport.connect(room);
    } catch (error) {
      _failBeforeJoin(_messageOf(error));
      throw AppException(_messageOf(error));
    }
    await _joined.future;
  }

  bool _failingBeforeJoin = false;

  void _failBeforeJoin(String message) {
    if (_joined.isCompleted || _failingBeforeJoin) return;
    _failingBeforeJoin = true;
    _closing = true;
    _connectTimeout?.cancel();
    _watchdog?.cancel();
    _pingTimer?.cancel();
    final link = _link;
    _link = null;
    if (link != null) {
      unawaited(link.dispose());
    }
    unawaited(() async {
      await _safeDisconnect();
      await _markOffline();
      callbacks.onNotice(message);
      if (!_joined.isCompleted) {
        _joined.completeError(AppException(message));
      }
    }());
  }

  Future<void> _markOffline() async {
    try {
      final existing = await repository.loadChat(chatId);
      if (existing != null) {
        await repository.setStatus(chatId, ChatStatus.offline);
        await repository.setAllMembersOffline(chatId);
      }
    } catch (_) {
      // Ignore.
    }
  }

  Future<void> _safeDisconnect() async {
    final id = _connectionId;
    _connectionId = null;
    if (id == null) return;
    try {
      await transport.disconnect(id);
    } catch (_) {
      // Ignore.
    }
  }

  @override
  Future<void> onConnected(TransportConnected event) async {
    if (_closing || _joinedOnce || event.hostSide) return;
    final remoteInfo = event.roomInfo;
    if (remoteInfo == null) {
      _failBeforeJoin('Room information is unavailable');
      return;
    }
    if (remoteInfo.roomId != chatId) {
      await transport.disconnect(event.connectionId);
      _failBeforeJoin('That room is not the expected chat');
      return;
    }
    if (remoteInfo.hostSigningKey != info.hostSigningKey ||
        remoteInfo.hostDhKey != info.hostDhKey) {
      await transport.disconnect(event.connectionId);
      _failBeforeJoin('Host identity does not match');
      return;
    }

    _connectionId = event.connectionId;
    final link = Link(transport: transport, connectionId: event.connectionId);
    _link = link;
    link.frames.listen((frame) {
      _queue = _queue.then((_) async {
        if (_closing) return;
        try {
          await _handleFrame(frame);
        } catch (error) {
          if (_joinedOnce) {
            _failAfterJoin(_messageOf(error));
          } else {
            _failBeforeJoin(_messageOf(error));
          }
        }
      });
    });

    try {
      final handshake = await ClientHandshake.begin(
        room: remoteInfo,
        identity: identity,
        displayName: displayName,
        pin: pin,
      );
      _handshake = handshake;
      await link.sendFrame(await handshake.buildHello());
    } catch (error) {
      _failBeforeJoin(_messageOf(error));
    }
  }

  Future<void> _handleFrame(Uint8List bytes) async {
    if (_closing) return;
    _lastReceived = DateTime.now();
    final channel = _channel;
    if (channel == null) {
      final frame = Frame.decode(bytes);
      switch (frame.type) {
        case FrameType.helloAck:
          final handshake = _handshake;
          if (handshake == null) {
            throw const AppException('Unexpected handshake response');
          }
          final auth = await handshake.handleHelloAck(frame.body);
          _channel = SecureChannel(keys: handshake.keys, isHost: false);
          await _link!.sendFrame(auth);
        case FrameType.plainError:
          throw AppException(
            frame.body['message'] as String? ?? 'Handshake failed',
          );
        default:
          throw const AppException('Unexpected handshake frame');
      }
      return;
    }

    final plaintext = await channel.open(bytes);
    final frame = Frame.decode(plaintext);
    switch (frame.type) {
      case FrameType.joinAccept:
        await _handleJoinAccept(frame.body);
      case FrameType.message:
        await _handleIncomingMessage(frame.body);
      case FrameType.ack:
        await _handleAck(frame.body);
      case FrameType.syncBatch:
        await _handleSyncBatch(frame.body);
      case FrameType.syncDone:
        await _handleSyncDone(frame.body);
      case FrameType.memberEvent:
        await _handleMemberEvent(frame.body);
      case FrameType.roomClosed:
        await _handleRoomClosed(frame.body);
      case FrameType.ping:
        await _sendSecure(FrameType.pong, const {});
      case FrameType.pong:
        break;
      case FrameType.error:
        await _handleRemoteError(frame.body);
      default:
        throw const AppException('Unsupported frame');
    }
  }

  Future<void> _handleJoinAccept(Map<String, Object?> body) async {
    if (_joinedOnce) return;
    final remote = RoomInfo.fromJson(
      Map<String, Object?>.from(body['info'] as Map),
    );
    if (remote.roomId != chatId ||
        remote.hostSigningKey != info.hostSigningKey) {
      throw const AppException('Room identity changed');
    }
    final members = (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (raw) => ChatMember.fromWire(chatId, Map<String, Object?>.from(raw)),
        )
        .toList();
    _chat = _chat.copyWith(
      name: remote.roomName,
      requiresPin: remote.requiresPin,
      hostId: remote.hostId,
      hostName: remote.hostName,
      hostSigningKey: remote.hostSigningKey,
      hostDhKey: remote.hostDhKey,
      status: ChatStatus.live,
    );
    await repository.saveChat(_chat);
    for (final member in members) {
      await repository.upsertMember(member);
    }

    _joinedOnce = true;
    _connectTimeout?.cancel();
    _pingTimer = Timer.periodic(Protocol.pingInterval, (_) => _tick());
    _syncing = true;
    _watchdog = Timer(const Duration(seconds: 45), () {
      if (_syncing) {
        _failAfterJoin('History sync timed out');
      }
    });

    if (!_joined.isCompleted) _joined.complete();
    await callbacks.onChanged();

    await _sendSecure(FrameType.syncRequest, {'afterSeq': _chat.lastSeq});
  }

  Future<void> _handleIncomingMessage(Map<String, Object?> body) async {
    final message = ChatMessage.fromWire(body);
    if (message.chatId != chatId) {
      throw const AppException('Message belongs to another room');
    }
    if (!await verifyMessage(message)) {
      throw const AppException('Invalid message signature');
    }
    final existing = await repository.messageById(chatId, message.msgId);
    if (existing != null) return;
    await repository.insertMessage(message);
    final seq = message.seq;
    if (seq != null) {
      await repository.bumpLastSeq(chatId, seq);
    }
    await callbacks.onChanged();
  }

  Future<void> _handleAck(Map<String, Object?> body) async {
    final msgId = body['msgId'] as String?;
    final seq = (body['seq'] as num?)?.toInt();
    if (msgId == null || seq == null) return;
    _pendingTimers.remove(msgId)?.cancel();
    await repository.markMessageSent(chatId, msgId, seq, DateTime.now());
    await callbacks.onChanged();
  }

  Future<void> _handleSyncBatch(Map<String, Object?> body) async {
    final rawMessages = body['messages'] as List? ?? const [];
    final valid = <ChatMessage>[];
    var highestSeq = 0;
    for (final raw in rawMessages.whereType<Map>()) {
      try {
        final message = ChatMessage.fromWire(Map<String, Object?>.from(raw));
        if (message.chatId != chatId) continue;
        if (!await verifyMessage(message)) continue;
        valid.add(message);
        final seq = message.seq;
        if (seq != null && seq > highestSeq) highestSeq = seq;
      } catch (_) {
        // Skip malformed messages.
      }
    }
    if (valid.isNotEmpty) {
      await repository.insertMessages(valid);
      if (highestSeq > 0) {
        await repository.bumpLastSeq(chatId, highestSeq);
      }
      await callbacks.onChanged();
    }
  }

  Future<void> _handleSyncDone(Map<String, Object?> body) async {
    final latestSeq = (body['latestSeq'] as num?)?.toInt() ?? 0;
    final truncated = body['truncated'] as bool? ?? false;
    if (latestSeq > 0) {
      await repository.bumpLastSeq(chatId, latestSeq);
    }
    if (truncated) {
      await repository.setHistoryTruncated(chatId, true);
    }
    _syncing = false;
    _watchdog?.cancel();
    await repository.setStatus(chatId, ChatStatus.live);
    await callbacks.onChanged();
  }

  Future<void> _handleMemberEvent(Map<String, Object?> body) async {
    final raw = body['member'];
    if (raw is! Map) return;
    final member = ChatMember.fromWire(chatId, Map<String, Object?>.from(raw));
    final event = body['event'] as String?;
    final updated = member.copyWith(isOnline: event != 'left');
    await repository.upsertMember(updated);
    callbacks.onNotice('${member.name} ${event == 'left' ? 'left' : 'joined'}');
    await callbacks.onChanged();
  }

  Future<void> _handleRoomClosed(Map<String, Object?> body) async {
    final reason = body['reason'] as String?;
    final ended = reason == 'deleted';
    _closing = true;
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _connectTimeout?.cancel();
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    await repository.setStatus(
      chatId,
      ended ? ChatStatus.ended : ChatStatus.offline,
    );
    await repository.setAllMembersOffline(chatId);
    final link = _link;
    _link = null;
    if (link != null) await link.dispose();
    await _safeDisconnect();
    callbacks.onNotice('The host ended the chat');
    callbacks.onClosed(ended: ended);
    await callbacks.onChanged();
  }

  Future<void> _handleRemoteError(Map<String, Object?> body) async {
    final message = body['message'] as String? ?? 'Connection error';
    _failAfterJoin(message);
  }

  void _failAfterJoin(String message) {
    if (_closing) return;
    _closing = true;
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _connectTimeout?.cancel();
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    final link = _link;
    _link = null;
    if (link != null) unawaited(link.dispose());
    unawaited(() async {
      await _safeDisconnect();
      await _markOffline();
      callbacks.onNotice(message);
      callbacks.onClosed(error: message);
    }());
  }

  void _tick() {
    if (_closing) return;
    if (DateTime.now().difference(_lastReceived) > Protocol.peerTimeout) {
      _failAfterJoin('Connection lost');
      return;
    }
    unawaited(_sendSecure(FrameType.ping, const {}));
  }

  Future<void> _sendSecure(
    int type,
    Map<String, Object?> body, {
    bool force = false,
  }) async {
    final channel = _channel;
    final link = _link;
    if (channel == null || link == null || (_closing && !force)) return;
    try {
      final frame = Frame(type, body).encode();
      await link.sendFrame(await channel.seal(frame));
    } catch (error) {
      _failAfterJoin(_messageOf(error));
    }
  }

  @override
  Future<void> sendText(String text) async {
    if (!isLive || _channel == null) {
      throw const AppException('You are offline');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > Protocol.maxTextLength) {
      throw const AppException('Message is too long');
    }
    final message = await createSignedMessage(trimmed);
    await repository.insertMessage(message);
    await _sendSecure(FrameType.message, message.toWire());
    await callbacks.onChanged();
    _pendingTimers[message.msgId]?.cancel();
    _pendingTimers[message.msgId] = Timer(Protocol.sendTimeout, () async {
      _pendingTimers.remove(message.msgId);
      final stored = await repository.messageById(chatId, message.msgId);
      if (stored != null && stored.state == MessageState.pending) {
        await repository.markMessageFailed(chatId, message.msgId);
        await callbacks.onChanged();
      }
    });
  }

  @override
  Future<void> close({String? reason, bool deleted = false}) async {
    if (_closing) return;
    _closing = true;
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _connectTimeout?.cancel();
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    if (_joinedOnce) {
      await _sendSecure(FrameType.leave, {
        'reason': reason ?? 'left',
      }, force: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    final link = _link;
    _link = null;
    if (link != null) await link.dispose();
    await _safeDisconnect();
    await repository.setStatus(
      chatId,
      deleted ? ChatStatus.ended : ChatStatus.offline,
    );
    await repository.setAllMembersOffline(chatId);
    if (!_joined.isCompleted) {
      _joined.completeError(const AppException('Join cancelled'));
    }
    callbacks.onClosed(ended: deleted);
    await callbacks.onChanged();
  }

  @override
  Future<void> onDisconnected(TransportDisconnected event) async {
    if (_closing) return;
    if (_connectionId != null && event.connectionId != _connectionId) return;
    if (!_joinedOnce) {
      _failBeforeJoin('Connection lost');
    } else {
      _failAfterJoin('Connection lost');
    }
  }

  @override
  void onData(TransportData event) {
    if (_connectionId != null && event.connectionId != _connectionId) return;
    _link?.handleData(event.data);
  }

  @override
  Future<void> dispose() async {
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _connectTimeout?.cancel();
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    final link = _link;
    _link = null;
    if (link != null) await link.dispose();
    await _safeDisconnect();
  }
}

String _messageOf(Object error) {
  if (error is AppException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
