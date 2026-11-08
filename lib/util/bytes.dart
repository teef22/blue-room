import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as sha;

/// Base64 (standard, padded) encoding helpers.
String b64(List<int> bytes) => base64.encode(bytes);

Uint8List unb64(String value) => base64.decode(value);

/// URL-safe base64 without padding.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64url(String value) {
  final padded = value.padRight((value.length + 3) & ~3, '=');
  return base64Url.decode(padded);
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String value) {
  final result = Uint8List(value.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Stable identity of a device derived from its Ed25519 public key.
String deviceIdFor(List<int> signingPublicKey) =>
    b64url(sha.sha256.convert(signingPublicKey).bytes.sublist(0, 8));

/// Short human-verifiable fingerprint, e.g. `A1B2-C3D4`.
String fingerprintFor(List<int> publicKey) {
  final digest = sha.sha256.convert(publicKey).bytes;
  final value = hex(digest.sublist(0, 4)).toUpperCase();
  return '${value.substring(0, 4)}-${value.substring(4)}';
}

/// 12 hex character room code (48 bits of entropy).
String generateRoomId() => hex(randomBytes(6));

/// Room names are advertised in a BLE packet, so keep them short. The limit is
/// measured in UTF-8 bytes to fit the legacy 31-byte advertisement (and its
/// scan response) regardless of the characters used.
String shortRoomName(String name) {
  final trimmed = name.trim();
  if (utf8.encode(trimmed).length <= 10) return trimmed;
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in trimmed.runes) {
    final encoded = utf8.encode(String.fromCharCode(rune)).length;
    // Reserve 3 bytes for the ellipsis.
    if (bytes + encoded > 7) break;
    buffer.writeCharCode(rune);
    bytes += encoded;
  }
  return '${buffer.toString()}…';
}

/// Appends a length-prefixed UTF-8 string to [builder].
void addSizedString(BytesBuilder builder, String value) {
  final bytes = utf8.encode(value);
  final header = ByteData(4)..setUint32(0, bytes.length);
  builder.add(header.buffer.asUint8List());
  builder.add(bytes);
}

Uint8List messageSigningPayload({
  required String chatId,
  required String msgId,
  required String senderId,
  required String senderName,
  required int sentAtMs,
  required String text,
}) {
  final builder = BytesBuilder(copy: false)
    ..add(utf8.encode('blue_room/message/v1'));
  addSizedString(builder, chatId);
  addSizedString(builder, msgId);
  addSizedString(builder, senderId);
  addSizedString(builder, senderName);
  final time = ByteData(8)..setUint64(0, sentAtMs);
  builder.add(time.buffer.asUint8List());
  addSizedString(builder, text);
  return builder.toBytes();
}

/// Constant-time-ish byte comparison.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
