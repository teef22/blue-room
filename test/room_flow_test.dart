import 'dart:async';
import 'dart:io';

import 'package:blue_room/crypto/identity.dart';
import 'package:blue_room/data/app_database.dart';
import 'package:blue_room/data/chat_repository.dart';
import 'package:blue_room/models/models.dart';
import 'package:blue_room/protocol/room_session.dart';
import 'package:blue_room/transport/chat_transport.dart';
import 'package:blue_room/transport/fake_transport.dart';
import 'package:blue_room/util/bytes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('host relays messages and late joiners receive history', () async {
    final env = _TestEnvironment();
    addTearDown(env.dispose);
    await env.init();

    await env.hostSession.start();
    await env.hostSession.sendText('first message');
    await env.hostSession.sendText('second message');

    final firstMember = await env.newMember();
    await firstMember.session.start();

    await _eventually(
      () async =>
          (await firstMember.repository.recentMessages(env.roomId)).length == 2,
      reason: 'first member sync',
    );

    await firstMember.session.sendText('reply from guest');
    await _eventually(
      () async =>
          (await env.hostRepository.recentMessages(env.roomId)).length == 3,
      reason: 'host receives reply',
    );
    await _eventually(
      () async =>
          (await firstMember.repository.recentMessages(env.roomId)).length == 3,
      reason: 'guest receives ack',
    );

    final lateMember = await env.newMember();
    await lateMember.session.start();
    await _eventually(
      () async =>
          (await lateMember.repository.recentMessages(env.roomId)).length == 3,
      reason: 'late member history sync',
    );

    final history = await lateMember.repository.recentMessages(env.roomId);
    expect(history.map((message) => message.text), [
      'first message',
      'second message',
      'reply from guest',
    ]);
    expect(history.map((message) => message.seq), [1, 2, 3]);
    expect(
      history.every((message) => message.state == MessageState.sent),
      isTrue,
    );

    final members = await lateMember.repository.loadMembers(env.roomId);
    expect(members.where((member) => member.isHost), hasLength(1));
    expect(members, hasLength(3));

    await firstMember.session.close();
    await lateMember.session.close();
    await env.hostSession.close();
  });

  test('a member reconnecting after new messages catches up', () async {
    final env = _TestEnvironment();
    addTearDown(env.dispose);
    await env.init();

    await env.hostSession.start();
    await env.hostSession.sendText('one');
    final member = await env.newMember();
    await member.session.start();
    await _eventually(
      () async =>
          (await member.repository.recentMessages(env.roomId)).length == 1,
      reason: 'initial sync',
    );

    await member.session.close();
    await env.hostSession.sendText('two');
    await env.hostSession.sendText('three');

    // Reconnect using the same repositories/conversation.
    final resumed = await env.newMember(
      identity: member.identity,
      repository: member.repository,
      chat: await member.repository.loadChat(env.roomId),
    );
    await resumed.session.start();
    await _eventually(
      () async =>
          (await member.repository.recentMessages(env.roomId)).length == 3,
      reason: 'delta sync',
    );
    final history = await member.repository.recentMessages(env.roomId);
    expect(history.map((message) => message.text), ['one', 'two', 'three']);
    expect(history.map((message) => message.seq), [1, 2, 3]);

    await resumed.session.close();
    await env.hostSession.close();
  });

  test('a wrong PIN never joins the room', () async {
    final env = _TestEnvironment(pin: '4321');
    addTearDown(env.dispose);
    await env.init();
    await env.hostSession.start();

    final member = await env.newMember(pin: '0000');
    await expectLater(member.session.start(), throwsA(isA<AppException>()));

    await _eventually(
      () async => (await member.repository.recentMessages(env.roomId)).isEmpty,
      reason: 'no messages after rejected join',
    );
    final chat = await member.repository.loadChat(env.roomId);
    expect(chat?.status ?? ChatStatus.offline, ChatStatus.offline);
    await env.hostSession.close();
  });
}

Future<void> _eventually(
  Future<bool> Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out${reason == null ? '' : ' ($reason)'}');
}

class _Member {
  _Member(this.session, this.repository, this.identity);

  final MemberRoomSession session;
  final ChatRepository repository;
  final DeviceIdentity identity;
  StreamSubscription<TransportEvent>? wire;
}

class _TestEnvironment {
  _TestEnvironment({this.pin});

  final String? pin;
  final FakeHub hub = FakeHub();
  final List<_Member> _members = [];
  final List<AppDatabase> _databases = [];
  final List<Directory> _directories = [];

  late DeviceIdentity hostIdentity;
  late FakeTransport hostTransport;
  late AppDatabase hostDatabase;
  late ChatRepository hostRepository;
  late RoomInfo info;
  late String roomId;
  late HostRoomSession hostSession;
  StreamSubscription<TransportEvent>? _hostWire;

  int _databaseCounter = 0;

  Future<void> init() async {
    hostIdentity = await DeviceIdentity.generate();
    hostTransport = FakeTransport(hub, chunkSize: 60);
    await hostTransport.init();
    final hostDeviceId = await hostIdentity.deviceId;
    roomId = generateRoomId();
    info = RoomInfo(
      roomId: roomId,
      roomName: 'Test room',
      hostId: hostDeviceId,
      hostName: 'Host',
      hostSigningKey: b64(await hostIdentity.signingPublicKey),
      hostDhKey: b64(await hostIdentity.dhPublicKey),
      requiresPin: pin != null,
    );

    hostDatabase = await _newDatabase('host');
    hostRepository = ChatRepository(hostDatabase);
    await hostRepository.saveChat(
      Chat(
        id: roomId,
        name: info.roomName,
        role: ChatRole.host,
        requiresPin: info.requiresPin,
        hostId: info.hostId,
        hostName: info.hostName,
        hostSigningKey: info.hostSigningKey,
        hostDhKey: info.hostDhKey,
        createdAt: DateTime.now(),
        status: ChatStatus.offline,
      ),
    );

    hostSession = HostRoomSession(
      chatId: roomId,
      identity: hostIdentity,
      repository: hostRepository,
      transport: hostTransport,
      callbacks: RoomCallbacks(
        onChanged: () async {},
        onNotice: (_) {},
        onClosed: ({String? error, bool ended = false}) {},
      ),
      displayName: 'Host',
      info: info,
      pin: pin,
    );
    _hostWire = _wire(hostTransport, hostSession);
  }

  Future<_Member> newMember({
    DeviceIdentity? identity,
    ChatRepository? repository,
    Chat? chat,
    String? pin,
  }) async {
    final memberIdentity = identity ?? await DeviceIdentity.generate();
    final memberTransport = FakeTransport(hub, chunkSize: 60);
    await memberTransport.init();
    final memberRepository =
        repository ?? ChatRepository(await _newDatabase('member'));
    final memberChat =
        chat ??
        Chat(
          id: roomId,
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
    final session = MemberRoomSession(
      chatId: roomId,
      identity: memberIdentity,
      repository: memberRepository,
      transport: memberTransport,
      callbacks: RoomCallbacks(
        onChanged: () async {},
        onNotice: (_) {},
        onClosed: ({String? error, bool ended = false}) {},
      ),
      displayName: 'Guest',
      chat: memberChat,
      room: DiscoveredRoom(
        peripheralId: hostTransport.address,
        displayName: info.roomName,
        roomId: roomId,
        rssi: -40,
        lastSeen: DateTime.now(),
      ),
      info: info,
      pin: pin ?? this.pin,
    );
    final member = _Member(session, memberRepository, memberIdentity);
    member.wire = _wire(memberTransport, session);
    _members.add(member);
    return member;
  }

  StreamSubscription<TransportEvent> _wire(
    ChatTransport transport,
    RoomSession session,
  ) {
    return transport.events.listen((event) {
      switch (event) {
        case TransportConnected():
          unawaited(session.onConnected(event));
        case TransportData():
          session.onData(event);
        case TransportDisconnected():
          unawaited(session.onDisconnected(event));
        case TransportStateChanged():
        case TransportDiscovered():
      }
    });
  }

  Future<AppDatabase> _newDatabase(String label) async {
    final directory = await Directory.systemTemp.createTemp('blue_room_test_');
    _directories.add(directory);
    final database = await AppDatabase.open(
      path: p.join(directory.path, '$label-${_databaseCounter++}.db'),
      factory: databaseFactoryFfi,
    );
    _databases.add(database);
    return database;
  }

  Future<void> dispose() async {
    await _hostWire?.cancel();
    for (final member in _members) {
      await member.wire?.cancel();
      await member.session.dispose();
    }
    await hostSession.dispose();
    await hostTransport.dispose();
    for (final database in _databases) {
      await database.close();
    }
    for (final directory in _directories) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Ignore cleanup errors.
      }
    }
  }
}
