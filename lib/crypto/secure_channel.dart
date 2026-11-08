import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/models.dart';

class SecureChannelKeys {
  const SecureChannelKeys({
    required this.clientToHost,
    required this.hostToClient,
    required this.sessionId,
  });

  final Uint8List clientToHost;
  final Uint8List hostToClient;
  final Uint8List sessionId;
}

/// Encrypts protocol frames with ChaCha20-Poly1305 using deterministic,
/// strictly increasing counter nonces. A new key pair (and counter) is created
/// for every BLE connection, so counters never collide.
class SecureChannel {
  SecureChannel({required SecureChannelKeys keys, required bool isHost})
    : _sendKey = isHost ? keys.hostToClient : keys.clientToHost,
      _recvKey = isHost ? keys.clientToHost : keys.hostToClient,
      _sessionId = keys.sessionId;

  final Uint8List _sendKey;
  final Uint8List _recvKey;
  final Uint8List _sessionId;

  int _sendCounter = 0;
  int _recvCounter = 0;

  static final Chacha20 _cipher = Chacha20.poly1305Aead();

  Future<Uint8List> seal(Uint8List plaintext) async {
    final counter = _sendCounter++;
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(_sendKey),
      nonce: nonceFor(counter),
      aad: _sessionId,
    );
    final result = Uint8List(8 + box.cipherText.length + box.mac.bytes.length);
    ByteData.view(result.buffer, 0, 8).setUint64(0, counter);
    result.setAll(8, box.cipherText);
    result.setAll(8 + box.cipherText.length, box.mac.bytes);
    return result;
  }

  Future<Uint8List> open(Uint8List wire) async {
    if (wire.length < 8 + 16) {
      throw const AppException('Malformed encrypted frame');
    }
    final counter = ByteData.sublistView(wire, 0, 8).getUint64(0);
    if (counter != _recvCounter) {
      throw const AppException('Replay or out-of-order frame rejected');
    }
    final cipherLength = wire.length - 8 - 16;
    final box = SecretBox(
      wire.sublist(8, 8 + cipherLength),
      nonce: nonceFor(counter),
      mac: Mac(wire.sublist(8 + cipherLength)),
    );
    final plaintext = await _cipher.decrypt(
      box,
      secretKey: SecretKey(_recvKey),
      aad: _sessionId,
    );
    _recvCounter++;
    return Uint8List.fromList(plaintext);
  }

  static Uint8List nonceFor(int counter) {
    final nonce = Uint8List(12);
    ByteData.view(nonce.buffer).setUint64(4, counter);
    return nonce;
  }
}
