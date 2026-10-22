import 'package:medical_appointments/l10n/gen/app_localizations.dart';

/// Client-side checks (UX only; the server validates again). Return a translated message.
const minPasswordLength = 8;

String? validateRequired(AppLocalizations l10n, String? value) =>
    (value == null || value.trim().isEmpty) ? l10n.validationRequired : null;

String? validateEmail(AppLocalizations l10n, String? value) {
  if (value == null || value.trim().isEmpty) return l10n.validationRequired;
  final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());
  return valid ? null : l10n.validationEmail;
}

String? validateNewPassword(AppLocalizations l10n, String? value) {
  if (value == null || value.isEmpty) return l10n.validationRequired;
  return value.length < minPasswordLength
      ? l10n.validationPasswordLength
      : null;
}

String? validateConfirm(AppLocalizations l10n, String? value, String password) {
  if (value == null || value.isEmpty) return l10n.validationRequired;
  return value == password ? null : l10n.validationPasswordMismatch;
}
