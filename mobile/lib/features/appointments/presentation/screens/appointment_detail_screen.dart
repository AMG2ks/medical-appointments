import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../../auth/data/models/user.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../doctors/presentation/screens/doctor_texts.dart';
import '../../data/models/appointment.dart';
import '../appointments_providers.dart';
import '../widgets/cancel_dialog.dart';
import '../widgets/status_chip.dart';
import 'appointment_texts.dart';

/// One appointment, with the actions of the viewer's role:
/// patient: cancel (while upcoming) · doctor: cancel before the start, complete / no-show
/// once it started. The server enforces the rules (cancellation cutoff, transitions); when
/// it refuses an action the detail is reloaded, since the data probably changed meanwhile.
class AppointmentDetailScreen extends ConsumerStatefulWidget {
  const AppointmentDetailScreen({super.key, required this.appointmentId});

  final int appointmentId;

  @override
  ConsumerState<AppointmentDetailScreen> createState() =>
      _AppointmentDetailScreenState();
}

class _AppointmentDetailScreenState
    extends ConsumerState<AppointmentDetailScreen> {
  /// An action is in flight: buttons are disabled (no double tap).
  bool _busy = false;

  void _toast(String text) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _reload() =>
      ref.refresh(appointmentProvider(widget.appointmentId).future);

  /// Runs [action]; on an API error shows it and reloads the detail.
  Future<T> _reloadingOnError<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException {
      ref.invalidate(appointmentProvider(widget.appointmentId));
      rethrow;
    }
  }

  Future<void> _run(Future<Object?> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _reloadingOnError(action);
      if (mounted) _toast(done);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel({required bool reasonRequired}) async {
    final actions = ref.read(appointmentsActionsProvider);
    final cancelled = await showDialog<bool>(
      context: context,
      builder:
          (_) => CancelAppointmentDialog(
            reasonRequired: reasonRequired,
            onConfirm:
                (reason) => _reloadingOnError(
                  () => actions.cancel(widget.appointmentId, reason: reason),
                ),
          ),
    );
    if (cancelled == true && mounted) {
      _toast(AppLocalizations.of(context).apptCancelled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final role = ref.watch(currentUserProvider)?.role;
    final provider = appointmentProvider(widget.appointmentId);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.apptDetailTitle)),
      body: AsyncValueView(
        value: ref.watch(provider),
        onRetry: () => ref.invalidate(provider),
        data: (a) {
          final isDoctor = role == UserRole.doctor;
          final other = isDoctor ? a.patient : a.doctor;
          final started = a.hasStarted(DateTime.now());
          final actions = ref.read(appointmentsActionsProvider);
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(24),
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: StatusChip(status: a.status),
                ),
                const SizedBox(height: 16),
                _Field(
                  label:
                      isDoctor ? l10n.apptPatientLabel : l10n.apptDoctorLabel,
                  value: other.fullName,
                  extra: [
                    if (other.specialty != null)
                      specialtyName(context, other.specialty!),
                    if (isDoctor && (other.phone ?? '').isNotEmpty)
                      other.phone!,
                  ],
                ),
                _Field(
                  label: l10n.apptWhenLabel,
                  value: formatLongDate(context, a.start),
                  extra: [
                    '${formatTime(context, a.start)} – ${formatTime(context, a.end)}',
                  ],
                ),
                _Field(
                  label: l10n.apptReasonLabel,
                  value: a.reason.isEmpty ? l10n.apptNoReason : a.reason,
                ),
                if (a.status == AppointmentStatus.cancelled)
                  _Field(
                    label: cancelledByText(l10n, a.cancelledByRole),
                    value:
                        a.cancellationReason.isEmpty
                            ? ''
                            : l10n.apptCancellationReason(a.cancellationReason),
                  ),
                if (a.isConfirmed) ...[
                  const SizedBox(height: 24),
                  if (isDoctor && started) ...[
                    FilledButton(
                      onPressed:
                          _busy
                              ? null
                              : () => _run(
                                () => actions.complete(a.id),
                                l10n.apptCompleted,
                              ),
                      child: Text(l10n.apptCompleteButton),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed:
                          _busy
                              ? null
                              : () => _run(
                                () => actions.markNoShow(a.id),
                                l10n.apptMarkedNoShow,
                              ),
                      child: Text(l10n.apptNoShowButton),
                    ),
                  ] else if (!started)
                    OutlinedButton(
                      onPressed:
                          _busy
                              ? null
                              : () => _cancel(reasonRequired: isDoctor),
                      child: Text(l10n.apptCancelButton),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.extra = const [],
  });

  final String label;
  final String value;
  final List<String> extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          if (value.isNotEmpty) Text(value, style: theme.textTheme.titleMedium),
          for (final line in extra) Text(line),
        ],
      ),
    );
  }
}
