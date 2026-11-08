// Private fields cannot be named parameters, so the handshake constructors
// assign them in initializer lists.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as sha;
import 'package:cryptography/cryptography.dart';

import '../models/models.dart';
import '../protocol/frames.dart';
import '../util/bytes.dart';
import 'identity.dart';
import 'secure_channel.dart';

const _hsDomain = 'blue_room/handshake/v1';

Uint8List _hashParts(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return Uint8List.fromList(sha.sha256.convert(builder.toBytes()).bytes);
}

Uint8List _sized(String value) {
  final builder = BytesBuilder(copy: false);
  addSizedString(builder, value);
  return builder.toBytes();
}

Uint8List _concat(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

Uint8List _pinDigest(String roomId, String? pin) {
  if (pin == null || pin.isEmpty) return Uint8List(0);
  return _hashParts([
    utf8.encode('blue_room/pin/v1'),
    _sized(roomId),
    _sized(pin),
  ]);
}

Future<Uint8List> _pinProof(String? pin, Uint8List transcript) async {
  if (pin == null || pin.isEmpty) return Uint8List(0);
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(pin),
    secretKey: SecretKey(transcript),
  );
  return Uint8List.fromList(mac.bytes);
}

Future<SecureChannelKeys> _deriveKeys({
  required Uint8List dhSecret,
  required Uint8List transcript,
  required String roomId,
  required String? pin,
}) async {
  final salt = _hashParts([
    utf8.encode('blue_room/hkdf/v1'),
    transcript,
    _pinDigest(roomId, pin),
  ]);
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(dhSecret),
    nonce: salt,
    info: utf8.encode('blue_room/session/v1'),
  );
  final bytes = await derived.extractBytes();
  final sessionId = _hashParts([
    utf8.encode('blue_room/sessionid/v1'),
    transcript,
    dhSecret,
  ]).sublist(0, 16);
  return SecureChannelKeys(
    clientToHost: Uint8List.fromList(bytes.sublist(0, 32)),
    hostToClient: Uint8List.fromList(bytes.sublist(32)),
    sessionId: sessionId,
  );
}

/// Client side of the ephemeral X25519 + Ed25519-signed handshake.
class ClientHandshake {
  ClientHandshake._({
    required this.room,
    required this.identity,
    required this.displayName,
    required this.pin,
    required SimpleKeyPair ephemeral,
    required Uint8List ephemeralPublic,
    required Uint8List nonce,
  }) : _ephemeral = ephemeral,
       _ephemeralPublic = ephemeralPublic,
       _nonce = nonce;

  final RoomInfo room;
  final DeviceIdentity identity;
  final String displayName;
  final String? pin;

  final SimpleKeyPair _ephemeral;
  final Uint8List _ephemeralPublic;
  final Uint8List _nonce;

  Uint8List? _th1;
  SecureChannelKeys? _keys;

  SecureChannelKeys get keys {
    final keys = _keys;
    if (keys == null) {
      throw const AppException('Handshake is not complete');
    }
    return keys;
  }

  static Future<ClientHandshake> begin({
    required RoomInfo room,
    required DeviceIdentity identity,
    required String displayName,
    String? pin,
  }) async {
    final ephemeral = await X25519().newKeyPair();
    final publicKey = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    return ClientHandshake._(
      room: room,
      identity: identity,
      displayName: displayName,
      pin: pin,
      ephemeral: ephemeral,
      ephemeralPublic: publicKey,
      nonce: randomBytes(16),
    );
  }

  Future<Uint8List> buildHello() async {
    _th1 = _hashParts([
      utf8.encode('$_hsDomain/hello'),
      _sized(room.roomId),
      _ephemeralPublic,
      _nonce,
    ]);
    return Frame(FrameType.hello, {
      'v': 1,
      'roomId': room.roomId,
      'eph': b64(_ephemeralPublic),
      'nonce': b64(_nonce),
    }).encode();
  }

  Future<Uint8List> handleHelloAck(Map<String, Object?> body) async {
    final th1 = _th1;
    if (th1 == null) {
      throw const AppException('Unexpected handshake response');
    }
    final remoteEph = unb64(body['eph'] as String);
    final remoteNonce = unb64(body['nonce'] as String);
    final hostSigningKey = unb64(body['hostSign'] as String);
    final hostDhKey = unb64(body['hostDh'] as String);
    final signature = unb64(body['sig'] as String);

    if (!constantTimeEquals(hostSigningKey, unb64(room.hostSigningKey)) ||
        !constantTimeEquals(hostDhKey, unb64(room.hostDhKey))) {
      throw const AppException('Host identity changed during handshake');
    }
    if (remoteEph.length != 32 || remoteNonce.length < 8) {
      throw const AppException('Malformed host handshake');
    }

    final ackPayload = _concat([
      utf8.encode('$_hsDomain/ack'),
      th1,
      remoteEph,
      remoteNonce,
      hostSigningKey,
      hostDhKey,
    ]);
    final hostVerified = await DeviceIdentity.verify(
      message: ackPayload,
      signature: signature,
      publicKey: hostSigningKey,
    );
    if (!hostVerified) {
      throw const AppException('Host signature verification failed');
    }

    final th2 = _hashParts([
      utf8.encode('$_hsDomain/transcript2'),
      th1,
      remoteEph,
      remoteNonce,
    ]);

    final signingPublicKey = await identity.signingPublicKey;
    final dhPublicKey = await identity.dhPublicKey;
    final proof = await _pinProof(pin, th2);

    final authPayload = _concat([
      utf8.encode('$_hsDomain/auth'),
      th2,
      _sized(displayName),
      signingPublicKey,
      dhPublicKey,
      proof,
    ]);
    final authSignature = await identity.sign(authPayload);

    final th3 = _hashParts([
      utf8.encode('$_hsDomain/transcript3'),
      th2,
      signingPublicKey,
      dhPublicKey,
      _sized(displayName),
    ]);

    final shared = await X25519().sharedSecretKey(
      keyPair: _ephemeral,
      remotePublicKey: SimplePublicKey(remoteEph, type: KeyPairType.x25519),
    );
    final dhSecret = Uint8List.fromList(await shared.extractBytes());
    _keys = await _deriveKeys(
      dhSecret: dhSecret,
      transcript: th3,
      roomId: room.roomId,
      pin: pin,
    );

    return Frame(FrameType.auth, {
      'name': displayName,
      'deviceId': await identity.deviceId,
      'signPub': b64(signingPublicKey),
      'dhPub': b64(dhPublicKey),
      'pinProof': b64(proof),
      'sig': b64(authSignature),
    }).encode();
  }
}

class HostAuthResult {
  const HostAuthResult({
    required this.deviceId,
    required this.name,
    required this.signingPublicKey,
    required this.dhPublicKey,
    required this.keys,
  });

  final String deviceId;
  final String name;
  final Uint8List signingPublicKey;
  final Uint8List dhPublicKey;
  final SecureChannelKeys keys;
}

/// Host side of the handshake. One instance per connected central.
class HostHandshake {
  HostHandshake._({
    required this.info,
    required this.identity,
    required this.pin,
    required SimpleKeyPair ephemeral,
    required Uint8List ephemeralPublic,
    required Uint8List nonce,
  }) : _ephemeral = ephemeral,
       _ephemeralPublic = ephemeralPublic,
       _nonce = nonce;

  final RoomInfo info;
  final DeviceIdentity identity;
  final String? pin;

  final SimpleKeyPair _ephemeral;
  final Uint8List _ephemeralPublic;
  final Uint8List _nonce;

  Uint8List? _th2;
  Uint8List? _remoteEph;

  static Future<HostHandshake> begin({
    required RoomInfo info,
    required DeviceIdentity identity,
    String? pin,
  }) async {
    final ephemeral = await X25519().newKeyPair();
    final publicKey = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    return HostHandshake._(
      info: info,
      identity: identity,
      pin: pin,
      ephemeral: ephemeral,
      ephemeralPublic: publicKey,
      nonce: randomBytes(16),
    );
  }

  Future<Uint8List> handleHello(Map<String, Object?> body) async {
    if ((body['v'] as num?)?.toInt() != 1) {
      throw const AppException('Unsupported protocol version');
    }
    if (body['roomId'] != info.roomId) {
      throw const AppException('This device is not hosting that room');
    }
    final remoteEph = unb64(body['eph'] as String);
    final remoteNonce = unb64(body['nonce'] as String);
    if (remoteEph.length != 32 || remoteNonce.length < 8) {
      throw const AppException('Malformed client handshake');
    }
    _remoteEph = remoteEph;

    final th1 = _hashParts([
      utf8.encode('$_hsDomain/hello'),
      _sized(info.roomId),
      remoteEph,
      remoteNonce,
    ]);
    final hostSigningKey = await identity.signingPublicKey;
    final hostDhKey = await identity.dhPublicKey;
    final ackPayload = _concat([
      utf8.encode('$_hsDomain/ack'),
      th1,
      _ephemeralPublic,
      _nonce,
      hostSigningKey,
      hostDhKey,
    ]);
    final signature = await identity.sign(ackPayload);

    final th2 = _hashParts([
      utf8.encode('$_hsDomain/transcript2'),
      th1,
      _ephemeralPublic,
      _nonce,
    ]);
    _th2 = th2;

    return Frame(FrameType.helloAck, {
      'v': 1,
      'eph': b64(_ephemeralPublic),
      'nonce': b64(_nonce),
      'hostSign': b64(hostSigningKey),
      'hostDh': b64(hostDhKey),
      'sig': b64(signature),
    }).encode();
  }

  Future<HostAuthResult> handleAuth(Map<String, Object?> body) async {
    final th2 = _th2;
    final remoteEph = _remoteEph;
    if (th2 == null || remoteEph == null) {
      throw const AppException('Unexpected handshake message');
    }

    final name = (body['name'] as String?)?.trim();
    if (name == null || name.isEmpty || name.length > 48) {
      throw const AppException('Invalid display name');
    }
    final signingPublicKey = unb64(body['signPub'] as String);
    final dhPublicKey = unb64(body['dhPub'] as String);
    final proof = unb64(body['pinProof'] as String);
    final signature = unb64(body['sig'] as String);

    if (signingPublicKey.length != 32 || dhPublicKey.length != 32) {
      throw const AppException('Invalid identity key');
    }
    final derivedId = deviceIdFor(signingPublicKey);
    if (body['deviceId'] != derivedId) {
      throw const AppException('Device identity mismatch');
    }

    if (info.requiresPin) {
      final expected = await _pinProof(pin, th2);
      if (expected.isEmpty || !constantTimeEquals(expected, proof)) {
        throw const AppException('Wrong PIN');
      }
    }

    final authPayload = _concat([
      utf8.encode('$_hsDomain/auth'),
      th2,
      _sized(name),
      signingPublicKey,
      dhPublicKey,
      proof,
    ]);
    final valid = await DeviceIdentity.verify(
      message: authPayload,
      signature: signature,
      publicKey: signingPublicKey,
    );
    if (!valid) {
      throw const AppException('Client signature verification failed');
    }

    final th3 = _hashParts([
      utf8.encode('$_hsDomain/transcript3'),
      th2,
      signingPublicKey,
      dhPublicKey,
      _sized(name),
    ]);
    final shared = await X25519().sharedSecretKey(
      keyPair: _ephemeral,
      remotePublicKey: SimplePublicKey(remoteEph, type: KeyPairType.x25519),
    );
    final dhSecret = Uint8List.fromList(await shared.extractBytes());
    final keys = await _deriveKeys(
      dhSecret: dhSecret,
      transcript: th3,
      roomId: info.roomId,
      pin: pin,
    );

    return HostAuthResult(
      deviceId: derivedId,
      name: name,
      signingPublicKey: signingPublicKey,
      dhPublicKey: dhPublicKey,
      keys: keys,
    );
  }
}
