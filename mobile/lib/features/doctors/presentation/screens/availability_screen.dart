import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/availability.dart';
import '../doctors_providers.dart';
import 'doctor_texts.dart';

/// Weekly availability editor of the doctor.
class AvailabilityScreen extends ConsumerWidget {
  const AvailabilityScreen({super.key, this.timeOffPath});

  /// Route of the time-off list (button in the app bar).
  final String? timeOffPath;

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Availability item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(l10n.availabilityDeleteTitle),
            content: Text(
              '${weekdayName(context, item.weekday)}, '
              '${timeRange(context, item.start, item.end)}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.commonDelete),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(availabilityProvider.notifier).remove(item.id);
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(availabilityProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.availabilityTitle),
        actions: [
          if (timeOffPath != null)
            TextButton.icon(
              onPressed: () => context.push(timeOffPath!),
              icon: const Icon(Icons.beach_access_outlined),
              label: Text(l10n.timeOffTitle),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed:
            () => showDialog<void>(
              context: context,
              builder: (_) => AvailabilityDialog(onSave: controller.add),
            ),
        icon: const Icon(Icons.add),
        label: Text(l10n.availabilityAdd),
      ),
      body: AsyncValueView(
        value: ref.watch(availabilityProvider),
        onRetry: () => ref.invalidate(availabilityProvider),
        isEmpty: (items) => items.isEmpty,
        emptyText: l10n.availabilityEmpty,
        data:
            (items) => ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  title: Text(weekdayName(context, item.weekday)),
                  subtitle: Text(timeRange(context, item.start, item.end)),
                  onTap:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => AvailabilityDialog(
                              initial: item,
                              onSave:
                                  (day, start, end) =>
                                      controller.edit(item.id, day, start, end),
                            ),
                      ),
                  trailing: IconButton(
                    tooltip: l10n.commonDelete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, ref, item),
                  ),
                );
              },
            ),
      ),
    );
  }
}

/// Add / edit one window. Server errors (e.g. `availability_overlap`) show inside the
/// dialog so the doctor can fix the hours without retyping.
class AvailabilityDialog extends StatefulWidget {
  const AvailabilityDialog({super.key, this.initial, required this.onSave});

  final Availability? initial;
  final Future<void> Function(int weekday, TimeOfDay start, TimeOfDay end)
  onSave;

  @override
  State<AvailabilityDialog> createState() => _AvailabilityDialogState();
}

class _AvailabilityDialogState extends State<AvailabilityDialog> {
  late int _weekday = widget.initial?.weekday ?? 0;
  late TimeOfDay _start =
      widget.initial?.start ?? const TimeOfDay(hour: 9, minute: 0);
  late TimeOfDay _end =
      widget.initial?.end ?? const TimeOfDay(hour: 12, minute: 0);
  bool _busy = false;
  Object? _error;

  Future<void> _pick(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked == null) return;
    setState(() => isStart ? _start = picked : _end = picked);
  }

  bool get _endAfterStart =>
      _end.hour * 60 + _end.minute > _start.hour * 60 + _start.minute;

  Future<void> _submit() async {
    if (!_endAfterStart) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(_weekday, _start, _end);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? l10n.availabilityAdd
            : l10n.availabilityEditTitle,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              value: _weekday,
              decoration: InputDecoration(labelText: l10n.availabilityDayLabel),
              items: [
                for (var day = 0; day < 7; day++)
                  DropdownMenuItem(
                    value: day,
                    child: Text(weekdayName(context, day)),
                  ),
              ],
              onChanged: (day) => setState(() => _weekday = day ?? _weekday),
            ),
            const SizedBox(height: 16),
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pick(true),
                    child: Text(
                      '${l10n.availabilityStartLabel} ${_start.format(context)}',
                    ),
                  ),
                ),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pick(false),
                    child: Text(
                      '${l10n.availabilityEndLabel} ${_end.format(context)}',
                    ),
                  ),
                ),
              ],
            ),
            if (!_endAfterStart || _error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  !_endAfterStart
                      ? l10n.availabilityEndAfterStart
                      : errorText(context, _error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy || !_endAfterStart ? null : _submit,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
