import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Locale-aware dates: never build date strings by hand.
String formatDate(BuildContext context, DateTime date) => DateFormat.yMMMd(
  Localizations.localeOf(context).toString(),
).format(date.toLocal());

String formatDateTime(BuildContext context, DateTime date) => DateFormat.yMMMd(
  Localizations.localeOf(context).toString(),
).add_Hm().format(date.toLocal());

/// `YYYY-MM-DD`, the format of dates in API payloads.
String apiDate(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}';
}
