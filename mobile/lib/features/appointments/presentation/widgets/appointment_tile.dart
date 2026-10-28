import 'package:flutter/material.dart';

import '../../../../core/utils/date_format.dart';
import '../../../doctors/presentation/screens/doctor_texts.dart';
import '../../data/models/appointment.dart';
import 'status_chip.dart';

/// One row of an appointments list. [showPatient] = the doctor's agenda (shows the patient);
/// otherwise the doctor is shown.
class AppointmentTile extends StatelessWidget {
  const AppointmentTile({
    super.key,
    required this.appointment,
    required this.showPatient,
    required this.onTap,
  });

  final Appointment appointment;
  final bool showPatient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final person = showPatient ? appointment.patient : appointment.doctor;
    final specialty = person.specialty;
    return ListTile(
      onTap: onTap,
      title: Text(person.fullName),
      subtitle: Text(
        [
          formatDateTime(context, appointment.start),
          if (specialty != null) specialtyName(context, specialty),
        ].join('\n'),
      ),
      isThreeLine: specialty != null,
      trailing: StatusChip(status: appointment.status),
    );
  }
}
