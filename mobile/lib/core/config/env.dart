/// Build-time configuration, read from `--dart-define-from-file=env/<target>.json`.
/// This is the only place that reads `String.fromEnvironment`; no URL lives in other code.
class Env {
  const Env._();

  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

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
