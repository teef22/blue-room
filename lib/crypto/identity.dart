import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../data/local_store.dart';
import '../util/bytes.dart';

/// Long-lived device identity. The signing key authenticates messages, the
/// Diffie-Hellman key is used during the session handshake.
class DeviceIdentity {
  DeviceIdentity._(this.signingKeyPair, this.dhKeyPair);

  final SimpleKeyPair signingKeyPair;
  final SimpleKeyPair dhKeyPair;

  static Future<DeviceIdentity> generate() async {
    final signing = await Ed25519().newKeyPair();
    final dh = await X25519().newKeyPair();
    return DeviceIdentity._(signing, dh);
  }

  static Future<DeviceIdentity> fromSeeds(
    Uint8List signingSeed,
    Uint8List dhSeed,
  ) async {
    final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
    final dh = await X25519().newKeyPairFromSeed(dhSeed);
    return DeviceIdentity._(signing, dh);
  }

  Future<Uint8List> get signingPublicKey => _publicBytes(signingKeyPair);
  Future<Uint8List> get dhPublicKey => _publicBytes(dhKeyPair);

  String? _cachedDeviceId;

  Future<String> get deviceId async {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;
    final id = deviceIdFor(await signingPublicKey);
    _cachedDeviceId = id;
    return id;
  }

  Future<Uint8List> sign(List<int> message) async {
    final signature = await Ed25519().sign(message, keyPair: signingKeyPair);
    return Uint8List.fromList(signature.bytes);
  }

  Future<Uint8List> extractSigningSeed() async =>
      Uint8List.fromList((await signingKeyPair.extract()).bytes);

  Future<Uint8List> extractDhSeed() async =>
      Uint8List.fromList((await dhKeyPair.extract()).bytes);

  static Future<Uint8List> _publicBytes(SimpleKeyPair pair) async {
    final publicKey = await pair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  static Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    try {
      return await Ed25519().verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<DeviceIdentity> loadOrCreate(LocalStore store) async {
    final signingSeed = await store.readSecret('identity.signing_seed');
    final dhSeed = await store.readSecret('identity.dh_seed');
    if (signingSeed != null && dhSeed != null) {
      try {
        return await fromSeeds(unb64(signingSeed), unb64(dhSeed));
      } catch (_) {
        // Corrupted keys: fall through and regenerate.
      }
    }
    final identity = await generate();
    await store.writeSecret(
      'identity.signing_seed',
      b64(await identity.extractSigningSeed()),
    );
    await store.writeSecret(
      'identity.dh_seed',
      b64(await identity.extractDhSeed()),
    );
    return identity;
  }
}
