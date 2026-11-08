import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static Future<AppDatabase> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final selectedFactory = factory ?? databaseFactory;
    final databasePath =
        path ??
        p.join(await selectedFactory.getDatabasesPath(), 'blue_room.db');
    final database = await selectedFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE chats (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              role INTEGER NOT NULL,
              requires_pin INTEGER NOT NULL DEFAULT 0,
              host_id TEXT NOT NULL,
              host_name TEXT NOT NULL,
              host_signing_key TEXT NOT NULL,
              host_dh_key TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              status INTEGER NOT NULL,
              last_seq INTEGER NOT NULL DEFAULT 0,
              last_read_seq INTEGER NOT NULL DEFAULT 0,
              last_message_text TEXT,
              last_message_at INTEGER,
              history_truncated INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              chat_id TEXT NOT NULL,
              msg_id TEXT NOT NULL,
              seq INTEGER,
              sender_id TEXT NOT NULL,
              sender_name TEXT NOT NULL,
              sender_key TEXT NOT NULL,
              sent_at INTEGER NOT NULL,
              received_at INTEGER NOT NULL,
              text TEXT NOT NULL,
              signature TEXT NOT NULL,
              state INTEGER NOT NULL,
              PRIMARY KEY (chat_id, msg_id),
              FOREIGN KEY (chat_id) REFERENCES chats (id) ON DELETE CASCADE
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_messages_chat_seq ON messages (chat_id, seq)',
          );
          await db.execute('''
            CREATE TABLE members (
              chat_id TEXT NOT NULL,
              device_id TEXT NOT NULL,
              name TEXT NOT NULL,
              public_key TEXT NOT NULL,
              is_host INTEGER NOT NULL DEFAULT 0,
              is_online INTEGER NOT NULL DEFAULT 0,
              last_seen INTEGER NOT NULL,
              PRIMARY KEY (chat_id, device_id),
              FOREIGN KEY (chat_id) REFERENCES chats (id) ON DELETE CASCADE
            )
          ''');
        },
      ),
    );
    return AppDatabase._(database);
  }

  Future<void> close() => db.close();
}
