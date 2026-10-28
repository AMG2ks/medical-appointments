/// Build-time configuration, read from `--dart-define-from-file=env/<target>.json`.
/// This is the only place that reads `String.fromEnvironment`; no URL lives in other code.
class Env {
  const Env._();

  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Last bookable day = today + this many days (same value as the backend's
  /// `BOOKING_HORIZON_DAYS`; the server is the judge, this only limits the date picker).
  static const bookingHorizonDays = int.fromEnvironment(
    'BOOKING_HORIZON_DAYS',
    defaultValue: 30,
  );

  /// Call first in `main()`: stop with a clear message instead of failing on every request.
  static void validate() {
    if (apiBaseUrl.isEmpty) {
      throw StateError(
        'API_BASE_URL is empty. Run with '
        '--dart-define-from-file=env/emulator.json (see mobile/env/example.json).',
      );
    }
  }
}
