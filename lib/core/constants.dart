/// Shared protocol and BLE constants.
class Protocol {
  static const int version = 1;

  /// BLE service and characteristic identifiers. A short service UUID keeps
  /// the advertisement packet small enough to also carry room metadata; the
  /// full UUID is 0000fff0-0000-1000-8000-00805f9b34fb.
  static const int serviceShortId = 0xfff0;
  static const String infoUuid = 'b1e5c0de-0002-4a5e-9f00-1234567890ab';
  static const String rxUuid = 'b1e5c0de-0003-4a5e-9f00-1234567890ab';
  static const String txUuid = 'b1e5c0de-0004-4a5e-9f00-1234567890ab';

  /// Reserved manufacturer id used only for local discovery metadata.
  static const int manufacturerId = 0xffff;

  /// Frame chunk header: frame id (u16), chunk index (u16), chunk count (u16).
  static const int chunkHeaderSize = 6;

  static const int maxFrameBytes = 32 * 1024;
  static const int maxConcurrentFrames = 8;
  static const int maxChunkSize = 180;
  static const int minChunkSize = 1;

  /// Default ATT payload before an MTU is negotiated. A chunk header is
  /// subtracted from this by [Link].
  static const int defaultBlePayload = 20;
  static const int maxBlePayload = maxChunkSize + chunkHeaderSize;

  static const int syncPageSize = 40;
  static const int initialHistoryLimit = 300;

  static const Duration connectionTimeout = Duration(seconds: 20);
  static const Duration handshakeTimeout = Duration(seconds: 20);
  static const Duration sendTimeout = Duration(seconds: 20);
  static const Duration pingInterval = Duration(seconds: 10);
  static const Duration peerTimeout = Duration(seconds: 35);
  static const Duration scanStaleAfter = Duration(seconds: 12);

  static const int maxTextLength = 1000;

  static const String pinSecretPrefix = 'chat.pin.';
}
