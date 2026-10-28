import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../auth/data/models/user.dart';
import '../../data/models/app_notification.dart';

/// Title and body of a notification, built from its kind + data in the current language.
/// [role] is the reader's role: a cancellation reads differently for the patient and the
/// doctor, and an admin-made one says "the clinic".
({String title, String body}) notificationText(
  BuildContext context,
  AppNotification n,
  UserRole role,
) {
  final l10n = AppLocalizations.of(context);
  final start = n.start;
  final when =
      start == null
          ? ''
          : DateFormat.yMMMEd(
            Localizations.localeOf(context).toString(),
          ).add_Hm().format(start);
  final body = switch (n.kind) {
    NotificationKind.appointmentConfirmed => l10n.notifConfirmedBody(
      n.doctorName,
      when,
    ),
    NotificationKind.appointmentBooked => l10n.notifBookedBody(
      n.patientName,
      when,
    ),
    NotificationKind.appointmentReminder => l10n.notifReminderBody(
      n.doctorName,
      when,
    ),
    NotificationKind.appointmentCancelled => _cancelled(l10n, n, role, when),
    NotificationKind.unknown => l10n.notifUnknownBody,
  };
  final title = switch (n.kind) {
    NotificationKind.appointmentConfirmed => l10n.notifConfirmedTitle,
    NotificationKind.appointmentBooked => l10n.notifBookedTitle,
    NotificationKind.appointmentReminder => l10n.notifReminderTitle,
    NotificationKind.appointmentCancelled => l10n.notifCancelledTitle,
    NotificationKind.unknown => l10n.notifUnknownTitle,
  };
  final reason =
      n.kind == NotificationKind.appointmentCancelled && n.reason.isNotEmpty
          ? '\n${l10n.apptCancellationReason(n.reason)}'
          : '';
  return (title: title, body: '$body$reason');
}

String _cancelled(
  AppLocalizations l10n,
  AppNotification n,
  UserRole role,
  String when,
) {
  final isDoctor = role == UserRole.doctor;
  return switch (n.cancelledBy) {
    'patient' => l10n.notifCancelledByPatientBody(n.patientName, when),
    'doctor' => l10n.notifCancelledByDoctorBody(n.doctorName, when),
    _ =>
      isDoctor
          ? l10n.notifCancelledByClinicDoctorBody(n.patientName, when)
          : l10n.notifCancelledByClinicPatientBody(n.doctorName, when),
  };
}
