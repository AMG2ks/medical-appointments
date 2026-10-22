import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stub owned by M4 (Notifications). Logout calls it so the next person using the phone
/// does not get this user's reminders. M4: replace the body with the real cancellation.
/// A provider, so tests can fake it.
class LocalReminders {
  const LocalReminders();

  Future<void> cancelAll() async {}
}

final localRemindersProvider = Provider<LocalReminders>(
  (ref) => const LocalReminders(),
);
