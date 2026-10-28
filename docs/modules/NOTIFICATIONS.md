# Module 4 — Notifications + admin dashboard

Django apps: `notifications`, `dashboard` · Flutter: `features/notifications/`, `features/dashboard/`
Conventions (error shape, i18n, pagination, env, licenses): see [`../TEAM_PLAN.md`](../TEAM_PLAN.md). Contracts used here: [`APPOINTMENTS.md`](APPOINTMENTS.md) §5 (`appointment_event`), [`AUTH.md`](AUTH.md).

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Outbox | A receiver of `appointments.signals.appointment_event` inserts `Notification` rows **in the booking / cancel transaction**. A worker sends the emails later. No Celery, no Firebase | TEAM_PLAN §2: a notification is never lost, never created for a failed booking, and a dead SMTP server cannot break a booking |
| No stored text | `Notification` holds `kind` + `data`. The app builds the in-app text from its ARB strings (follows the language switch); the email is rendered by the server when sent, in the recipient's `preferred_language` | TEAM_PLAN §2 |
| Receiver robustness | The receiver only does `bulk_create(ignore_conflicts=True)` on rows it fully built from the event (no lookup that can fail). A raising receiver would roll back the booking, the cancellation **or the patient deactivation** (which emits one `cancelled` event per appointment inside its transaction) | APPOINTMENTS.md §5 |
| Idempotency | `dedupe_key` is unique: `confirmed:<apt>`, `booked:<apt>`, `cancelled:<apt>:<user>`, `reminder:<apt>`. Sending the same event twice, or two worker cycles, never duplicates a row | |
| Who is told what | See §3. Default chosen where the plan was silent: whoever performed a cancel is not notified of their own action; the patient is not told "new booking" (they get the confirmation), the doctor gets no reminder | |
| Admin cancels | For a cancel made by an admin (also the automatic cancels of a deactivated patient **or doctor**) both sides read "**the clinic** cancelled it" (`data.cancelled_by = "admin"`). A manual cancel keeps its reason; the automatic cancels of a deactivation (`automatic=True` in the signal kwargs) drop it, because their reason is a fixed sentence in the admin's language | |
| Detailed emails (owner decision) | Emails keep the doctor's name, the time and the cancel reason. Hardening instead: names are validated at register / profile update / admin doctor creation (no control or format characters such as line breaks and bidi overrides, no `http(s)://` or `www.`, whitespace collapsed); the reason is flattened to one line and shown quoted and attributed: `Reason given by the doctor: "..."` (FR: `Motif indiqué par le médecin : « ... »`) | an email body is text one user influences for another |
| Email flooding | Patient cancellations have their own cap, `THROTTLE_APPOINTMENT_CANCEL` (default `10/day`, per user), because each one emails the doctor (see APPOINTMENTS.md). Read notifications whose email is done are purged after `NOTIFICATION_RETENTION_DAYS` (default 90) by the worker, about once an hour | |
| Deactivated recipients | A deactivated user still gets the `appointment_cancelled` email (that is how a deactivated patient learns it); other kinds are `skipped` for inactive users | |
| Reminder rows | The worker creates them for confirmed appointments with `now < start <= now + REMINDER_MINUTES_BEFORE` (patient **and doctor** active). Before an email goes out it is `skipped` if the appointment started meanwhile (any kind except cancellations), or, for a reminder, was cancelled or has an inactive doctor | |
| Email statuses | `pending` → `sent` \| `failed` (gave up after `NOTIFICATION_MAX_ATTEMPTS`) \| `skipped`. A message the server refuses increments `attempts`, stores `last_error` (class + message, max 300 chars, **never logged**: the log only has the class name) and retries on the next cycle. A **connection-level** failure (refused, unresolvable, timeout, disconnect: `ConnectionError`, `TimeoutError`, other non-SMTP `OSError`, `SMTPServerDisconnected`, `SMTPConnectError`) does **not** count as an attempt and stops the batch (one try per cycle instead of one per pending row), so an SMTP outage never burns the attempts of every pending email; rows simply stay `pending` until the server is back | |
| Row lock | Each email is sent under `select_for_update(skip_locked=True)` on its row, so two workers never double send | |
| Time zone | `data.start_at` is the start in clinic time with its offset (`2026-11-05T10:00:00+01:00`, same shape as the appointments API: an absolute instant whose wall clock the app shows as is). Emails show it as `<date> at <time>` (FR `<date> à <time>`): Django's `DATE_FORMAT` of the recipient's language plus a 24 h `HH:MM`, so it never ends with a period (`Nov. 5, 2026 at 10:00`, `5 novembre 2026 à 10:00`) | |
| Dashboard | Read-only `GET dashboard/stats/` (admin), figures computed in `TIME_ZONE`. `dashboard` has no model | |
| Admin back office | `/admin/` (when enabled) shows notifications read-only | |
| Android build | `flutter_local_notifications` needs core library desugaring (`isCoreLibraryDesugaringEnabled` + `desugar_jdk_libs` in `android/app/build.gradle.kts`) and, in the main `AndroidManifest.xml`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED` and the plugin's two receivers | plugin README |

## 2. Models and settings

`notifications.Notification(user FK, kind, data JSON, dedupe_key unique null, read_at, created_at, email_status, attempts, last_error)`. Kinds: `appointment_confirmed`, `appointment_booked`, `appointment_cancelled`, `appointment_reminder`.

`data` (no FK to appointments, `notifications` stays a leaf):
```json
{ "appointment_id": 41, "start_at": "2026-11-05T10:00:00+01:00", "doctor_name": "Sarah Miller",
  "patient_name": "Amira Ben Salah",
  "cancelled_by": "patient|doctor|admin",   // appointment_cancelled only
  "reason": "Congé" }                        // appointment_cancelled by a patient / doctor, if given
```

Settings (all have defaults; `backend/.env.example` documents them): `NOTIFICATION_POLL_SECONDS=30`, `NOTIFICATION_MAX_ATTEMPTS=5`, `REMINDER_MINUTES_BEFORE=1440`, `NOTIFICATION_RETENTION_DAYS=90`, `THROTTLE_APPOINTMENT_CANCEL=10/day`. Mobile: `NOTIFICATIONS_POLL_SECONDS`, `REMINDER_MINUTES_BEFORE` in `env/*.json` (defaults 30 / 1440 in `core/config/env.dart`; keep the reminder value equal to the backend's).

## 3. Who is notified

| Event | Recipient | Kind | Email subject (EN) |
|---|---|---|---|
| booked | patient | `appointment_confirmed` | Appointment confirmed |
| booked | doctor | `appointment_booked` | New appointment booked |
| cancelled by the patient | doctor | `appointment_cancelled` (`cancelled_by=patient`) | Appointment cancelled |
| cancelled by the doctor | patient | `appointment_cancelled` (`cancelled_by=doctor`, + `reason`) | Appointment cancelled |
| cancelled by an admin (incl. deactivation of the patient or the doctor) | patient **and** doctor | `appointment_cancelled` (`cancelled_by=admin`) | Appointment cancelled |
| start within `REMINDER_MINUTES_BEFORE` | patient | `appointment_reminder` | Appointment reminder |

Templates: `backend/templates/notifications/email/<kind>.txt` (`{% blocktranslate %}`), subjects in `notifications/services.py` (`gettext_lazy`); French in `locale/fr/LC_MESSAGES/django.po` + `.mo`. Plain text, no tokens, passwords or codes.

## 4. Endpoints (all `IsAuthenticated`; everyone sees only their own)

| # | Endpoint | Who | Notes |
|---|---|---|---|
| 1 | `GET notifications/?unread=true` | any logged-in user | paginated, newest first: `{id, kind, data, read_at, created_at}` |
| 2 | `GET notifications/unread-count/` | any | `{"count": 3}` |
| 3 | `POST notifications/{id}/read/` | owner | 200 with the notification; idempotent; someone else's id is `404 not_found` |
| 4 | `POST notifications/read-all/` | any | `{"updated": 2}` |
| 5 | `GET dashboard/stats/` | admin (`403` otherwise) | below |

```json
{ "patients": { "total": 12, "active": 10 },
  "doctors":  { "total": 3,  "active": 3 },
  "appointments": { "total": 40, "today": 4, "this_week": 9,
                    "by_status": { "confirmed": 20, "cancelled": 8, "completed": 10, "no_show": 2 } } }
```
`today` / `this_week` (Monday to Sunday) count appointments of any status that **start** in that period in `TIME_ZONE`; `by_status` covers all appointments ever, every status present. No new error codes.

## 5. Worker

`python manage.py run_notification_worker [--once]` loops every `NOTIFICATION_POLL_SECONDS`: (a) `create_due_reminders`, (b) `send_pending_emails` (oldest first, 100 per cycle, inside `translation.override(user.preferred_language)`). Each loop cycle starts with `django.db.close_old_connections()`, so a database restart or an idle-closed connection is recovered on the next cycle (a one-shot `--once` has a fresh connection). A cycle that raises is logged and the loop continues; the stop signal is also checked between emails; Ctrl+C / SIGTERM stop it after the current cycle. `--once` runs one cycle, always prints `reminders created: N, emails sent: M` (N = rows created by this call, not rows already there) and exits (useful for demos and checks). Run it in its own terminal next to `runserver`.

## 6. Flutter side

```
features/notifications/
  local_reminders.dart                        # LocalReminders (flutter_local_notifications + timezone), localRemindersProvider
  data/models/app_notification.dart           # AppNotification, NotificationKind (unknown-safe)
  data/notifications_repository.dart          # list / unreadCount / markRead / markAllRead
  presentation/notifications_providers.dart   # unreadCountProvider, notificationsListProvider, reminderSyncProvider
  presentation/screens/                       # notifications_screen, notification_texts (kind + data -> ARB text)
  presentation/widgets/                       # notifications_host (poller), notifications_nav_icon (badge)
features/dashboard/                           # repository, DashboardStats, dashboard_screen
```

- **Tabs:** patient and doctor get a Notifications tab (bell with unread badge, `/patient/notifications`, `/doctor/notifications`); the admin home `/admin` is the Dashboard (users list moved to `/admin/users`). A notification opens its appointment (`patientAppointmentRoute` / `doctorAppointmentRoute`) and is marked read.
- **Polling:** `NotificationsHost` (wraps every shell via `ShellScaffold`) runs a `Timer.periodic(NOTIFICATIONS_POLL_SECONDS)` while the app is in the foreground, cancels it when the app goes to the background and refreshes at once on resume. Pull-to-refresh on the list reloads list + badge. When the count **increases** a snackbar ("You have a new notification", with a View action) is shown and the list is reloaded. Polling errors are silent (the last count stays). Admins are not polled.
- **On-device reminders** (patients): `reminderSyncProvider` (watched by the host) calls `LocalReminders.resync(upcomingConfirmed)` every time `upcomingConfirmedProvider` reloads (every booking / cancellation invalidates it) and when the language changes: **cancel all, then schedule again**, notification id = appointment id, `AndroidScheduleMode.inexactAllowWhileIdle` (no exact-alarm permission), at the absolute UTC instant `startAt - REMINDER_MINUTES_BEFORE` (`TZDateTime.from(utc, tz.UTC)`). An appointment that starts sooner than the lead time gets no reminder (it would fire at once, again on every resync). Calls are serialized so a slow resync cannot interleave with a newer one or with logout. The reminder text is in the current language.
- **Permission:** `POST_NOTIFICATIONS` (Android 13+) is requested by `BookingScreen` right after a successful booking (`requestPermission()`; the system shows its dialog only when it can). Refusal = no on-device reminders; email and the in-app list still work.
- **Logout:** `logout()`, `sessionExpired()` and `discardSession()` all call `LocalReminders.cancelAll()` (after the state is cleared; a failing hook never blocks them); the host is disposed with the shell, which stops the timer. `reminderSyncProvider` also cancels everything when the logged-in user is not a patient (leftovers of an earlier session), and `LocalReminders` drops a `resync` that started before a `cancelAll` (a fetch in flight when the session ended).
- **Lock screen:** reminders use `NotificationVisibility.private`; the plugin (17.x) has no "public version", so on a secure lock screen Android shows its generic notification instead of the doctor's name and time. The small icon is the monochrome `ic_stat_reminder` drawable.
- **Polling details:** a stale poll cannot overwrite a count just set by "mark all as read"; the snackbar ignores loading transitions (account switch) and the first load; on an increase the notifications list, the appointments lists and the reminders are reloaded. The dashboard is refreshed after a user (de)activation and a doctor creation.
- **Plugin version:** `flutter_local_notifications` stays on 17.x (what resolves for Flutter 3.29.2 and is in the offline pub cache; newer majors change the scheduling API).

## 7. Tests

Backend (`notifications/tests`, `dashboard/tests`): `test_receiver.py` (who is told what for booked / each cancel actor / deactivation, rollback, idempotency), `test_worker.py` (reminder window and idempotency, FR/EN emails, retries then `failed`, one failure does not block others, skipped cases, cancellation wording, `--once`, connection outages, relevance, purge, close_old_connections), `test_api.py` (401, scoping, filter, 404 on others', read / read-all), `dashboard/tests/test_stats.py` (401/403, empty, counts, time-zone day/week boundaries). Regression for the M2 follow-up in `doctors/tests/test_api.py`.

Mobile (`test/features/notifications`, `test/features/dashboard`): `local_reminders_test.dart` (plan: window / status / lead time; plugin calls: cancel-all first, id = appointment id, UTC instant, inexact mode, serialization), `notifications_repository_test.dart`, `notifications_providers_test.dart` (count, silent failures, list paging / read / read-all, reminder sync on fetch / language change / roles / failed fetch), `notifications_screen_test.dart` (texts FR/EN per role and actor, tap navigation, mark all, load more, empty, error + retry), `notifications_host_test.dart` (foreground polling, snackbar only on increase, timer stopped in the background, resume refresh, admins), `dashboard_test.dart`; `auth_controller_test.dart` checks that logout cancels the reminders. Fakes: `test/support/fake_local_reminders.dart`, `fake_notifications_repository.dart`.

## 8. Not covered by automated tests

The real plugin on a device (actual scheduling, permission dialog, reboot persistence, doze timing) and the real SMTP path are verified by hand with `docs/DEMO.md`.
