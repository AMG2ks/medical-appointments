# Medical Appointments — Team Plan

Esprit university project. Flutter (mobile) + Django REST Framework (backend) + PostgreSQL.
4 members, each owns **one module end-to-end** (Django app + Flutter feature). Duration: week 0 (setup) + 5 weeks. Final demo runs **locally** (laptop backend + Android phone/emulator on the same network, no internet needed).

Two project-wide constraints:
- **Bilingual UI: French + English** (§4.5).
- **Every tool, library and service is free and open source** (§9). Don't add a dependency until it is in the §9 table, and update the table in the same PR.

> Read this whole file once. When something here and your code disagree, fix one of them in the same PR.

---

## 1. Product scope (MVP)

### Patient
- Sign up (email + password), log in, log out, forgot password (code by email).
- View/edit own profile, change password, switch language FR/EN.
- Browse doctors: filter by specialty, search by name; see a doctor's profile.
- See a doctor's free slots for a date, book an appointment (confirmed immediately).
- See upcoming and past appointments; cancel an upcoming one (up to `CANCELLATION_MIN_HOURS` before start).
- Notifications: email (confirmation, cancellation, reminder) in the user's language, in-app notification list with unread badge, and an **on-device reminder** before each appointment.

### Doctor
- Account **created by the admin** (no doctor self-signup). The doctor receives an invite email with a code and sets a password on the "Reset password" screen.
- Edit professional profile (bio, specialty, consultation duration).
- Manage weekly availability (e.g. Mon 09:00–12:00) and time off (date ranges).
- View agenda (today / upcoming / past), cancel an appointment with a reason, mark it completed or no-show.
- Email + in-app notifications for new bookings and cancellations.

### Admin
- Log in (admins are created with `createsuperuser` only).
- Dashboard: counts of patients, doctors, appointments (today, this week, by status).
- Manage specialties; create doctors; list users and activate/deactivate any account.
- Django admin (`/admin/`) is a back-office fallback, off by default (`DJANGO_ADMIN_ENABLED=True` to mount it).

### Explicitly OUT of scope
Payments · video consultation · chat · medical records, prescriptions, file uploads · rescheduling (= cancel + rebook) · waiting lists · ratings/reviews · SMS · **remote push notifications** (no Firebase, see §2 M4) · social login · 2FA · email verification · doctor self-registration / approval workflow · multi-clinic / multi-timezone · recurring appointments · web frontend · offline mode (screens show a clear error instead) · account self-deletion · **hosting/deployment** · **real email delivery** (all mail is captured by Mailpit) · languages other than FR/EN (no Arabic/RTL) · iOS builds (Android-only demo; the Flutter code stays cross-platform).

---

## 2. Modules and ownership

Dependency direction is **one-way** (an app may only import from apps to its left):

```
accounts  <-  doctors  <-  appointments  <-  notifications, dashboard
 (M1)          (M2)          (M3)               (M4)
```

| # | Module | Owner | Django app(s) | Flutter feature folder(s) |
|---|---|---|---|---|
| M1 | Auth & user profiles + shared skeleton + i18n setup | **Aziz** (lead) | `accounts`, `core` | `core/`, `app/`, `l10n/`, `features/auth/`, `features/users_admin/` |
| M2 | Doctors, specialties & availability | TBD — pick one | `doctors` | `features/doctors/` |
| M3 | Appointments booking lifecycle | TBD — pick one | `appointments` | `features/appointments/` |
| M4 | Notifications + admin dashboard + demo runbook | TBD — pick one | `notifications`, `dashboard` | `features/notifications/`, `features/dashboard/` |

Members 2–4: read this plan, then choose M2/M3/M4 among yourselves during week 0 and write your name in this table.

**Why this split is fair:** M1 is light in business logic but carries the shared skeleton, routing, token handling and i18n setup everyone depends on (the lead's extra load). M2 is CRUD-heavy with one real algorithm (working intervals). M3 has the hardest logic (slot computation, double-booking prevention, state transitions) but fewer screens. M4 has a background worker, translated emails, on-device reminders and a small read-only dashboard; with no Firebase to set up, it also owns the LAN demo runbook (`docs/DEMO.md`). Each module has ~6–9 endpoints and ~4–6 screens.

### M1 — Auth & user profiles (Aziz)
Full design: [`docs/modules/AUTH.md`](modules/AUTH.md).
- **Models:** `User` (custom, email login, `role`, `preferred_language`), `PatientProfile`, `PasswordResetCode`.
- **Endpoints:** `/api/v1/auth/register|login|token/refresh|logout|me|password/change|password/reset|password/reset/confirm/`, `/api/v1/users/` (admin).
- **Screens:** splash, login (with language switch), register, forgot/reset password, profile (with language setting), change password, admin users list; the three role shells (bottom-nav containers) and the router.
- **Depends on:** nothing.

### M2 — Doctors & availability
- **Models:** `Specialty(name_fr, name_en unique)`, `DoctorProfile(user OneToOne primary_key, specialty FK, bio, consultation_minutes default 30)`, `WeeklyAvailability(doctor, weekday 0–6, start_time, end_time)`, `TimeOff(doctor, start_at, end_at, reason)`.
  Specialty names are data, not UI strings, so they are stored in both languages and the API returns both (`name_fr`, `name_en`). The app shows the one matching the current locale. `bio` is free text written by the doctor and is not translated.
- **Endpoints:**
  - `GET /api/v1/specialties/` (any logged-in user), `POST/PATCH/DELETE` (admin)
  - `GET /api/v1/doctors/?specialty=&search=` (active doctors only), `GET /api/v1/doctors/{id}/`
  - `POST /api/v1/doctors/` (admin): creates User(role=doctor, no password, `preferred_language` from the payload) + DoctorProfile, then calls `accounts.services.send_password_code(user, purpose="invite")`
  - `GET/PATCH /api/v1/doctors/me/` (doctor)
  - `GET/POST /api/v1/doctors/me/availability/`, `PATCH/DELETE /api/v1/doctors/me/availability/{id}/` (no overlaps per weekday → `availability_overlap`)
  - `GET/POST /api/v1/doctors/me/time-off/`, `DELETE /api/v1/doctors/me/time-off/{id}/`
- **Python contract for M3:** `doctors.services.working_intervals(doctor, date) -> list[tuple[datetime, datetime]]` (timezone-aware, time off already removed).
- **Screens:** doctors list + search/filter, doctor detail ("Book" button opens M3's flow), doctor "my profile", availability editor, time-off list, admin: specialties + create doctor.
- **Depends on:** M1 (User, permissions, `send_password_code`).

### M3 — Appointments
- **Models:** `Appointment(patient FK User, doctor FK DoctorProfile, start_at, end_at, status, reason, cancelled_by FK User null, cancellation_reason, created_at, updated_at)`. Status: `confirmed → cancelled | completed | no_show` (no other transitions).
- **Double booking:** booking runs in a transaction that locks the doctor row (`select_for_update`) and checks overlap, plus a partial `UniqueConstraint(doctor, start_at, condition=status="confirmed")` as a DB backstop.
- **Endpoints:**
  - `GET /api/v1/appointments/slots/?doctor={id}&date=YYYY-MM-DD` → free slots = working intervals cut into `consultation_minutes`, minus booked ones, only within `BOOKING_HORIZON_DAYS` and at least `BOOKING_MIN_LEAD_MINUTES` from now
  - `POST /api/v1/appointments/` (patient) `{doctor, start_at, reason}` → 201; 409 `slot_taken`; 400 `slot_not_available`
  - `GET /api/v1/appointments/?scope=upcoming|past&status=` — patient sees own, doctor sees own agenda, admin sees all (+`doctor`, `patient`, `date` filters)
  - `GET /api/v1/appointments/{id}/` (participant or admin)
  - `POST /api/v1/appointments/{id}/cancel/` `{reason}` (patient until the cutoff → else `cancellation_too_late`; doctor/admin until start)
  - `POST /api/v1/appointments/{id}/complete/`, `/no-show/` (owning doctor, after start; otherwise `invalid_status_transition`)
- **Signal contract for M4:** `appointments.signals.appointment_event` sent with `appointment=` and `event=` (`"confirmed" | "cancelled"`), sent **inside** the booking/cancel transaction.
- **Screens:** booking flow (date picker → slot grid → confirm), my appointments (patient, tabs upcoming/past), appointment detail + cancel, doctor agenda + detail with complete/no-show/cancel.
- **Depends on:** M1, M2 (`working_intervals`, `DoctorProfile`).

### M4 — Notifications + admin dashboard
- **Models:** `Notification(user, kind, data JSON, dedupe_key unique null, read_at, created_at, email_status, attempts, last_error)`.
  No title/body text is stored: the app builds the text from `kind` + `data` with its ARB strings, so the list follows the current language. Emails are rendered by the server in the recipient's `preferred_language`.
- **How it works (outbox pattern, no Celery, no Firebase):**
  1. A receiver of `appointment_event` creates `Notification` rows in the same DB transaction as the booking, so a notification is never lost or created for a booking that failed.
  2. One worker process, `python manage.py run_notification_worker`, loops every `NOTIFICATION_POLL_SECONDS`:
     a. creates reminder rows for confirmed appointments starting within `REMINDER_MINUTES_BEFORE` (`dedupe_key = "reminder:<appointment_id>"` makes it idempotent);
     b. sends pending emails (Django SMTP → Mailpit) inside `translation.override(user.preferred_language)`, marks `sent`/`failed`, retries up to `NOTIFICATION_MAX_ATTEMPTS`.
- **Mobile, no remote push:**
  - **In-app:** poll `unread-count` every `NOTIFICATIONS_POLL_SECONDS` while the app is in the foreground (stop the timer when the app goes to background), refresh on resume and on pull-to-refresh, show a badge plus a snackbar when the count increases.
  - **On-device reminders:** `flutter_local_notifications` schedules a local notification `REMINDER_MINUTES_BEFORE` each upcoming appointment. Every time the upcoming-appointments list is fetched: cancel all scheduled reminders and reschedule them from the server list (notification id = appointment id). Cancellations, reboots and language changes are then handled with no extra logic. Use `inexactAllowWhileIdle` (no exact-alarm permission), schedule at the absolute UTC instant (`timezone` package), ask for `POST_NOTIFICATIONS` (Android 13+) the first time the user books, and cancel all reminders on logout.
- **Endpoints:**
  - `GET /api/v1/notifications/?unread=true`, `GET /api/v1/notifications/unread-count/`
  - `POST /api/v1/notifications/{id}/read/`, `POST /api/v1/notifications/read-all/`
  - `GET /api/v1/dashboard/stats/` (admin)
- **Screens:** notifications list with unread badge, admin dashboard.
- **Depends on:** M1, M3 (read-only on M2 for stats). Mobile: uses M3's appointments repository for reminders.

**Notifications decision:** email (to Mailpit) + in-app list with foreground polling + on-device scheduled reminders. All of it is open source and works offline on a LAN.
Rejected:
- **Firebase Cloud Messaging:** proprietary, needs internet and a Google account.
- **ntfy + UnifiedPush:** open source, but needs an extra server in compose plus a "distributor" app installed on every demo phone, and background delivery is unreliable on some Android builds. That's a lot of setup for something local reminders + polling already show in the demo. M4 can try it as a stretch goal only after week 4.
- **Celery + Redis + beat:** two extra services for one periodic job.
- **Sending email inside the request:** slow, and a failing SMTP would break booking.

---

## 3. Shared data model

```mermaid
erDiagram
    USER ||--o| PATIENT_PROFILE : "has (role=patient)"
    USER ||--o| DOCTOR_PROFILE : "has (role=doctor)"
    USER ||--o{ PASSWORD_RESET_CODE : requests
    SPECIALTY ||--o{ DOCTOR_PROFILE : groups
    DOCTOR_PROFILE ||--o{ WEEKLY_AVAILABILITY : defines
    DOCTOR_PROFILE ||--o{ TIME_OFF : blocks
    USER ||--o{ APPOINTMENT : "books (patient)"
    DOCTOR_PROFILE ||--o{ APPOINTMENT : receives
    USER ||--o{ NOTIFICATION : receives

    USER {
        bigint id PK
        string email UK
        string first_name
        string last_name
        string phone
        string role
        string preferred_language
        bool is_active
    }
    PATIENT_PROFILE {
        bigint user_id PK, FK
        date date_of_birth
    }
    DOCTOR_PROFILE {
        bigint user_id PK, FK
        bigint specialty_id FK
        text bio
        int consultation_minutes
    }
    SPECIALTY {
        bigint id PK
        string name_fr UK
        string name_en UK
    }
    WEEKLY_AVAILABILITY {
        bigint id PK
        bigint doctor_id FK
        int weekday
        time start_time
        time end_time
    }
    TIME_OFF {
        bigint id PK
        bigint doctor_id FK
        datetime start_at
        datetime end_at
    }
    APPOINTMENT {
        bigint id PK
        bigint patient_id FK
        bigint doctor_id FK
        datetime start_at
        datetime end_at
        string status
    }
    NOTIFICATION {
        bigint id PK
        bigint user_id FK
        string kind
        json data
        string dedupe_key UK
        datetime read_at
        string email_status
    }
    PASSWORD_RESET_CODE {
        bigint id PK
        bigint user_id FK
        string purpose
        string code_hash
        datetime expires_at
        int attempts
    }
```

Key rule: **profiles use the user id as their primary key** (`OneToOneField(User, primary_key=True)`). So "doctor 12" is user 12 everywhere: in URLs, in `Appointment.doctor_id`, and in ownership checks (`appointment.doctor_id == request.user.id`).

`Notification` stores the appointment id in `data` (no FK) so `notifications` stays a leaf app.

---

## 4. Shared conventions

### 4.1 Monorepo layout
```
medical-appointments/
├── README.md                 # quickstart (how to run everything)
├── docker-compose.yml        # postgres + mailpit (local dev + demo)
├── scripts/check.py          # THE quality gate: lint + tests, backend + mobile
├── docs/
│   ├── TEAM_PLAN.md   DEMO.md (M4, week 4)
│   └── modules/  AUTH.md  DOCTORS.md  APPOINTMENTS.md  NOTIFICATIONS.md
├── backend/
│   ├── manage.py
│   ├── requirements.txt  requirements-dev.txt
│   ├── pyproject.toml        # ruff + pytest config
│   ├── .env.example          # committed; .env is gitignored
│   ├── conftest.py           # shared pytest fixtures (owned by M1)
│   ├── config/               # settings.py, urls.py, wsgi.py, asgi.py
│   ├── core/                 # exception handler, pagination, seed_demo command
│   ├── accounts/  doctors/  appointments/  notifications/  dashboard/
│   │   └── models.py serializers.py services.py views.py urls.py admin.py tests/
│   ├── templates/<app>/email/  # email templates using {% translate %}
│   └── locale/<lang>/LC_MESSAGES/django.po + django.mo
└── mobile/
    ├── pubspec.yaml  analysis_options.yaml  l10n.yaml
    ├── env/example.json      # committed; env/emulator.json, env/device.json gitignored
    └── lib/
        ├── main.dart
        ├── l10n/             # app_en.arb, app_fr.arb (all UI strings)
        ├── app/              # app.dart, router.dart, theme.dart, shells/
        ├── core/             # config/, network/, storage/, l10n/, widgets/, utils/
        └── features/<feature>/
            ├── data/         # <x>_api.dart, <x>_repository.dart, models/
            └── presentation/ # screens/, widgets/, <x>_providers.dart
```
Backend rules: views stay thin; business rules live in `services.py` (plain functions); never `fields = "__all__"` in serializers; one person per app touches its migrations.

### 4.2 Backend stack
Python 3.12 · Django 5.2 LTS · djangorestframework · djangorestframework-simplejwt · drf-spectacular + **drf-spectacular-sidecar** (serves Swagger UI files locally; the default loads them from a CDN, which fails offline) · django-filter · django-environ · psycopg 3. Dev: pytest, pytest-django, ruff. GNU gettext is needed only by whoever edits backend translations.

### 4.3 API conventions
- Base path **`/api/v1/`**. JSON only. `snake_case` field names.
- Default permission is `IsAuthenticated`; public endpoints say `AllowAny` explicitly.
- Status codes: 200 OK, 201 created, 202 accepted, 204 no body, 400 validation/business rule, 401 not logged in / bad token, 403 wrong role or not your resource, 404, 409 conflict, 429 throttled.
- **One error shape** (produced by `core/exceptions.py`; never build it by hand). Every error carries a **stable `code`** at the top level and per field:
  ```json
  { "error": {
      "code": "validation_error",
      "message": "Données invalides.",
      "fields": { "email": [ { "code": "unique", "message": "Un utilisateur avec ce champ email existe déjà." } ] }
  } }
  ```
  - `fields` is always present (`{}` when not a field error); nested serializers give nested objects.
  - Some business errors add an optional top-level `details` object (only when the app needs data to explain the error, e.g. `time_off_conflict` lists the blocking appointments). `BusinessError(..., details={...})`; absent otherwise.
  - **The app translates by `code`.** `message` is only a fallback: the server localizes it from the `Accept-Language` header, which the app always sends.
  - Business errors: `raise BusinessError("slot_taken", _("This slot is already taken."), status_code=409)` (helper in `core/exceptions.py`).
  - Never catch a Django `ValidationError` and re-raise only its messages: that drops the codes. Let it propagate; DRF keeps the codes.
- **Error code registry** (each module lists its own codes in its module doc and adds an ARB string for each):
  | Kind | Codes |
  |---|---|
  | Generic | `validation_error`, `not_authenticated`, `authentication_failed`, `token_not_valid`, `permission_denied`, `not_found`, `throttled`, `parse_error`; client-only: `network_error`, `server_error` |
  | Field (DRF/Django) | `required`, `blank`, `null`, `invalid`, `unique`, `max_length`, `min_length`, `invalid_choice`, `password_too_short`, `password_too_common`, `password_entirely_numeric`, `password_too_similar`, `min_value`, `max_value`, `does_not_exist`, `incorrect_type` |
  | M1 Auth | `invalid_code`, `cannot_deactivate_self`, `date_in_future` |
  | M2 Doctors | `availability_overlap`, `specialty_in_use` |
  | M3 Appointments | `slot_taken`, `slot_not_available`, `cancellation_too_late`, `invalid_status_transition`, `booking_limit_reached`, `time_off_conflict` (returned by M2's `POST doctors/me/time-off/`) |
- **Pagination** on every list: `?page=2`, `page_size` 20 (max 100) → `{ "count", "next", "previous", "results" }`.
- **Dates/times:** `USE_TZ = True`, `TIME_ZONE = APP_TIME_ZONE` (default `Africa/Tunis`). Store UTC, return ISO 8601 with offset (`2026-11-03T09:00:00+01:00`). Dates `YYYY-MM-DD`. Availability times are wall-clock in `APP_TIME_ZONE`. The app formats dates with `intl` in the current locale.
- **Docs:** drf-spectacular → Swagger UI at `/api/docs/`, schema at `/api/schema/`. Every view has a serializer (or `@extend_schema`) so it shows correctly.

### 4.4 Flutter stack
- **Flutter 3.29.2** (the version CI uses; check with `flutter --version`). No version manager is required, just install that version.
- **State:** `flutter_riverpod` (plain `Notifier`/`AsyncNotifier`, **no code generation**). `AsyncValue` gives loading/error/data for every screen. Rejected: Bloc (too much boilerplate for 5 weeks), GetX (hidden magic, hard to test).
- **HTTP:** `dio`. Use the one shared authenticated client from `core/network`: it adds the auth header, `Accept-Language` and token refresh for you.
- **Routing:** `go_router`, with role-based redirects (owned by M1).
- **Storage:** `flutter_secure_storage` for tokens only; `shared_preferences` for the non-secret language choice. Never store tokens in `shared_preferences`.
- **Local notifications:** `flutter_local_notifications` + `timezone` (M4).
- JSON: hand-written `fromJson`/`toJson` (no build_runner).
- Every screen handles loading, error (with retry) and empty states using the shared `AsyncValueView` widget.
- No runtime downloads (no `google_fonts`, no network images from the internet): the demo must work offline.
- Lints: `flutter_lints`; `dart format`.

### 4.5 Internationalization (FR + EN)
**Mobile (official Flutter i18n):**
- `flutter_localizations` + `intl` + `gen-l10n`: `l10n.yaml`, ARB files `lib/l10n/app_en.arb` (template) and `lib/l10n/app_fr.arb`. Strings are accessed via `AppLocalizations.of(context)`.
- **No hardcoded user-visible string in widgets.** Every label, button, error and notification text is an ARB key.
- Key naming: module prefix + camelCase (`authLoginTitle`, `doctorsSearchHint`, `apptSlotTaken`, `errorUnique`). Keep keys grouped by module in the file. On a merge conflict in an ARB file, keep both sides and re-run `flutter gen-l10n`.
- Error translation: `core/l10n/error_text.dart` maps an `ApiException` / field error `code` to an ARB string; unknown code → server `message` → generic error string.
- Language switcher and stored preference: owned by M1 (see AUTH.md §6.6). Default = device language if `fr` or `en`, otherwise `fr`.
- Dates, times and weekday names come from `intl` with the current locale, never hand-built.

**Backend (Django i18n):**
- `USE_I18N = True`, `LANGUAGE_CODE = "fr"`, `LANGUAGES = [("fr", "Français"), ("en", "English")]`, `LOCALE_PATHS = [BASE_DIR / "locale"]`, `LocaleMiddleware` enabled (API fallback `message`s follow `Accept-Language`; Django and DRF already ship French translations of their built-in messages).
- `User.preferred_language` (`fr`/`en`) decides the language of every email: send inside `translation.override(user.preferred_language)`. Templates use `{% load i18n %}` / `{% blocktranslate %}`; subjects and custom messages use `gettext` / `gettext_lazy`.
- Source strings in English; French in `locale/fr/LC_MESSAGES/django.po`. Whoever changes translated strings runs `makemessages -l fr` and `compilemessages` (needs GNU gettext) and **commits both `.po` and `.mo`**, so teammates without gettext (Windows) still get translations.

### 4.6 Config and secrets
- Backend: `backend/.env` (gitignored), `backend/.env.example` committed with every key and safe dev values. Settings read env via django-environ and **fail at startup** if `SECRET_KEY` or `DATABASE_URL` is missing.
- Mobile: `flutter run --dart-define-from-file=env/<target>.json`. Read values only in `core/config/env.dart` (`String.fromEnvironment` / `int.fromEnvironment`). **No URL is ever hardcoded in Dart code.**
- No secret ever goes in the app (everything in the APK is public) or in git.

`backend/.env.example` (each module adds its keys in its first PR):
```
DEBUG=False
SECRET_KEY=            # required: 50+ random chars, generate with get_random_secret_key (see README); never committed
ALLOWED_HOSTS=localhost,127.0.0.1,10.0.2.2
DATABASE_URL=postgres://medapp:medapp@localhost:5432/medapp
POSTGRES_USER=medapp
POSTGRES_PASSWORD=medapp
POSTGRES_DB=medapp
APP_TIME_ZONE=Africa/Tunis
# auth (M1)
JWT_ACCESS_MINUTES=15
JWT_REFRESH_DAYS=7
PASSWORD_RESET_CODE_TTL_MINUTES=15
PASSWORD_INVITE_CODE_TTL_HOURS=72
THROTTLE_LOGIN=10/min
THROTTLE_REGISTER=10/hour
THROTTLE_PASSWORD_RESET=5/hour
THROTTLE_PASSWORD_RESET_CONFIRM=20/hour
THROTTLE_APPOINTMENT_WRITE=20/hour
RESET_MAX_FAILED_ATTEMPTS_PER_DAY=10
DJANGO_ADMIN_ENABLED=False
SEED_DEMO_PASSWORD=     # set a real password before running seed_demo
# email (M1 + M4) -> Mailpit
EMAIL_HOST=localhost
EMAIL_PORT=1025
EMAIL_USE_TLS=False
EMAIL_TIMEOUT=10
DEFAULT_FROM_EMAIL=MedApp <no-reply@medapp.local>
# appointments (M3)
BOOKING_HORIZON_DAYS=30
BOOKING_MIN_LEAD_MINUTES=60
CANCELLATION_MIN_HOURS=24
MAX_UPCOMING_APPOINTMENTS_PER_PATIENT=5
# notifications (M4)
NOTIFICATION_POLL_SECONDS=30
NOTIFICATION_MAX_ATTEMPTS=5
REMINDER_MINUTES_BEFORE=1440
```

`mobile/env/example.json`:
```json
{ "API_BASE_URL": "http://10.0.2.2:8000", "NOTIFICATIONS_POLL_SECONDS": 30, "REMINDER_MINUTES_BEFORE": 1440 }
```

### 4.7 Local dev and LAN demo
- **Containers:** `docker compose up -d` (or `podman compose up -d`) starts **Postgres 16** (port 5432, named volume) and **Mailpit** (SMTP 1025, inbox at http://localhost:8025, where every email lands). Use Docker Engine (Linux), Podman Desktop or Rancher Desktop (Windows/macOS). **Not Docker Desktop**: it is proprietary. Without containers, install PostgreSQL natively and run the single Mailpit binary.
- **Backend:** virtualenv, `pip install -r requirements-dev.txt`, `python manage.py migrate`, `python manage.py seed_demo`, `python manage.py runserver --insecure 0.0.0.0:8000` (`--insecure` because `DEBUG=False` stops Django serving the Swagger static files; dev only) (`0.0.0.0` so phones can reach it).
- **Worker** (M4) in a second terminal: `python manage.py run_notification_worker`.
- **Reaching the backend from the app:**
  | Target | `API_BASE_URL` in env file | Backend `.env` |
  |---|---|---|
  | Android emulator | `http://10.0.2.2:8000` (`env/emulator.json`); 10.0.2.2 is the emulator's alias for the laptop | `10.0.2.2` in `ALLOWED_HOSTS` |
  | Physical Android phone | `http://<laptop LAN IP>:8000` (`env/device.json`); find the IP with `ip addr` / `ipconfig` | add the LAN IP to `ALLOWED_HOSTS` |
  - Phone and laptop must be on the same network, and the laptop firewall must allow inbound TCP 8000. University Wi-Fi often blocks device-to-device traffic: use the **laptop's or a phone's hotspot** instead.
  - Plain HTTP is allowed only in `android/app/src/debug/AndroidManifest.xml`, so **demo with a debug build** (`flutter run`). Release/profile builds will refuse `http://`.
- **Fully offline:** once dependencies and container images are downloaded, nothing needs internet (no CDN, no Firebase, no real SMTP, no web fonts). M4 writes `docs/DEMO.md` in week 4 and the team rehearses once **with internet off**.
- `seed_demo` creates demo users (1 admin, 2 doctors, 2 patients, mixed `preferred_language`, password from `SEED_DEMO_PASSWORD`), specialties, availability and a few appointments. Each app provides `seed.py` with a `run()` function; the command calls them in dependency order.
- Demo tip: set `REMINDER_MINUTES_BEFORE` (backend `.env` and mobile env file) to something just under `BOOKING_MIN_LEAD_MINUTES` so a reminder fires a few minutes after booking.

### 4.8 Tests and the quality gate
- Backend: pytest + pytest-django against the real Postgres from compose (no SQLite: partial constraints and `select_for_update` must be tested for real). Use the shared fixtures in `backend/conftest.py`.
- Mobile: `flutter test` for providers, repositories (with a fake), interceptors and key form widgets.
- **`python scripts/check.py`** is the single gate, the same on Linux/Windows/macOS. It runs `ruff check`, `ruff format --check`, `pytest`, `flutter gen-l10n` (fails if the untranslated-messages file lists any key missing in FR or EN), `dart format --set-exit-if-changed`, `flutter analyze` and `flutter test`, then prints PASS/FAIL per step and exits non-zero if any step failed. It works offline.
- CI is optional. If the repo is on GitHub, a small GitHub Actions workflow may run `scripts/check.py` on PRs. Actions is free but **not open source**, so it is a convenience, never the gate (§9).

---

## 5. Git workflow
- `main` is protected: PR required, **1 approval**, no direct pushes, squash merge.
- Before requesting review, the author runs `python scripts/check.py` and pastes the summary in the PR. The reviewer checks out the branch and runs it too before approving.
- Branches: `feat/<module>-<short-desc>`, `fix/<module>-<short-desc>` (e.g. `feat/auth-login`, `fix/appointments-double-booking`).
- Commits: Conventional Commits with the module as scope: `feat(auth): add login endpoint`, `fix(doctors): reject overlapping availability`, `test(appointments): ...`, `docs: ...`, `chore: ...`.
- Keep PRs small (< ~400 changed lines), one topic each. Rebase on `main` at least daily.
- Review rotation: M1 ← reviewed by M2, M2 ← M3, M3 ← M4, M4 ← M1. A PR that changes a contract (endpoint shape, error code, signal, shared fixture, `core/`) also needs the consumer's approval.
- **Migrations:** never edit another app's migrations; never edit a merged migration; if two PRs create migrations in the same app, the second rebases and regenerates.
- Never commit `.env`, `mobile/env/*.json` other than `example.json`, or `build/` folders.

---

## 6. Integration contracts (so everyone starts on day 1)

What M1 merges in **week 0**, usable immediately:

**Backend**
| Contract | Location | Usage |
|---|---|---|
| User model | `accounts.models.User`; FKs use `settings.AUTH_USER_MODEL` | `User.Role.PATIENT / DOCTOR / ADMIN`; `user.preferred_language` |
| Permission classes | `accounts.permissions` | `IsPatient`, `IsDoctor`, `IsAdmin`; combine with DRF operators: `permission_classes = [IsPatient \| IsAdmin]` |
| User summary serializer | `accounts.serializers.UserSummarySerializer` | `{id, first_name, last_name, email, phone}` to embed a patient/doctor in your responses |
| Create user | `accounts.services.create_user(*, email, first_name, last_name, role, phone="", preferred_language=None, password=None)` | M2 creates doctors (no password → unusable) |
| Invite / reset email | `accounts.services.send_password_code(user, purpose="invite" \| "reset")` | M2 sends the doctor invite |
| Business errors | `core.exceptions.BusinessError(code, message, status_code=400, details=None)`; `details` (optional dict) comes out as `error.details` | every module |
| Test fixtures | `backend/conftest.py` | `api_client`, `patient`, `doctor` (with a `DoctorProfile` once M2 merges), `admin_user`, `auth_client(user)` (uses `force_authenticate`, no JWT needed) |
| Login | `POST /api/v1/auth/login/` works from week 0 | get a real token for Swagger / Flutter |

**Mobile**
| Contract | Location |
|---|---|
| Authenticated HTTP client | `dioProvider` in `core/network/api_client.dart`: just `ref.watch(dioProvider)`, never create your own `Dio` |
| Errors | `ApiException { statusCode, code, message, fields, details }` (`details` = optional `error.details`) in `core/network/api_exception.dart`; text via `errorText(context, e)` in `core/l10n/error_text.dart` |
| Current user | `currentUserProvider` → `User?` with `role` (`UserRole.patient/doctor/admin`) and `preferredLanguage`; `currentUserIdProvider` → `int?` |
| Current locale | `localeControllerProvider` (`core/l10n/locale_controller.dart`) |
| Role shells | `app/shells/patient_shell.dart`, `doctor_shell.dart`, `admin_shell.dart`: add your tab/route in `app/router.dart` in your PR |
| Shared widgets | `core/widgets/async_value_view.dart`, `core/utils/date_format.dart` (locale-aware) |
| Logout hook | `authController.logout()` calls `LocalReminders.cancelAll()` (`features/notifications/local_reminders.dart`, real since M4); notification polling lives in `NotificationsHost`, which only exists inside a logged-in shell, so it stops on logout |

**Working in parallel with stubs**
- Week 0: each owner writes `docs/modules/<MODULE>.md` (models, endpoints, example JSON, error codes) and the consumers review it. Contracts first, code second.
- Backend: M3 can call `doctors.services.working_intervals` from day 1 because M2's **first** PR (week 1, day 1–2) is models + this function. M4 can test its receiver by sending `appointment_event` manually in tests.
- Mobile: depend on the *repository* of another feature, and swap in a fake until the endpoint exists: `ProviderScope(overrides: [doctorsRepositoryProvider.overrideWithValue(FakeDoctorsRepository())])`. Dart classes are implicit interfaces (`class FakeDoctorsRepository implements DoctorsRepository`), so no extra abstract class is needed.
- Every user-scoped provider must `ref.watch(currentUserIdProvider)` (not the whole user) so its data resets on logout without reloading on every profile edit.

---

## 7. Milestones

The project starts next week. The demo date is not set yet, so milestones are relative.
> **TODO (lead):** fill in calendar dates once the demo date is known. Week 0 = ____ to ____, Week 1 = ____ … Week 5 / demo = ____.

| Week | Aziz (M1 Auth) | M2 Doctors | M3 Appointments | M4 Notifications + dashboard |
|---|---|---|---|---|
| **0 — setup (2–3 days)** | Repo + branch protection, compose, `.env.example`, `scripts/check.py`, Django project + `core` (errors, `BusinessError`, pagination, Swagger with sidecar, i18n settings), **`User` model + first migration**, permissions, `conftest.py`, default login/refresh; Flutter app with folder layout, env config, gen-l10n + empty ARB files, dio client, router + empty role shells; README quickstart | Pick module; run the stack; write `DOCTORS.md`; review skeleton PR | Pick module; run the stack; write `APPOINTMENTS.md` (slot rules, statuses, error codes); review | Pick module; run the stack; write `NOTIFICATIONS.md` (kinds, email templates, reminder rules); review |
| **1** | Register, login (+user in response), me GET/PATCH (incl. `preferred_language`), logout, refresh rotation; Flutter: token storage, refresh interceptor, auth controller, splash/login/register, language switcher + locale controller | Models + migrations + `working_intervals` (first PR, early!), specialties CRUD, doctors list/detail, admin create doctor | Appointment model + constraints, slots endpoint, booking endpoint with locking | Notification model, `appointment_event` receiver, worker sending translated emails to Mailpit, FR/EN email templates |
| **2** | Change password, reset request/confirm + `send_password_code` (FR/EN emails); Flutter: forgot/reset, profile (with language setting), change password | Availability + time-off endpoints; Flutter: doctors list/search, doctor detail | List/detail/cancel/complete/no-show; Flutter: booking flow | Reminders in worker, notifications list/read/unread-count endpoints; Flutter: notifications screen + badge + foreground polling |
| **3** | Admin users list/activate; throttling; Flutter: admin users screen, `error_text.dart` covering all registry codes | Flutter: doctor profile, availability editor, time off, admin specialties + create doctor | Flutter: patient "my appointments", doctor agenda, detail actions | On-device reminders (`flutter_local_notifications`, resync on fetch, cancel on logout); dashboard stats endpoint + Flutter dashboard |
| **4 — integration** | Run end-to-end flows in **both languages** across roles, fix contract mismatches, complete `seed_demo`. **Feature freeze at end of week.** | Same | Same | Same + write `docs/DEMO.md` (LAN/hotspot setup, offline checklist) |
| **5 — polish & demo** | Bug fixes, missing translations, test gaps, docs, offline demo rehearsal, report/slides | Same | Same | Same |

End-to-end demo flows that must work by end of week 4 (on a physical phone over LAN, internet off):
1. Admin creates doctor → invite email (doctor's language) in Mailpit → doctor sets password with the code → sets availability.
2. Patient signs up in French → finds doctor → books slot → confirmation emails to both, in-app notification for the doctor.
3. On-device reminder fires before the appointment; the reminder email is in Mailpit.
4. Patient switches the app to English → notification list and dates now in English. Patient cancels → doctor notified. Doctor marks a past appointment completed.
5. Admin deactivates a user → that user is logged out on their next request.

---

## 8. Definition of done (every PR)
- [ ] Endpoint(s) visible and correct in Swagger (`/api/docs/`), and the module doc updated (including new error codes).
- [ ] Tests: happy path + validation error + wrong role (403) + anonymous (401) + not-your-resource (403/404) for each endpoint; business rules tested; error responses assert the `code`, not the message.
- [ ] `python scripts/check.py` passes (summary pasted in the PR).
- [ ] Migrations included and they run on a fresh DB.
- [ ] **No hardcoded user-visible strings**: every UI text is in both `app_en.arb` and `app_fr.arb`; every new error code has an ARB string; backend email/user-facing text is wrapped in `gettext` with the French `.po`/`.mo` updated.
- [ ] Screens checked in both FR and EN (no overflow with longer French text).
- [ ] No hardcoded URLs, secrets or limits: new settings added to `.env.example` / `env/example.json`.
- [ ] Every new screen shows loading, error (with retry) and empty states; no tokens or personal data printed in logs.
- [ ] Any new dependency is free/open source and added to the §9 table.
- [ ] Reviewed and approved by one teammate.

---

## 9. Tooling & licenses

Rule: everything the app uses is **free and open source** (OSI-approved license). Check before adding anything.

| Area | Tool | License |
|---|---|---|
| Database | PostgreSQL 16 | PostgreSQL License |
| Dev mail server | Mailpit | MIT |
| Containers | Docker Engine (Moby) / Podman / Podman Desktop / Rancher Desktop | Apache-2.0 |
| Language | Python 3.12 | PSF-2.0 |
| Backend | Django | BSD-3-Clause |
| | djangorestframework | BSD-3-Clause |
| | djangorestframework-simplejwt | MIT |
| | drf-spectacular / drf-spectacular-sidecar (bundles Swagger UI, Apache-2.0) | BSD-3-Clause |
| | django-filter | BSD-3-Clause |
| | django-environ | MIT |
| | psycopg 3 | LGPL-3.0 |
| Backend dev | pytest | MIT |
| | pytest-django | BSD-3-Clause |
| | ruff | MIT |
| | GNU gettext (translators only) | GPL-3.0 |
| Mobile | Flutter SDK / Dart, `flutter_localizations` | BSD-3-Clause |
| | flutter_riverpod | MIT |
| | go_router | BSD-3-Clause |
| | dio | MIT |
| | flutter_secure_storage | BSD-3-Clause |
| | shared_preferences | BSD-3-Clause |
| | intl | BSD-3-Clause |
| | flutter_local_notifications | BSD-3-Clause |
| | timezone | BSD-2-Clause |
| Mobile dev | flutter_lints | BSD-3-Clause |
| | mocktail | MIT |
| JDK for Android builds | OpenJDK (e.g. Eclipse Temurin) | GPL-2.0 with Classpath Exception |
| Editor (suggested) | VSCodium + Dart/Flutter extensions from Open VSX | MIT |
| Version control | Git | GPL-2.0 |
| Diagrams in docs | Mermaid | MIT |

Known exceptions (free, not open source; flagged honestly):
- **Android SDK / build-tools / emulator** binaries are distributed under the *Android SDK License* (built from Apache-2.0 AOSP sources). They can't be avoided when building an Android app with Flutter.
- **Git hosting:** GitHub and GitHub Actions are free but proprietary. They are optional collaboration services, not part of the app; the gate is `scripts/check.py`. The fully open-source alternative is **Codeberg** (Forgejo, GPL-3.0). See open questions.
- Docker Desktop, Android Studio and VS Code (Microsoft build) are not open source: use the alternatives above. Android Studio is acceptable only if you need it for the emulator's GUI, under the same exception as the SDK.

Removed from the design for this rule: Firebase Cloud Messaging (proprietary). Real SMTP providers such as Gmail are not needed because all mail goes to Mailpit.

---

## 10. Open questions (lead to decide)
1. **Git hosting:** does Esprit require GitHub? If not, Codeberg keeps the whole toolchain open source. Either way the PR workflow in §5 stays the same.
2. Is the Android SDK exception in §9 acceptable to the teacher (no open-source way to build Android apps without it)?
