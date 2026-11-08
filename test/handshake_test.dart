import 'dart:typed_data';

import 'package:blue_room/crypto/handshake.dart';
import 'package:blue_room/crypto/identity.dart';
import 'package:blue_room/crypto/secure_channel.dart';
import 'package:blue_room/models/models.dart';
import 'package:blue_room/protocol/frames.dart';
import 'package:blue_room/util/bytes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DeviceIdentity hostIdentity;
  late RoomInfo room;

  setUp(() async {
    hostIdentity = await DeviceIdentity.generate();
    room = RoomInfo(
      roomId: generateRoomId(),
      roomName: 'Test room',
      hostId: await hostIdentity.deviceId,
      hostName: 'Host',
      hostSigningKey: b64(await hostIdentity.signingPublicKey),
      hostDhKey: b64(await hostIdentity.dhPublicKey),
      requiresPin: false,
    );
  });

  test('handshake derives matching keys and channels interoperate', () async {
    final clientIdentity = await DeviceIdentity.generate();
    final hostHandshake = await HostHandshake.begin(
      info: room,
      identity: hostIdentity,
    );
    final clientHandshake = await ClientHandshake.begin(
      room: room,
      identity: clientIdentity,
      displayName: 'Guest',
    );

    final hello = await clientHandshake.buildHello();
    final ack = await hostHandshake.handleHello(
      Map<String, Object?>.from(_decode(hello)),
    );
    final auth = await clientHandshake.handleHelloAck(
      Map<String, Object?>.from(_decode(ack)),
    );
    final result = await hostHandshake.handleAuth(
      Map<String, Object?>.from(_decode(auth)),
    );

    expect(result.name, 'Guest');
    expect(result.deviceId, await clientIdentity.deviceId);
    expect(result.keys.clientToHost, equals(clientHandshake.keys.clientToHost));
    expect(result.keys.hostToClient, equals(clientHandshake.keys.hostToClient));
    expect(result.keys.sessionId, equals(clientHandshake.keys.sessionId));

    final hostChannel = SecureChannel(keys: result.keys, isHost: true);
    final clientChannel = SecureChannel(
      keys: clientHandshake.keys,
      isHost: false,
    );
    final sealed = await hostChannel.seal(Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(await clientChannel.open(sealed), [1, 2, 3, 4, 5]);

    final reply = await clientChannel.seal(Uint8List.fromList([9, 8, 7]));
    expect(await hostChannel.open(reply), [9, 8, 7]);
  });

  test('tampered ciphertext and replayed counter are rejected', () async {
    final keys = SecureChannelKeys(
      clientToHost: Uint8List.fromList(List.filled(32, 1)),
      hostToClient: Uint8List.fromList(List.filled(32, 2)),
      sessionId: Uint8List.fromList(List.filled(16, 3)),
    );
    final sender = SecureChannel(keys: keys, isHost: true);
    final receiver = SecureChannel(keys: keys, isHost: false);

    final sealed = await sender.seal(Uint8List.fromList([1, 2, 3]));
    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 2] ^= 0xff;
    await expectLater(receiver.open(tampered), throwsA(isA<Exception>()));

    // The failed frame must not advance the counter; the original still works.
    expect(await receiver.open(sealed), [1, 2, 3]);
    await expectLater(receiver.open(sealed), throwsA(isA<Exception>()));
  });

  test('a wrong PIN is rejected by the host', () async {
    final pinnedRoom = RoomInfo(
      roomId: room.roomId,
      roomName: room.roomName,
      hostId: room.hostId,
      hostName: room.hostName,
      hostSigningKey: room.hostSigningKey,
      hostDhKey: room.hostDhKey,
      requiresPin: true,
    );
    final clientIdentity = await DeviceIdentity.generate();
    final hostHandshake = await HostHandshake.begin(
      info: pinnedRoom,
      identity: hostIdentity,
      pin: '1234',
    );
    final clientHandshake = await ClientHandshake.begin(
      room: pinnedRoom,
      identity: clientIdentity,
      displayName: 'Guest',
      pin: '0000',
    );

    final ack = await hostHandshake.handleHello(
      Map<String, Object?>.from(_decode(await clientHandshake.buildHello())),
    );
    final auth = await clientHandshake.handleHelloAck(
      Map<String, Object?>.from(_decode(ack)),
    );

    await expectLater(
      hostHandshake.handleAuth(Map<String, Object?>.from(_decode(auth))),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          contains('PIN'),
        ),
      ),
    );
  });

  test('a host identity mismatch is rejected by the client', () async {
    final impostor = await DeviceIdentity.generate();
    final impostorRoom = RoomInfo(
      roomId: room.roomId,
      roomName: room.roomName,
      hostId: await impostor.deviceId,
      hostName: 'Impostor',
      hostSigningKey: b64(await impostor.signingPublicKey),
      hostDhKey: b64(await impostor.dhPublicKey),
      requiresPin: false,
    );
    final clientIdentity = await DeviceIdentity.generate();
    final hostHandshake = await HostHandshake.begin(
      info: impostorRoom,
      identity: impostor,
    );
    final clientHandshake = await ClientHandshake.begin(
      room: room,
      identity: clientIdentity,
      displayName: 'Guest',
    );

    final ack = await hostHandshake.handleHello(
      Map<String, Object?>.from(_decode(await clientHandshake.buildHello())),
    );
    await expectLater(
      clientHandshake.handleHelloAck(Map<String, Object?>.from(_decode(ack))),
      throwsA(isA<AppException>()),
    );
  });
}

Map<String, Object?> _decode(Uint8List frame) {
  final decoded = Frame.decode(frame);
  return decoded.body;
}
