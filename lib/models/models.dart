import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../util/bytes.dart';

enum ChatRole { host, member }

enum ChatStatus { live, offline, ended }

enum MessageState { pending, sent, failed }

class AppException implements Exception {
  const AppException(this.message);

  final String message;

  @override
  String toString() => message;
}

@immutable
class RoomInfo {
  const RoomInfo({
    required this.roomId,
    required this.roomName,
    required this.hostId,
    required this.hostName,
    required this.hostSigningKey,
    required this.hostDhKey,
    required this.requiresPin,
    this.version = 1,
  });

  final String roomId;
  final String roomName;
  final String hostId;
  final String hostName;
  final String hostSigningKey;
  final String hostDhKey;
  final bool requiresPin;
  final int version;

  String get fingerprint => fingerprintFor(unb64(hostSigningKey));

  /// Compact binary form used by the BLE INFO characteristic. A single ATT
  /// read must carry this value, so keep it well under the smallest useful MTU
  /// (~180 bytes after negotiation). The larger JSON form is only used inside
  /// encrypted protocol frames.
  static const int binaryFormatVersion = 1;
  static const int _nameLimit = 32;

  Uint8List toBytes() {
    final roomNameBytes = _truncateUtf8(roomName, _nameLimit);
    final hostNameBytes = _truncateUtf8(hostName, _nameLimit);
    final builder = BytesBuilder(copy: false)
      ..addByte(binaryFormatVersion)
      ..addByte(version & 0xff)
      ..addByte(requiresPin ? 1 : 0)
      ..add(fromHex(roomId))
      ..add(unb64(hostSigningKey))
      ..add(unb64(hostDhKey))
      ..addByte(roomNameBytes.length)
      ..add(roomNameBytes)
      ..addByte(hostNameBytes.length)
      ..add(hostNameBytes);
    return builder.toBytes();
  }

  factory RoomInfo.fromBytes(List<int> bytes) {
    if (bytes.length < 74) {
      throw const AppException('Room information is truncated');
    }
    final data = Uint8List.fromList(bytes);
    if (data[0] != binaryFormatVersion) {
      throw const AppException('Unsupported room information format');
    }
    final protocolVersion = data[1];
    final flags = data[2];
    final roomId = hex(data.sublist(3, 9));
    final signingKey = data.sublist(9, 41);
    final dhKey = data.sublist(41, 73);
    var offset = 73;
    final roomNameLength = data[offset++];
    if (offset + roomNameLength > data.length) {
      throw const AppException('Room information is truncated');
    }
    final roomName = utf8.decode(
      data.sublist(offset, offset + roomNameLength),
      allowMalformed: true,
    );
    offset += roomNameLength;
    if (offset >= data.length) {
      throw const AppException('Room information is truncated');
    }
    final hostNameLength = data[offset++];
    if (offset + hostNameLength > data.length) {
      throw const AppException('Room information is truncated');
    }
    final hostName = utf8.decode(
      data.sublist(offset, offset + hostNameLength),
      allowMalformed: true,
    );
    return RoomInfo(
      version: protocolVersion,
      roomId: roomId,
      roomName: roomName,
      hostId: deviceIdFor(signingKey),
      hostName: hostName,
      hostSigningKey: b64(signingKey),
      hostDhKey: b64(dhKey),
      requiresPin: flags & 1 == 1,
    );
  }

  static Uint8List _truncateUtf8(String value, int limit) {
    final bytes = utf8.encode(value.trim());
    if (bytes.length <= limit) return Uint8List.fromList(bytes);
    // Cut on a rune boundary so the peer never receives half a character.
    final buffer = StringBuffer();
    var used = 0;
    for (final rune in value.trim().runes) {
      final encoded = utf8.encode(String.fromCharCode(rune)).length;
      if (used + encoded > limit) break;
      buffer.writeCharCode(rune);
      used += encoded;
    }
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'roomId': roomId,
    'roomName': roomName,
    'hostId': hostId,
    'hostName': hostName,
    'hostSign': hostSigningKey,
    'hostDh': hostDhKey,
    'pin': requiresPin,
  };

  factory RoomInfo.fromJson(Map<String, Object?> json) => RoomInfo(
    version: (json['v'] as num?)?.toInt() ?? 1,
    roomId: json['roomId'] as String,
    roomName: json['roomName'] as String,
    hostId: json['hostId'] as String,
    hostName: json['hostName'] as String,
    hostSigningKey: json['hostSign'] as String,
    hostDhKey: json['hostDh'] as String,
    requiresPin: json['pin'] as bool? ?? false,
  );
}

@immutable
class DiscoveredRoom {
  const DiscoveredRoom({
    required this.peripheralId,
    required this.displayName,
    required this.rssi,
    required this.lastSeen,
    this.roomId,
    this.requiresPin,
  });

  final String peripheralId;
  final String displayName;
  final String? roomId;
  final int rssi;
  final DateTime lastSeen;
  final bool? requiresPin;

  bool get isStale =>
      DateTime.now().difference(lastSeen) > Protocol.scanStaleAfter;

  DiscoveredRoom copyWith({
    String? displayName,
    String? roomId,
    int? rssi,
    DateTime? lastSeen,
    bool? requiresPin,
  }) => DiscoveredRoom(
    peripheralId: peripheralId,
    displayName: displayName ?? this.displayName,
    roomId: roomId ?? this.roomId,
    rssi: rssi ?? this.rssi,
    lastSeen: lastSeen ?? this.lastSeen,
    requiresPin: requiresPin ?? this.requiresPin,
  );
}

@immutable
class Chat {
  const Chat({
    required this.id,
    required this.name,
    required this.role,
    required this.requiresPin,
    required this.hostId,
    required this.hostName,
    required this.hostSigningKey,
    required this.hostDhKey,
    required this.createdAt,
    required this.status,
    this.lastSeq = 0,
    this.lastReadSeq = 0,
    this.lastMessageText,
    this.lastMessageAt,
    this.historyTruncated = false,
    this.unread = 0,
  });

  final String id;
  final String name;
  final ChatRole role;
  final bool requiresPin;
  final String hostId;
  final String hostName;
  final String hostSigningKey;
  final String hostDhKey;
  final DateTime createdAt;
  final ChatStatus status;
  final int lastSeq;
  final int lastReadSeq;
  final String? lastMessageText;
  final DateTime? lastMessageAt;
  final bool historyTruncated;

  /// Computed by the repository, not stored on the chat row.
  final int unread;

  bool get isHost => role == ChatRole.host;
  bool get isLive => status == ChatStatus.live;

  /// Short human-verifiable host fingerprint.
  String get fingerprint => fingerprintFor(unb64(hostSigningKey));

  int get unreadCount => unread;

  Chat copyWith({
    String? name,
    bool? requiresPin,
    String? hostId,
    String? hostName,
    String? hostSigningKey,
    String? hostDhKey,
    ChatStatus? status,
    int? lastSeq,
    int? lastReadSeq,
    String? lastMessageText,
    DateTime? lastMessageAt,
    bool? historyTruncated,
    int? unread,
  }) => Chat(
    id: id,
    name: name ?? this.name,
    role: role,
    requiresPin: requiresPin ?? this.requiresPin,
    hostId: hostId ?? this.hostId,
    hostName: hostName ?? this.hostName,
    hostSigningKey: hostSigningKey ?? this.hostSigningKey,
    hostDhKey: hostDhKey ?? this.hostDhKey,
    createdAt: createdAt,
    status: status ?? this.status,
    lastSeq: lastSeq ?? this.lastSeq,
    lastReadSeq: lastReadSeq ?? this.lastReadSeq,
    lastMessageText: lastMessageText ?? this.lastMessageText,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    historyTruncated: historyTruncated ?? this.historyTruncated,
    unread: unread ?? this.unread,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'role': role.index,
    'requires_pin': requiresPin ? 1 : 0,
    'host_id': hostId,
    'host_name': hostName,
    'host_signing_key': hostSigningKey,
    'host_dh_key': hostDhKey,
    'created_at': createdAt.millisecondsSinceEpoch,
    'status': status.index,
    'last_seq': lastSeq,
    'last_read_seq': lastReadSeq,
    'last_message_text': lastMessageText,
    'last_message_at': lastMessageAt?.millisecondsSinceEpoch,
    'history_truncated': historyTruncated ? 1 : 0,
  };

  factory Chat.fromRow(Map<String, Object?> row) => Chat(
    id: row['id'] as String,
    name: row['name'] as String,
    role: ChatRole.values[(row['role'] as num).toInt()],
    requiresPin: (row['requires_pin'] as num).toInt() == 1,
    hostId: row['host_id'] as String,
    hostName: row['host_name'] as String,
    hostSigningKey: row['host_signing_key'] as String,
    hostDhKey: row['host_dh_key'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (row['created_at'] as num).toInt(),
    ),
    status: ChatStatus.values[(row['status'] as num).toInt()],
    lastSeq: (row['last_seq'] as num?)?.toInt() ?? 0,
    lastReadSeq: (row['last_read_seq'] as num?)?.toInt() ?? 0,
    lastMessageText: row['last_message_text'] as String?,
    lastMessageAt: row['last_message_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (row['last_message_at'] as num).toInt(),
          ),
    historyTruncated: (row['history_truncated'] as num?)?.toInt() == 1,
  );
}

@immutable
class ChatMessage {
  const ChatMessage({
    required this.chatId,
    required this.msgId,
    required this.senderId,
    required this.senderName,
    required this.senderKey,
    required this.sentAt,
    required this.receivedAt,
    required this.text,
    required this.signature,
    required this.state,
    this.seq,
  });

  final String chatId;
  final String msgId;
  final int? seq;
  final String senderId;
  final String senderName;
  final String senderKey;
  final DateTime sentAt;
  final DateTime receivedAt;
  final String text;
  final String signature;
  final MessageState state;

  ChatMessage copyWith({int? seq, MessageState? state, DateTime? receivedAt}) =>
      ChatMessage(
        chatId: chatId,
        msgId: msgId,
        seq: seq ?? this.seq,
        senderId: senderId,
        senderName: senderName,
        senderKey: senderKey,
        sentAt: sentAt,
        receivedAt: receivedAt ?? this.receivedAt,
        text: text,
        signature: signature,
        state: state ?? this.state,
      );

  Map<String, Object?> toRow() => {
    'chat_id': chatId,
    'msg_id': msgId,
    'seq': seq,
    'sender_id': senderId,
    'sender_name': senderName,
    'sender_key': senderKey,
    'sent_at': sentAt.millisecondsSinceEpoch,
    'received_at': receivedAt.millisecondsSinceEpoch,
    'text': text,
    'signature': signature,
    'state': state.index,
  };

  factory ChatMessage.fromRow(Map<String, Object?> row) => ChatMessage(
    chatId: row['chat_id'] as String,
    msgId: row['msg_id'] as String,
    seq: (row['seq'] as num?)?.toInt(),
    senderId: row['sender_id'] as String,
    senderName: row['sender_name'] as String,
    senderKey: row['sender_key'] as String,
    sentAt: DateTime.fromMillisecondsSinceEpoch(
      (row['sent_at'] as num).toInt(),
    ),
    receivedAt: DateTime.fromMillisecondsSinceEpoch(
      (row['received_at'] as num).toInt(),
    ),
    text: row['text'] as String,
    signature: row['signature'] as String,
    state: MessageState.values[(row['state'] as num).toInt()],
  );

  Map<String, Object?> toWire() => {
    'chatId': chatId,
    'msgId': msgId,
    'seq': seq,
    'senderId': senderId,
    'senderName': senderName,
    'senderKey': senderKey,
    'sentAt': sentAt.millisecondsSinceEpoch,
    'text': text,
    'signature': signature,
  };

  factory ChatMessage.fromWire(Map<String, Object?> json) => ChatMessage(
    chatId: json['chatId'] as String,
    msgId: json['msgId'] as String,
    seq: (json['seq'] as num?)?.toInt(),
    senderId: json['senderId'] as String,
    senderName: json['senderName'] as String,
    senderKey: json['senderKey'] as String,
    sentAt: DateTime.fromMillisecondsSinceEpoch(
      (json['sentAt'] as num).toInt(),
    ),
    receivedAt: DateTime.now(),
    text: json['text'] as String,
    signature: json['signature'] as String,
    state: MessageState.sent,
  );
}

@immutable
class ChatMember {
  const ChatMember({
    required this.chatId,
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.isHost,
    required this.isOnline,
    required this.lastSeen,
  });

  final String chatId;
  final String deviceId;
  final String name;
  final String publicKey;
  final bool isHost;
  final bool isOnline;
  final DateTime lastSeen;

  ChatMember copyWith({bool? isOnline, String? name, DateTime? lastSeen}) =>
      ChatMember(
        chatId: chatId,
        deviceId: deviceId,
        name: name ?? this.name,
        publicKey: publicKey,
        isHost: isHost,
        isOnline: isOnline ?? this.isOnline,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, Object?> toRow() => {
    'chat_id': chatId,
    'device_id': deviceId,
    'name': name,
    'public_key': publicKey,
    'is_host': isHost ? 1 : 0,
    'is_online': isOnline ? 1 : 0,
    'last_seen': lastSeen.millisecondsSinceEpoch,
  };

  factory ChatMember.fromRow(Map<String, Object?> row) => ChatMember(
    chatId: row['chat_id'] as String,
    deviceId: row['device_id'] as String,
    name: row['name'] as String,
    publicKey: row['public_key'] as String,
    isHost: (row['is_host'] as num).toInt() == 1,
    isOnline: (row['is_online'] as num).toInt() == 1,
    lastSeen: DateTime.fromMillisecondsSinceEpoch(
      (row['last_seen'] as num).toInt(),
    ),
  );

  Map<String, Object?> toWire() => {
    'deviceId': deviceId,
    'name': name,
    'publicKey': publicKey,
    'isHost': isHost,
    'online': isOnline,
  };

  factory ChatMember.fromWire(String chatId, Map<String, Object?> json) =>
      ChatMember(
        chatId: chatId,
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        publicKey: json['publicKey'] as String,
        isHost: json['isHost'] as bool? ?? false,
        isOnline: json['online'] as bool? ?? true,
        lastSeen: DateTime.now(),
      );
}
