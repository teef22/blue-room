import 'package:blue_room/crypto/identity.dart';
import 'package:blue_room/models/models.dart';
import 'package:blue_room/util/bytes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RoomInfo binary form fits a single ATT read and round-trips', () async {
    final identity = await DeviceIdentity.generate();
    final info = RoomInfo(
      roomId: generateRoomId(),
      roomName: 'A very long room name that must be truncated',
      hostId: await identity.deviceId,
      hostName: 'A very long host name that must be truncated',
      hostSigningKey: b64(await identity.signingPublicKey),
      hostDhKey: b64(await identity.dhPublicKey),
      requiresPin: true,
    );

    final bytes = info.toBytes();
    // 74 bytes of fixed fields plus two length-prefixed 32-byte names.
    expect(bytes.length, lessThanOrEqualTo(140));
    expect(bytes.length, lessThanOrEqualTo(180));

    final decoded = RoomInfo.fromBytes(bytes);
    expect(decoded.roomId, info.roomId);
    expect(decoded.hostId, info.hostId);
    expect(decoded.hostSigningKey, info.hostSigningKey);
    expect(decoded.hostDhKey, info.hostDhKey);
    expect(decoded.requiresPin, isTrue);
    expect(decoded.roomName, info.roomName.substring(0, 32));
    expect(decoded.hostName, info.hostName.substring(0, 32));
    expect(decoded.fingerprint, info.fingerprint);
  });

  test('truncated room info is rejected', () async {
    final identity = await DeviceIdentity.generate();
    final info = RoomInfo(
      roomId: generateRoomId(),
      roomName: 'Room',
      hostId: await identity.deviceId,
      hostName: 'Host',
      hostSigningKey: b64(await identity.signingPublicKey),
      hostDhKey: b64(await identity.dhPublicKey),
      requiresPin: false,
    );
    expect(
      () => RoomInfo.fromBytes(info.toBytes().sublist(0, 20)),
      throwsA(isA<AppException>()),
    );
  });
}
