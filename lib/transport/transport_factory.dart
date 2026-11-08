import 'dart:io';

import 'package:flutter/foundation.dart';

import '../transport/ble_transport.dart';
import '../transport/chat_transport.dart';
import '../transport/fake_transport.dart';

/// On phones we use real BLE. Desktop and tests use the in-process fake so the
/// UI can be developed without Bluetooth hardware. `--dart-define=FAKE_TRANSPORT=true`
/// forces the fake transport on a phone as well.
///
/// `--dart-define=REAL_BLE=true` enables real BLE on Linux. The Linux plugin
/// implements the central (member) role only, so the app can join a room hosted
/// on a phone but cannot host one itself.
ChatTransport createChatTransport() {
  const forceFake = bool.fromEnvironment('FAKE_TRANSPORT');
  if (forceFake) return FakeTransport(FakeHub());
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    return BleTransport();
  }
  const realBle = bool.fromEnvironment('REAL_BLE');
  if (realBle && !kIsWeb && Platform.isLinux) {
    return BleTransport(canHost: false);
  }
  return FakeTransport(FakeHub());
}
