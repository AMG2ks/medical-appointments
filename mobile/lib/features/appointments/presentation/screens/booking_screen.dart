import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/env.dart';
import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/utils/date_format.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../../doctors/presentation/doctors_providers.dart';
import '../../../doctors/presentation/screens/doctor_texts.dart';
import '../../../notifications/local_reminders.dart';
import '../../data/appointments_repository.dart';
import '../../data/models/appointment.dart';
import '../appointments_providers.dart';
import '../appointments_routes.dart';
import 'appointment_texts.dart';

/// Booking flow: pick a date, pick a free slot, confirm. The server is the judge: if the
/// slot was taken meanwhile the error is shown and the slots are reloaded.
class BookingScreen extends ConsumerStatefulWidget {
  const BookingScreen({super.key, required this.doctorId});

  final int doctorId;

  @override
  ConsumerState<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends ConsumerState<BookingScreen> {
  final _reason = TextEditingController();
  DateTime _day = dayOf(DateTime.now());
  Slot? _slot;
  bool _busy = false;

  /// Set once the user picks a date: the automatic "first bookable day" must not override it.
  bool _userPickedDay = false;

  @override
  void initState() {
    super.initState();
    _showFirstBookableDay();
  }

  /// Opens on the first day that has a free slot instead of on today (often empty: past
  /// working hours, day off, or the minimum lead time). Stops at the booking horizon.
  Future<void> _showFirstBookableDay() async {
    final repo = ref.read(appointmentsRepositoryProvider);
    final today = dayOf(DateTime.now());
    for (var i = 0; i <= Env.bookingHorizonDays; i++) {
      final day = DateTime(today.year, today.month, today.day + i);
      try {
        final slots = await repo.slots(doctorId: widget.doctorId, day: day);
        if (!mounted || _userPickedDay) return;
        if (slots.isNotEmpty) {
          if (i > 0) setState(() => _day = day);
          return;
        }
      } catch (_) {
        return; // the slots section shows the error for the shown day
      }
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final today = dayOf(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.isBefore(today) ? today : _day,
      firstDate: today,
      lastDate: today.add(const Duration(days: Env.bookingHorizonDays)),
    );
    if (picked != null) {
      setState(() {
        _userPickedDay = true;
        _day = dayOf(picked);
        _slot = null;
      });
    }
  }

  Future<void> _confirm() async {
    final slot = _slot!;
    setState(() => _busy = true);
    try {
      final booked = await ref
          .read(appointmentsActionsProvider)
          .book(
            doctorId: widget.doctorId,
            slot: slot,
            reason: _reason.text.trim(),
          );
      // In context, at the moment of need: the reminders only make sense once the user has
      // booked. The system shows its dialog only when it can; a refusal just means no
      // on-device reminders (the email and the in-app list still work).
      await ref.read(localRemindersProvider).requestPermission();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).apptBooked)),
      );
      // One `go` to the Appointments tab: the booking screen sits on the root navigator
      // (see router.dart), so it is simply removed and the tab bar appears below it.
      showAppointment(context, id: booked.id);
    } catch (e) {
      if (!mounted) return;
      showApiError(context, e);
      // Only a slot that is gone is deselected (and the slots reloaded); after a limit error
      // (`booking_limit_reached`) the choice stays so the user can read the message.
      final slotGone =
          e is ApiException &&
          (e.code == 'slot_taken' || e.code == 'slot_not_available');
      setState(() {
        if (slotGone) _slot = null;
        _busy = false;
      });
      if (slotGone) ref.invalidate(slotsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final doctor = ref.watch(doctorProvider(widget.doctorId));
    final slotsQuery = (doctorId: widget.doctorId, day: _day);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.apptBookTitle)),
      body: AsyncValueView(
        value: doctor,
        onRetry: () => ref.invalidate(doctorProvider(widget.doctorId)),
        data:
            (d) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  d.fullName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(specialtyName(context, d.specialty)),
                Text(l10n.doctorsConsultationMinutes(d.consultationMinutes)),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickDay,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text(
                    '${l10n.apptPickDate}: ${formatLongDate(context, _day)}',
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.apptSlotsTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                AsyncValueView(
                  value: ref.watch(slotsProvider(slotsQuery)),
                  onRetry: () => ref.invalidate(slotsProvider(slotsQuery)),
                  isEmpty: (slots) => slots.isEmpty,
                  emptyText: l10n.apptNoSlots,
                  data:
                      (slots) => Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final slot in slots)
                            ChoiceChip(
                              label: Text(formatTime(context, slot.start)),
                              selected: _slot?.startIso == slot.startIso,
                              onSelected:
                                  _busy
                                      ? null
                                      : (_) => setState(() => _slot = slot),
                            ),
                        ],
                      ),
                ),
                if (_slot != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    l10n.apptSelectedSlot(
                      formatDateTime(context, _slot!.start),
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    maxLength: 500,
                    maxLines: 3,
                    minLines: 1,
                    decoration: InputDecoration(
                      labelText: l10n.apptBookReasonLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _confirm,
                    child: Text(l10n.apptConfirmButton),
                  ),
                ],
              ],
            ),
      ),
    );
  }
}
