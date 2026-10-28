import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/appointment.dart';

String statusText(AppLocalizations l10n, AppointmentStatus status) =>
    switch (status) {
      AppointmentStatus.confirmed => l10n.apptStatusConfirmed,
      AppointmentStatus.cancelled => l10n.apptStatusCancelled,
      AppointmentStatus.completed => l10n.apptStatusCompleted,
      AppointmentStatus.noShow => l10n.apptStatusNoShow,
      AppointmentStatus.unknown => l10n.apptStatusUnknown,
    };

/// `09:30`, formatted for the locale (a slot button label).
String formatTime(BuildContext context, DateTime moment) =>
    DateFormat.Hm(Localizations.localeOf(context).toString()).format(moment);

/// `Thursday, Nov 5, 2026`.
String formatLongDate(BuildContext context, DateTime day) =>
    DateFormat.yMMMEd(Localizations.localeOf(context).toString()).format(day);

String cancelledByText(AppLocalizations l10n, String? role) => switch (role) {
  'patient' => l10n.apptCancelledByPatient,
  'doctor' => l10n.apptCancelledByDoctor,
  _ => l10n.apptCancelledByAdmin,
};
