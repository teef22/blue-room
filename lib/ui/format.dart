import 'package:intl/intl.dart';

final DateFormat _time = DateFormat.Hm();
final DateFormat _date = DateFormat.MMMd();
final DateFormat _fullDate = DateFormat.yMMMd().add_Hm();

String chatTimestamp(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return _time.format(local);
  if (difference == 1) return 'Yesterday';
  if (difference < 7) return DateFormat.E().format(local);
  return _date.format(local);
}

String messageTimestamp(DateTime value) => _time.format(value.toLocal());

String fullTimestamp(DateTime value) => _fullDate.format(value.toLocal());

String dayLabel(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  return DateFormat.yMMMMd().format(local);
}

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
