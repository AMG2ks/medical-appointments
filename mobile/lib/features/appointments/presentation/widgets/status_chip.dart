import 'package:flutter/material.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/appointment.dart';
import '../screens/appointment_texts.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final AppointmentStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      AppointmentStatus.confirmed => scheme.primary,
      AppointmentStatus.completed => scheme.tertiary,
      AppointmentStatus.cancelled ||
      AppointmentStatus.unknown => scheme.outline,
      AppointmentStatus.noShow => scheme.error,
    };
    return Chip(
      label: Text(
        statusText(AppLocalizations.of(context), status),
        style: TextStyle(color: color),
      ),
      side: BorderSide(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}
