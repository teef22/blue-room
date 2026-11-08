import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../format.dart';
import '../widgets/status_pill.dart';
import '../widgets/user_avatar.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId});

  final String chatId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatService _service;
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<String>? _noticeSub;
  String? _selfId;
  bool _busy = false;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _service = context.read<ChatService>();
    _service.addListener(_onServiceChanged);
    _noticeSub = _service.notices.listen(_onNotice);
    _service.identity.deviceId.then((id) {
      if (mounted) setState(() => _selfId = id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _service.openChat(widget.chatId);
      _scrollToBottom(jump: true);
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _noticeSub?.cancel();
    _composer.dispose();
    _scroll.dispose();
    unawaited(_service.closeChat(widget.chatId));
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final count = _service.activeMessages.length;
    if (count > _lastMessageCount) {
      _lastMessageCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToBottom({bool jump = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Chat? _chat() {
    for (final chat in _service.chats) {
      if (chat.id == widget.chatId) return chat;
    }
    return null;
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    try {
      await _service.sendMessage(widget.chatId, text);
    } catch (error) {
      _onNotice(error is AppException ? error.message : '$error');
      if (mounted && _composer.text.isEmpty) {
        _composer.text = text;
      }
    }
  }

  Future<void> _reconnect(Chat chat) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.resume(chat);
      _onNotice('Connected to ${chat.name}');
    } catch (error) {
      _onNotice(error is AppException ? error.message : '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect(Chat chat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the room?'),
        content: Text(
          chat.isHost
              ? 'This stops hosting the room. Members will be disconnected, '
                    'but the history stays on your device.'
              : 'You will stop receiving messages until you reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _service.disconnectChat(chat);
      _onNotice('Disconnected');
    } catch (error) {
      _onNotice('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Chat chat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          chat.isLive
              ? 'This ends the room for everyone and removes the history from '
                    'this device.'
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
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _service.deleteChat(chat);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _onNotice('$error');
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMembers(Chat chat) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final members = _service.activeMembers;
          final scheme = Theme.of(context).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Members',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${members.length}',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Room fingerprint ${chat.fingerprint}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final member in members)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                UserAvatar(
                                  name: member.name,
                                  id: member.deviceId,
                                ),
                                Positioned(
                                  right: -1,
                                  bottom: -1,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: member.isOnline
                                          ? const Color(0xFF16A34A)
                                          : scheme.outline,
                                      border: Border.all(
                                        color: scheme.surface,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(
                              member.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              member.isHost
                                  ? 'Host · relays messages'
                                  : 'Member',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Icon(
                              member.isOnline
                                  ? Icons.wifi_tethering
                                  : Icons.wifi_tethering_off,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ChatService>();
    final chat = _chat();
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This chat no longer exists.')),
      );
    }
    final messages = service.activeMessages;
    final live = chat.isLive && service.liveChatId == chat.id;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    chat.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(status: chat.status),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              live
                  ? (chat.isHost
                        ? 'Hosting · ${_onlineCount(service)} online'
                        : 'Connected · ${_onlineCount(service)} online')
                  : (chat.isHost ? 'Host · not hosting' : 'Member · offline'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Members',
            onPressed: () => _showMembers(chat),
            icon: const Icon(Icons.people_outline),
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (value) {
              switch (value) {
                case 'members':
                  _showMembers(chat);
                case 'reconnect':
                  _reconnect(chat);
                case 'disconnect':
                  _disconnect(chat);
                case 'delete':
                  _delete(chat);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'members',
                child: ListTile(
                  leading: Icon(Icons.people_outline),
                  title: Text('Members'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'reconnect',
                enabled: !live,
                child: const ListTile(
                  leading: Icon(Icons.link),
                  title: Text('Reconnect'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'disconnect',
                enabled: live,
                child: const ListTile(
                  leading: Icon(Icons.link_off),
                  title: Text('Disconnect'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Delete chat',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!live)
            _OfflineBanner(
              chat: chat,
              busy: _busy,
              onReconnect: () => _reconnect(chat),
            ),
          if (chat.historyTruncated)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer
                  .withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Older messages were not transferred. Ask the host to share '
                'them while you are connected.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? _EmptyMessages(chat: chat)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final showDay =
                          index == 0 ||
                          !sameDay(messages[index - 1].sentAt, message.sentAt);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showDay) _DayDivider(date: message.sentAt),
                          _MessageBubble(
                            message: message,
                            selfId: _selfId,
                            showSender:
                                message.senderId != _selfId &&
                                (index == 0 ||
                                    messages[index - 1].senderId !=
                                        message.senderId),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          _Composer(
            controller: _composer,
            enabled: live && !_busy,
            onSend: _send,
          ),
        ],
      ),
    );
  }

  int _onlineCount(ChatService service) =>
      service.activeMembers.where((member) => member.isOnline).length;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.selfId,
    required this.showSender,
  });

  final ChatMessage message;
  final String? selfId;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = selfId != null && message.senderId == selfId;
    final failed = message.state == MessageState.failed;
    final pending = message.state == MessageState.pending;
    final bubbleColor = mine
        ? scheme.primary
        : scheme.surfaceContainerHighest.withValues(alpha: 0.8);
    final textColor = mine ? scheme.onPrimary : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showSender)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 3),
              child: Text(
                message.senderName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            padding: const EdgeInsets.fromLTRB(13, 9, 13, 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.text,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15.5,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.seq != null && !mine)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          '#${message.seq}',
                          style: TextStyle(
                            fontSize: 10,
                            color: textColor.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    Text(
                      messageTimestamp(message.sentAt),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: textColor.withValues(alpha: 0.65),
                      ),
                    ),
                    if (mine) ...[
                      const SizedBox(width: 4),
                      Icon(
                        failed
                            ? Icons.error_outline
                            : pending
                            ? Icons.schedule
                            : Icons.done,
                        size: 13,
                        color: failed
                            ? const Color(0xFFFCA5A5)
                            : textColor.withValues(alpha: 0.7),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: scheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              dayLabel(date),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: enabled ? 'Message' : 'Reconnect to send messages',
                  counterText: '',
                  isDense: true,
                ),
                onSubmitted: (_) {
                  if (enabled) onSend();
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({
    required this.chat,
    required this.busy,
    required this.onReconnect,
  });

  final Chat chat;
  final bool busy;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      color: chat.status == ChatStatus.ended
          ? scheme.errorContainer
          : scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            chat.status == ChatStatus.ended ? Icons.block : Icons.link_off,
            size: 18,
            color: chat.status == ChatStatus.ended
                ? scheme.onErrorContainer
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              chat.status == ChatStatus.ended
                  ? 'This room was deleted by the host.'
                  : chat.isHost
                  ? 'You are not hosting this room right now.'
                  : 'You are offline. History is available on this device.',
              style: TextStyle(
                fontSize: 12.5,
                color: chat.status == ChatStatus.ended
                    ? scheme.onErrorContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (chat.status != ChatStatus.ended)
            TextButton(
              onPressed: busy ? null : onReconnect,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(chat.isHost ? 'Host again' : 'Reconnect'),
            ),
        ],
      ),
    );
  }
}

class _EmptyMessages extends StatelessWidget {
  const _EmptyMessages({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 44,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              chat.isHost ? 'Your room is ready' : 'No messages yet',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              chat.isHost
                  ? 'People nearby can join from Add chat. '
                        'Messages you send are relayed to everyone connected.'
                  : 'Say hello when you are connected.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
