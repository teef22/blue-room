import 'package:flutter/material.dart';

import '../../models/models.dart';

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});

  final ChatStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground, String label) = switch (status) {
      ChatStatus.live => (
        const Color(0xFF16A34A).withValues(alpha: 0.14),
        const Color(0xFF15803D),
        'Live',
      ),
      ChatStatus.offline => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        'Offline',
      ),
      ChatStatus.ended => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        'Ended',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
