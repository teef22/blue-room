import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';

/// Protocol frame types. Plaintext types are only valid before the secure
/// channel is established.
class FrameType {
  static const int hello = 1;
  static const int helloAck = 2;
  static const int auth = 3;
  static const int plainError = 4;

  static const int joinAccept = 10;
  static const int message = 11;
  static const int ack = 12;
  static const int syncRequest = 13;
  static const int syncBatch = 14;
  static const int syncDone = 15;
  static const int memberEvent = 16;
  static const int leave = 17;
  static const int roomClosed = 18;
  static const int ping = 19;
  static const int pong = 20;
  static const int error = 21;
}

class Frame {
  const Frame(this.type, this.body);

  final int type;
  final Map<String, Object?> body;

  Uint8List encode() {
    final payload = utf8.encode(jsonEncode(body));
    final result = Uint8List(1 + payload.length);
    result[0] = type;
    result.setAll(1, payload);
    return result;
  }

  static Frame decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const AppException('Empty protocol frame');
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes.sublist(1)));
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object');
      }
      return Frame(bytes[0], Map<String, Object?>.from(decoded));
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException('Malformed protocol frame');
    }
  }
}
