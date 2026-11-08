import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.id,
    this.radius = 20,
  });

  final String name;
  final String id;
  final double radius;

  static const _palette = [
    Color(0xFF2563EB),
    Color(0xFF0891B2),
    Color(0xFF059669),
    Color(0xFFD97706),
    Color(0xFFDC2626),
    Color(0xFF7C3AED),
    Color(0xFFDB2777),
    Color(0xFF4F46E5),
  ];

  @override
  Widget build(BuildContext context) {
    final seed = id.isEmpty
        ? name.codeUnits.fold<int>(0, (sum, value) => sum + value)
        : id.codeUnits.fold<int>(0, (sum, value) => sum + value);
    final color = _palette[seed % _palette.length];
    final initials = _initials(name);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      foregroundColor: Colors.white,
      child: Text(
        initials,
        style: TextStyle(fontSize: radius * 0.8, fontWeight: FontWeight.w700),
      ),
    );
  }

  String _initials(String value) {
    final words = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      final word = words.first;
      final first = String.fromCharCode(word.runes.first);
      final second = word.runes.length > 1
          ? String.fromCharCode(word.runes.elementAt(1))
          : '';
      return '$first$second'.toUpperCase();
    }
    final first = String.fromCharCode(words.first.runes.first);
    final last = String.fromCharCode(words.last.runes.first);
    return '$first$last'.toUpperCase();
  }
}
