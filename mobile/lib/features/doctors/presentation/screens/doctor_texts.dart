import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models/specialty.dart';

/// Specialty name in the current locale.
String specialtyName(BuildContext context, Specialty specialty) =>
    specialty.nameFor(Localizations.localeOf(context).languageCode);

/// Weekday name (0 = Monday) in the current locale, from intl.
String weekdayName(BuildContext context, int weekday) {
  final monday = DateTime(2024, 1, 1); // a Monday
  return DateFormat.EEEE(
    Localizations.localeOf(context).toString(),
  ).format(monday.add(Duration(days: weekday)));
}

/// `09:00 – 12:00`, formatted for the locale.
String timeRange(BuildContext context, TimeOfDay start, TimeOfDay end) =>
    '${start.format(context)} – ${end.format(context)}';
