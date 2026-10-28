import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/utils/date_format.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/time_off.dart';
import '../doctors_providers.dart';

/// Whole days are shown as a date range ("Dec 24 → Dec 26": the stored end is midnight
/// after the last day); anything else keeps its exact start and end.
String timeOffPeriod(BuildContext context, TimeOff item) {
  bool midnight(DateTime d) => d.hour == 0 && d.minute == 0 && d.second == 0;
  if (midnight(item.startAt) && midnight(item.endAt)) {
    final last = DateTime(
      item.endAt.year,
      item.endAt.month,
      item.endAt.day - 1,
    );
    final first = formatDate(context, item.startAt);
    final lastText = formatDate(context, last);
    return first == lastText ? first : '$first → $lastText';
  }
  return '${formatDateTime(context, item.startAt)} → '
      '${formatDateTime(context, item.endAt)}';
}

/// Time off of the doctor (whole days), newest first.
class TimeOffScreen extends ConsumerWidget {
  const TimeOffScreen({super.key});

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    TimeOff item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(l10n.timeOffDeleteTitle),
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
      await ref.read(timeOffProvider.notifier).remove(item.id);
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.timeOffTitle)),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fabTimeOffAdd',
        onPressed:
            () => showDialog<void>(
              context: context,
              builder:
                  (_) => TimeOffDialog(
                    onSave: ref.read(timeOffProvider.notifier).add,
                  ),
            ),
        icon: const Icon(Icons.add),
        label: Text(l10n.timeOffAdd),
      ),
      body: AsyncValueView(
        value: ref.watch(timeOffProvider),
        onRetry: () => ref.invalidate(timeOffProvider),
        isEmpty: (items) => items.isEmpty,
        emptyText: l10n.timeOffEmpty,
        data:
            (items) => ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  title: Text(timeOffPeriod(context, item)),
                  subtitle: item.reason.isEmpty ? null : Text(item.reason),
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

/// The appointments in the way of a time off (the doctor cancels them first).
class TimeOffConflictList extends StatelessWidget {
  const TimeOffConflictList({super.key, required this.conflict});

  final TimeOffConflict conflict;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final more = conflict.count - conflict.items.length;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.timeOffConflictTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final item in conflict.items)
            Text(
              l10n.timeOffConflictLine(
                formatDateTime(context, item.startAt),
                item.patientName,
              ),
            ),
          if (more > 0) Text(l10n.timeOffConflictMore(more)),
        ],
      ),
    );
  }
}

/// Pick a date range (whole days: from the first day at 00:00 to the end of the last day).
class TimeOffDialog extends StatefulWidget {
  const TimeOffDialog({super.key, required this.onSave});

  final Future<void> Function(DateTime startAt, DateTime endAt, String reason)
  onSave;

  @override
  State<TimeOffDialog> createState() => _TimeOffDialogState();
}

class _TimeOffDialogState extends State<TimeOffDialog> {
  final _reason = TextEditingController();
  DateTimeRange? _range;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final today = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 3),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _submit() async {
    final range = _range!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(
        DateTime(range.start.year, range.start.month, range.start.day),
        // Midnight after the last chosen day.
        DateTime(range.end.year, range.end.month, range.end.day + 1),
        _reason.text.trim(),
      );
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
    final range = _range;
    return AlertDialog(
      title: Text(l10n.timeOffAdd),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.date_range),
              label: Text(
                range == null
                    ? l10n.timeOffPickRange
                    : '${formatDate(context, range.start)} → '
                        '${formatDate(context, range.end)}',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              maxLength: 200,
              decoration: InputDecoration(labelText: l10n.timeOffReasonLabel),
            ),
            if (_error != null)
              Text(
                errorText(context, _error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (TimeOffConflict.from(_error) case final conflict?)
              TimeOffConflictList(conflict: conflict),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy || range == null ? null : _submit,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
