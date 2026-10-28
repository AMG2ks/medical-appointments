import 'package:flutter/material.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../network/api_exception.dart';

/// Registry code -> ARB text (TEAM_PLAN 4.3). Each module adds its own codes here
/// together with the ARB keys. Unknown code: the caller falls back to the server message.
String? _knownCode(AppLocalizations l10n, String code) {
  return switch (code) {
    // generic
    'validation_error' => l10n.errorValidation,
    'not_authenticated' => l10n.errorNotAuthenticated,
    'authentication_failed' => l10n.errorAuthenticationFailed,
    'token_not_valid' => l10n.errorTokenNotValid,
    'permission_denied' => l10n.errorPermissionDenied,
    'not_found' => l10n.errorNotFound,
    'throttled' => l10n.errorThrottled,
    'parse_error' => l10n.errorParse,
    'network_error' => l10n.errorNetwork,
    'server_error' => l10n.errorServer,
    // fields (DRF / Django)
    'required' => l10n.errorRequired,
    'blank' => l10n.errorBlank,
    'null' => l10n.errorNull,
    'invalid' => l10n.errorInvalid,
    'unique' => l10n.errorUnique,
    'max_length' => l10n.errorMaxLength,
    'min_length' => l10n.errorMinLength,
    'invalid_choice' => l10n.errorInvalidChoice,
    'password_too_short' => l10n.errorPasswordTooShort,
    'password_too_common' => l10n.errorPasswordTooCommon,
    'password_entirely_numeric' => l10n.errorPasswordEntirelyNumeric,
    'password_too_similar' => l10n.errorPasswordTooSimilar,
    'min_value' => l10n.errorMinValue,
    'max_value' => l10n.errorMaxValue,
    'does_not_exist' => l10n.errorDoesNotExist,
    'incorrect_type' => l10n.errorIncorrectType,
    // M1 Auth
    'invalid_code' => l10n.errorInvalidCode,
    'cannot_deactivate_self' => l10n.errorCannotDeactivateSelf,
    'date_in_future' => l10n.errorDateInFuture,
    // M2 Doctors
    'availability_overlap' => l10n.errorAvailabilityOverlap,
    'specialty_in_use' => l10n.errorSpecialtyInUse,
    _ => null,
  };
}

/// Text for a whole error: known code -> ARB text, else the server message, else generic.
String errorTextFor(AppLocalizations l10n, Object? error) {
  if (error is ApiException) {
    // Only non-field errors: the useful text is the code of that error.
    final nonField =
        error.fields.length == 1 ? error.fieldError('non_field_errors') : null;
    if (error.code == 'validation_error' && nonField != null) {
      return fieldErrorTextFor(l10n, nonField);
    }
    return _knownCode(l10n, error.code) ??
        (error.message.isNotEmpty ? error.message : l10n.errorGeneric);
  }
  return l10n.errorGeneric;
}

/// Text for one field error (same registry; unknown code -> its server message).
String fieldErrorTextFor(AppLocalizations l10n, ApiFieldError error) {
  return _knownCode(l10n, error.code) ??
      (error.message.isNotEmpty ? error.message : l10n.errorGeneric);
}

/// `errorText(context, e)`: use it for snackbars and banners.
String errorText(BuildContext context, Object? error) =>
    errorTextFor(AppLocalizations.of(context), error);

/// Server error of [field] under an input, or null: `errorText: fieldError(context, e, 'email')`.
String? fieldError(BuildContext context, ApiException? error, String field) {
  final fieldError = error?.fieldError(field);
  return fieldError == null
      ? null
      : fieldErrorTextFor(AppLocalizations.of(context), fieldError);
}

/// Snackbar for an error. Skipped when it is a validation error whose fields are all
/// shown under inputs ([inlineFields]).
void showApiError(
  BuildContext context,
  Object error, {
  Set<String> inlineFields = const {},
}) {
  if (error is ApiException &&
      error.code == 'validation_error' &&
      error.fields.isNotEmpty &&
      error.fields.keys.every(inlineFields.contains)) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorText(context, error))));
}
