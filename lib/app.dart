import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/chat_service.dart';
import 'ui/app_theme.dart';
import 'ui/screens/chats_screen.dart';
import 'ui/screens/onboarding_screen.dart';

class BlueRoomApp extends StatelessWidget {
  const BlueRoomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blue Room',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const RootGate(),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ChatService>();
    if (!service.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (service.displayName.isEmpty) {
      return const OnboardingScreen();
    }
    return const ChatsScreen();
  }
}
