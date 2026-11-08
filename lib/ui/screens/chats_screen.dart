import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../format.dart';
import '../widgets/status_pill.dart';
import '../widgets/user_avatar.dart';
import 'add_chat_screen.dart';
import 'chat_screen.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ChatService>();
    final chats = service.chats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          if (!service.bluetoothEnabled)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'Bluetooth is off',
                child: Icon(Icons.bluetooth_disabled, color: Colors.orange),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'name':
                  _changeName(context, service);
                case 'security':
                  _showSecurity(context);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'name',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Change display name'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'security',
                child: ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('Security & privacy'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (service.bluetoothError != null)
            _BluetoothBanner(message: service.bluetoothError!),
          Expanded(
            child: chats.isEmpty
                ? _EmptyState(canHost: service.canHost)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: chats.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      return Dismissible(
                        key: ValueKey(chat.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(
                            Icons.delete_outline,
                            color: Theme.of(context).colorScheme.onError,
                          ),
                        ),
                        confirmDismiss: (_) => _confirmDelete(context, chat),
                        onDismissed: (_) => unawaited(service.deleteChat(chat)),
                        child: _ChatTile(
                          chat: chat,
                          onTap: () => _openChat(context, chat),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddChat(context),
        icon: const Icon(Icons.add),
        label: const Text('Add chat'),
      ),
    );
  }

  Future<void> _openChat(BuildContext context, Chat chat) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: chat.id)),
    );
  }

  Future<void> _openAddChat(BuildContext context) async {
    final service = context.read<ChatService>();
    if (service.hasLiveSession) {
      Chat? current;
      for (final chat in service.chats) {
        if (chat.id == service.liveChatId) current = chat;
      }
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('One room at a time'),
          content: Text(
            'You are connected to "${current?.name ?? 'a room'}". '
            'Disconnect from it before creating or joining another room.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'open'),
              child: const Text('Open room'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'disconnect'),
              child: const Text('Disconnect'),
            ),
          ],
        ),
      );
      if (!context.mounted) return;
      if (action == 'open' && current != null) {
        await _openChat(context, current);
        return;
      }
      if (action == 'disconnect' && current != null) {
        await service.disconnectChat(current);
      }
      if (action != 'disconnect') return;
    }
    if (!context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AddChatScreen()));
  }

  Future<bool> _confirmDelete(BuildContext context, Chat chat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          chat.isLive
              ? 'This ends the room for everyone and removes the history '
                    'from this device.'
              : 'This removes the chat and its history from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _changeName(BuildContext context, ChatService service) async {
    final controller = TextEditingController(text: service.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      await service.setDisplayName(name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  void _showSecurity(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Security & privacy'),
        content: const SingleChildScrollView(
          child: Text(
            'Messages travel directly between nearby phones over Bluetooth. '
            'Every connection is encrypted with ephemeral keys, and every '
            'message is signed by its sender.\n\n'
            'The person who creates a room relays messages, so they can read '
            'the conversation. Nothing is uploaded anywhere and there are no '
            'accounts.\n\n'
            'Room PINs keep casual strangers out. For stronger verification, '
            'compare the room fingerprint shown in the member list.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat, required this.onTap});

  final Chat chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = chat.lastMessageText?.trim().isNotEmpty == true
        ? chat.lastMessageText!
        : chat.isHost
        ? 'Hosting · no messages yet'
        : 'No messages yet';
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(name: chat.name, id: chat.hostId, radius: 23),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chat.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          chat.lastMessageAt == null
                              ? ''
                              : chatTimestamp(chat.lastMessageAt!),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        if (chat.unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${chat.unread}',
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        StatusPill(status: chat.status),
                        const SizedBox(width: 8),
                        Text(
                          chat.isHost ? 'Host' : 'Member',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (chat.requiresPin) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.lock_outline,
                            size: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BluetoothBanner extends StatelessWidget {
  const _BluetoothBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.canHost});

  final bool canHost;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.forum_outlined,
                size: 44,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No chats yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              canHost
                  ? 'Create a room and let people nearby join, or join a room '
                        'that someone else is hosting.'
                  : 'Join a room hosted on a nearby phone. Hosting is only '
                        'available on phones.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
