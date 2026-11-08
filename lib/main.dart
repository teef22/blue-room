import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'crypto/identity.dart';
import 'data/app_database.dart';
import 'data/chat_repository.dart';
import 'data/local_store.dart';
import 'services/chat_service.dart';
import 'transport/transport_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  try {
    final store = await LocalStore.open();
    final identity = await DeviceIdentity.loadOrCreate(store);
    String? databasePath;
    if (isDesktop) {
      final directory = await getApplicationSupportDirectory();
      databasePath = p.join(directory.path, 'blue_room.db');
    }
    final database = await AppDatabase.open(path: databasePath);
    final service = ChatService(
      identity: identity,
      store: store,
      repository: ChatRepository(database),
      transport: createChatTransport(),
    );
    await service.init();
    runApp(
      ChangeNotifierProvider<ChatService>.value(
        value: service,
        child: const BlueRoomApp(),
      ),
    );
  } catch (error, stackTrace) {
    debugPrint('Startup failed: $error\n$stackTrace');
    runApp(_StartupErrorApp(message: '$error'));
  }
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Blue Room could not start',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
