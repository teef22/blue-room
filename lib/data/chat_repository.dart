import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

class ChatRepository {
  ChatRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  Future<List<Chat>> loadChats({required String selfDeviceId}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT c.*, (
        SELECT COUNT(*) FROM messages m
        WHERE m.chat_id = c.id
          AND m.seq IS NOT NULL
          AND m.seq > c.last_read_seq
          AND m.sender_id != ?
      ) AS unread
      FROM chats c
      ORDER BY (c.last_message_at IS NULL) ASC,
               c.last_message_at DESC,
               c.created_at DESC
      ''',
      [selfDeviceId],
    );
    return rows.map(Chat.fromRow).toList();
  }

  Future<Chat?> loadChat(String chatId) async {
    final rows = await _db.query(
      'chats',
      where: 'id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Chat.fromRow(rows.first);
  }

  Future<void> saveChat(Chat chat) async {
    // Do not use INSERT OR REPLACE here: REPLACE deletes the existing row,
    // which would cascade-delete the chat's messages and members.
    final updated = await _db.update(
      'chats',
      chat.toRow(),
      where: 'id = ?',
      whereArgs: [chat.id],
    );
    if (updated == 0) {
      await _db.insert(
        'chats',
        chat.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> setStatus(String chatId, ChatStatus status) async {
    await _db.update(
      'chats',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> setHistoryTruncated(String chatId, bool truncated) async {
    await _db.update(
      'chats',
      {'history_truncated': truncated ? 1 : 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> markRead(String chatId, int seq) async {
    await _db.rawUpdate(
      'UPDATE chats SET last_read_seq = MAX(last_read_seq, ?) WHERE id = ?',
      [seq, chatId],
    );
  }

  Future<void> bumpLastSeq(String chatId, int seq) async {
    await _db.rawUpdate(
      'UPDATE chats SET last_seq = MAX(last_seq, ?) WHERE id = ?',
      [seq, chatId],
    );
  }

  Future<void> deleteChat(String chatId) async {
    await _db.delete('chats', where: 'id = ?', whereArgs: [chatId]);
  }

  /// Inserts a message if it does not exist yet and updates the chat summary.
  /// Returns false for an already known message.
  Future<bool> insertMessage(ChatMessage message) async {
    var inserted = false;
    await _db.transaction((txn) async {
      final rowId = await txn.insert(
        'messages',
        message.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (rowId == 0) return;
      inserted = true;
      await _updateChatSummary(txn, message);
    });
    return inserted;
  }

  Future<void> _updateChatSummary(DatabaseExecutor txn, ChatMessage message) {
    final sentAt = message.sentAt.millisecondsSinceEpoch;
    return txn.rawUpdate(
      '''
      UPDATE chats SET
        last_seq = CASE WHEN ? IS NULL THEN last_seq
                        ELSE MAX(last_seq, ?) END,
        last_message_text = CASE
          WHEN last_message_at IS NULL OR ? IS NULL OR ? > last_seq
          THEN ? ELSE last_message_text END,
        last_message_at = CASE
          WHEN last_message_at IS NULL OR ? IS NULL OR ? > last_seq
          THEN ? ELSE last_message_at END
      WHERE id = ?
      ''',
      [
        message.seq,
        message.seq,
        message.seq,
        message.seq,
        message.text,
        message.seq,
        message.seq,
        sentAt,
        message.chatId,
      ],
    );
  }

  /// Inserts a batch of messages in a single transaction. Used for history
  /// sync, where notifications would otherwise flood the UI.
  Future<int> insertMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return 0;
    var inserted = 0;
    await _db.transaction((txn) async {
      for (final message in messages) {
        final rowId = await txn.insert(
          'messages',
          message.toRow(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (rowId != 0) inserted++;
      }
      final highest = messages.last;
      await _updateChatSummary(txn, highest);
    });
    return inserted;
  }

  Future<void> markMessageSent(
    String chatId,
    String msgId,
    int seq,
    DateTime receivedAt,
  ) async {
    await _db.transaction((txn) async {
      await txn.update(
        'messages',
        {
          'seq': seq,
          'state': MessageState.sent.index,
          'received_at': receivedAt.millisecondsSinceEpoch,
        },
        where: 'chat_id = ? AND msg_id = ?',
        whereArgs: [chatId, msgId],
      );
      await txn.rawUpdate(
        'UPDATE chats SET last_seq = MAX(last_seq, ?) WHERE id = ?',
        [seq, chatId],
      );
    });
  }

  Future<void> markMessageFailed(String chatId, String msgId) async {
    await _db.update(
      'messages',
      {'state': MessageState.failed.index},
      where: 'chat_id = ? AND msg_id = ?',
      whereArgs: [chatId, msgId],
    );
  }

  Future<ChatMessage?> messageById(String chatId, String msgId) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ? AND msg_id = ?',
      whereArgs: [chatId, msgId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatMessage.fromRow(rows.first);
  }

  Future<List<ChatMessage>> recentMessages(
    String chatId, {
    int limit = 300,
  }) async {
    final rows = await _db.rawQuery(
      '''
      SELECT * FROM (
        SELECT * FROM messages
        WHERE chat_id = ?
        ORDER BY (seq IS NULL) ASC, seq DESC, sent_at DESC
        LIMIT ?
      ) ORDER BY (seq IS NULL) ASC, seq ASC, sent_at ASC
      ''',
      [chatId, limit],
    );
    return rows.map(ChatMessage.fromRow).toList();
  }

  Future<List<ChatMessage>> messagesAfter(
    String chatId,
    int afterSeq, {
    int limit = 40,
  }) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ? AND seq IS NOT NULL AND seq > ?',
      whereArgs: [chatId, afterSeq],
      orderBy: 'seq ASC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromRow).toList();
  }

  Future<int> maxSeq(String chatId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(seq) AS max_seq FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return (rows.first['max_seq'] as num?)?.toInt() ?? 0;
  }

  Future<List<ChatMember>> loadMembers(String chatId) async {
    final rows = await _db.query(
      'members',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'is_host DESC, is_online DESC, name ASC',
    );
    return rows.map(ChatMember.fromRow).toList();
  }

  Future<void> upsertMember(ChatMember member) async {
    await _db.insert(
      'members',
      member.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setMemberOnline(
    String chatId,
    String deviceId,
    bool online,
  ) async {
    await _db.update(
      'members',
      {
        'is_online': online ? 1 : 0,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'chat_id = ? AND device_id = ?',
      whereArgs: [chatId, deviceId],
    );
  }

  Future<void> setAllMembersOffline(String chatId) async {
    await _db.update(
      'members',
      {'is_online': 0},
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }
}
