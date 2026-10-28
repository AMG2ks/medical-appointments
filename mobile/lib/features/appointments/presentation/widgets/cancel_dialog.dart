import 'package:flutter/material.dart';

import '../../../../core/l10n/error_text.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

/// Asks for a cancellation reason, then runs [onConfirm]. Errors (e.g.
/// `cancellation_too_late`) stay in the dialog; it closes with `true` on success.
class CancelAppointmentDialog extends StatefulWidget {
  const CancelAppointmentDialog({
    super.key,
    required this.reasonRequired,
    required this.onConfirm,
  });

  /// The doctor must explain; the patient may skip it.
  final bool reasonRequired;
  final Future<void> Function(String reason) onConfirm;

  @override
  State<CancelAppointmentDialog> createState() =>
      _CancelAppointmentDialogState();
}

class _CancelAppointmentDialogState extends State<CancelAppointmentDialog> {
  final _reason = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy && (!widget.reasonRequired || _reason.text.trim().isNotEmpty);

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_reason.text.trim());
      if (mounted) Navigator.pop(context, true);
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
      title: Text(l10n.apptCancelTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reason,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText:
                    widget.reasonRequired
                        ? l10n.apptCancelReasonRequired
                        : l10n.apptCancelReasonOptional,
              ),
            ),
            if (_error != null)
              Text(
                errorText(context, _error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(l10n.apptCancelKeep),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(l10n.apptCancelButton),
        ),
      ],
    );
  }
}
