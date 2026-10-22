import 'package:flutter_test/flutter_test.dart';
import 'package:medical_appointments/core/l10n/error_text.dart';
import 'package:medical_appointments/core/network/api_exception.dart';
import 'package:medical_appointments/l10n/gen/app_localizations_en.dart';
import 'package:medical_appointments/l10n/gen/app_localizations_fr.dart';

void main() {
  final en = AppLocalizationsEn();
  final fr = AppLocalizationsFr();

  test('known codes use the ARB text in both languages', () {
    const e = ApiException(
      code: 'authentication_failed',
      message: 'server text',
    );
    expect(errorTextFor(en, e), en.errorAuthenticationFailed);
    expect(errorTextFor(fr, e), fr.errorAuthenticationFailed);
    expect(en.errorAuthenticationFailed, isNot(fr.errorAuthenticationFailed));
  });

  test('every Auth code of the registry has a text', () {
    for (final code in [
      'validation_error',
      'not_authenticated',
      'authentication_failed',
      'token_not_valid',
      'permission_denied',
      'not_found',
      'throttled',
      'parse_error',
      'network_error',
      'server_error',
      'invalid_code',
      'cannot_deactivate_self',
      'date_in_future',
    ]) {
      final e = ApiException(code: code, message: 'SERVER');
      expect(errorTextFor(en, e), isNot('SERVER'), reason: code);
    }
  });

  test('an unknown code shows the server message', () {
    const e = ApiException(code: 'brand_new_code', message: 'Server says no.');
    expect(errorTextFor(en, e), 'Server says no.');
  });

  test('nothing known gives the generic text', () {
    expect(
      errorTextFor(fr, const ApiException(code: 'brand_new_code')),
      fr.errorGeneric,
    );
    expect(errorTextFor(fr, StateError('boom')), fr.errorGeneric);
    expect(errorTextFor(fr, null), fr.errorGeneric);
  });

  test(
    'a validation error with only non-field errors uses that error code',
    () {
      const e = ApiException(
        code: 'validation_error',
        fields: {
          'non_field_errors': [
            ApiFieldError(code: 'invalid_choice', message: 'x'),
          ],
        },
      );
      expect(errorTextFor(fr, e), fr.errorInvalidChoice);
      const mixed = ApiException(
        code: 'validation_error',
        fields: {
          'non_field_errors': [
            ApiFieldError(code: 'invalid_choice', message: 'x'),
          ],
          'email': [ApiFieldError(code: 'required', message: 'x')],
        },
      );
      expect(errorTextFor(fr, mixed), fr.errorValidation);
    },
  );

  test('field errors use the same registry', () {
    const field = ApiFieldError(code: 'password_too_short', message: 'x');
    expect(fieldErrorTextFor(fr, field), fr.errorPasswordTooShort);
  });
}
