import 'dart:async';
import 'dart:typed_data';

import '../core/constants.dart';
import '../models/models.dart';
import '../transport/chat_transport.dart';

class _IncomingFrame {
  _IncomingFrame(this.count, this.startedAt)
    : chunks = List<Uint8List?>.filled(count, null);

  final int count;
  final DateTime startedAt;
  final List<Uint8List?> chunks;

  int get received => chunks.where((chunk) => chunk != null).length;

  Uint8List? assemble() {
    if (received != count) return null;
    final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk!.length);
    if (total > Protocol.maxFrameBytes) {
      throw const AppException('Frame is too large');
    }
    final result = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      result.setAll(offset, chunk!);
      offset += chunk.length;
    }
    return result;
  }
}

/// Reassembles transport chunks into protocol frames and splits outgoing
/// frames into chunks that fit the current BLE link.
class Link {
  Link({required this.transport, required this.connectionId}) {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
      _incoming.removeWhere((_, frame) => frame.startedAt.isBefore(cutoff));
    });
  }

  final ChatTransport transport;
  final String connectionId;

  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  final Map<int, _IncomingFrame> _incoming = {};
  late final Timer _cleanupTimer;
  Future<void> _sendChain = Future<void>.value();
  int _nextFrameId = 1;
  bool _closed = false;

  Stream<Uint8List> get frames => _frames.stream;

  int get _chunkSize {
    final available =
        transport.maxPayloadSize(connectionId) - Protocol.chunkHeaderSize;
    if (available <= 0) return Protocol.minChunkSize;
    return available > Protocol.maxChunkSize
        ? Protocol.maxChunkSize
        : available;
  }

  void handleData(Uint8List data) {
    if (_closed || data.length < Protocol.chunkHeaderSize) return;
    final header = ByteData.sublistView(data, 0, Protocol.chunkHeaderSize);
    final frameId = header.getUint16(0);
    final index = header.getUint16(2);
    final count = header.getUint16(4);
    final payload = Uint8List.sublistView(data, Protocol.chunkHeaderSize);

    if (count == 0 || index >= count || payload.isEmpty) return;
    var frame = _incoming[frameId];
    if (frame == null || frame.count != count) {
      if (_incoming.length >= Protocol.maxConcurrentFrames) return;
      frame = _IncomingFrame(count, DateTime.now());
      _incoming[frameId] = frame;
    }
    frame.chunks[index] = payload;
    if (frame.received == frame.count) {
      _incoming.remove(frameId);
      try {
        final assembled = frame.assemble();
        if (assembled != null && !_closed) {
          _frames.add(assembled);
        }
      } catch (_) {
        // Drop malformed frames.
      }
    }
  }

  Future<void> sendFrame(Uint8List frame) {
    if (_closed) {
      return Future.error(const AppException('Connection is closed'));
    }
    if (frame.length > Protocol.maxFrameBytes) {
      return Future.error(const AppException('Frame is too large'));
    }
    final frameId = _nextFrameId;
    _nextFrameId = (_nextFrameId + 1) & 0xffff;
    final chunkSize = _chunkSize;
    final count = (frame.length / chunkSize).ceil();
    if (count > 0xffff) {
      return Future.error(const AppException('Frame needs too many chunks'));
    }

    final completer = Completer<void>();
    _sendChain = _sendChain.then((_) async {
      try {
        for (var index = 0; index < count; index++) {
          final start = index * chunkSize;
          final end = (start + chunkSize).clamp(0, frame.length);
          final chunk = Uint8List(Protocol.chunkHeaderSize + (end - start));
          ByteData.view(chunk.buffer, 0, Protocol.chunkHeaderSize)
            ..setUint16(0, frameId)
            ..setUint16(2, index)
            ..setUint16(4, count);
          chunk.setAll(Protocol.chunkHeaderSize, frame.sublist(start, end));
          await transport.send(connectionId, chunk);
        }
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _cleanupTimer.cancel();
    _incoming.clear();
    await _frames.close();
  }
}
