import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Detail route of an appointment, per role area.
String patientAppointmentRoute(int id) => '/patient/appointments/$id';
String doctorAppointmentRoute(int id) => '/doctor/appointments/$id';

/// List route of the appointments tab, per role area.
const patientAppointmentsRoute = '/patient/appointments';
const doctorAppointmentsRoute = '/doctor';

/// Opens an appointment from outside its tab (after a booking, from a notification): the
/// tab's list first, then the detail pushed on top, like a tap on a row.
///
/// A single `go` to the detail builds list and detail in one go, so the list sits under the
/// detail in a tab that was never laid out; when its data arrives, Flutter's debug build
/// throws "relayout boundary" assertions and the tab ends up blank.
void showAppointment(
  BuildContext context, {
  required int id,
  bool doctor = false,
}) {
  final router = GoRouter.of(context);
  router.go(doctor ? doctorAppointmentsRoute : patientAppointmentsRoute);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    router.push(
      doctor ? doctorAppointmentRoute(id) : patientAppointmentRoute(id),
    );
  });
}
