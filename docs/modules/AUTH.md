# Module 1 — Auth & user profiles

Owner: **Aziz** · Django apps: `accounts` (+ shared `core`) · Flutter: `core/`, `app/`, `l10n/`, `features/auth/`, `features/users_admin/`
Conventions (error shape and codes, i18n, pagination, env, git, licenses): see [`../TEAM_PLAN.md`](../TEAM_PLAN.md).

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| User model | Custom `accounts.User`, email as login, `role` and `preferred_language` fields. `AUTH_USER_MODEL = "accounts.User"` **in the first commit, before the first `migrate`** | Changing the user model after migrations exist is painful; every other app's FKs point at it |
| Roles | One `role` field: `patient` / `doctor` / `admin` | A user has exactly one role; simpler than Django groups |
| Language | `preferred_language` (`fr`/`en`) on `User`: the server uses it for emails, the app syncs it with its language switcher | Emails (reset, invite, M4 notifications) are sent when the user isn't looking at the app, so the server must know the language |
| Profiles | `PatientProfile` is owned by Auth (created at sign-up). `DoctorProfile` is owned by **Doctors (M2)**. Both use `user` as primary key | Doctor data (specialty, availability) belongs with doctor logic; shared ids avoid id confusion |
| Sign-up | Patients self-register. Doctors are created by an admin (M2 endpoint) with no password and receive an **invite code** by email. Admins come from `createsuperuser` | No approval workflow to build; the doctor reuses the reset-password screen to set a password |
| Tokens | `djangorestframework-simplejwt`: access 15 min, refresh 7 days, **rotation + blacklist** | Stateless access, revocable refresh, standard library (MIT) |
| Password reset | 6-digit code by email, typed into the app (no links) | Links need deep links or a web page; a code works on any phone, offline on a LAN |
| Email verification | **Out of scope** (confirmed) | Saves ~2 days; not needed for the demo |
| Email sending | Auth sends its own emails directly with Django `send_mail` (not through M4's worker), to Mailpit | Auth must not depend on the Notifications module; the reset email must be immediate |
| Rejected | dj-rest-auth / Djoser (black box, hard to adapt to codes; you learn less); DRF `TokenAuthentication` (tokens never expire) | |

---

## 2. Data model (`accounts/models.py`)

```python
class User(AbstractUser):
    class Role(models.TextChoices):
        PATIENT = "patient"; DOCTOR = "doctor"; ADMIN = "admin"

    class Language(models.TextChoices):
        FR = "fr", "Français"; EN = "en", "English"

    username = None
    email = models.EmailField(unique=True)          # stored lowercase
    phone = models.CharField(max_length=20, blank=True, validators=[phone_validator])  # ^\+?[0-9]{8,15}$
    role = models.CharField(max_length=10, choices=Role.choices, default=Role.PATIENT, db_index=True)
    preferred_language = models.CharField(max_length=2, choices=Language.choices, default=Language.FR)

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = ["first_name", "last_name"]
    objects = UserManager()
```
- `UserManager` (subclass `BaseUserManager`):
  - `create_user(email, password=None, **extra)`: lowercases email; `password=None` → `set_unusable_password()`.
  - `create_superuser(...)`: forces `role=ADMIN`, `is_staff=True`, `is_superuser=True`.
  - `get_by_natural_key(email)`: `get(email__iexact=email)`. This makes login case-insensitive everywhere (API and Django admin) in one place.
- `User.save()` keeps `is_staff = (role == ADMIN)` so Django admin access follows the role.
- `PatientProfile(user = OneToOneField(User, primary_key=True, related_name="patient_profile"), date_of_birth = DateField(null=True, blank=True))`. Add fields only when a screen uses them. **No medical data** in this table.
- `PasswordResetCode(user FK, purpose ["reset"|"invite"], code_hash, created_at, expires_at, attempts PositiveSmallInteger=0, used_at null)`. The code is stored with `make_password()`, never in clear.
- `accounts/admin.py`: register `User` with a `UserAdmin` adapted to email (no `username` in fieldsets/ordering). Creating doctors in Django admin would skip `DoctorProfile`, so create doctors through the app/API.

---

## 3. Settings (`config/settings.py`, Auth + shared part)

```python
AUTH_USER_MODEL = "accounts.User"
INSTALLED_APPS += ["rest_framework", "rest_framework_simplejwt.token_blacklist",
                   "drf_spectacular", "drf_spectacular_sidecar", "django_filters", "core", "accounts"]
MIDDLEWARE: add "django.middleware.locale.LocaleMiddleware" right after SessionMiddleware
USE_I18N = True
LANGUAGE_CODE = "fr"
LANGUAGES = [("fr", "Français"), ("en", "English")]
LOCALE_PATHS = [BASE_DIR / "locale"]
SPECTACULAR_SETTINGS = {"SWAGGER_UI_DIST": "SIDECAR", "SWAGGER_UI_FAVICON_HREF": "SIDECAR",
                        "REDOC_DIST": "SIDECAR"}            # Swagger works offline

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["rest_framework_simplejwt.authentication.JWTAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_PAGINATION_CLASS": "core.pagination.DefaultPagination",
    "DEFAULT_FILTER_BACKENDS": ["django_filters.rest_framework.DjangoFilterBackend"],
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    "EXCEPTION_HANDLER": "core.exceptions.api_exception_handler",
    "NUM_PROXIES": 0,   # throttle on REMOTE_ADDR only: X-Forwarded-For is client-controlled
    "DEFAULT_THROTTLE_CLASSES": ["rest_framework.throttling.ScopedRateThrottle"],
    "DEFAULT_THROTTLE_RATES": {
        "auth_login": env("THROTTLE_LOGIN"),
        "auth_register": env("THROTTLE_REGISTER"),
        "password_reset": env("THROTTLE_PASSWORD_RESET"),
        "password_reset_confirm": env("THROTTLE_PASSWORD_RESET_CONFIRM"),
    },
}
SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=env.int("JWT_ACCESS_MINUTES")),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=env.int("JWT_REFRESH_DAYS")),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
    "UPDATE_LAST_LOGIN": True,
    "CHECK_REVOKE_TOKEN": True,   # access tokens carry a password hash: a password change revokes them
    "AUTH_HEADER_TYPES": ("Bearer",),
}
AUTH_PASSWORD_VALIDATORS = [  # Django's 4 defaults; MinimumLength set to 8
    ...UserAttributeSimilarity, MinimumLength(min_length=8), CommonPassword, NumericPassword
]
PASSWORD_RESET_CODE_TTL_MINUTES = env.int("PASSWORD_RESET_CODE_TTL_MINUTES")    # 15
PASSWORD_INVITE_CODE_TTL_HOURS = env.int("PASSWORD_INVITE_CODE_TTL_HOURS")      # 72
PASSWORD_CODE_MAX_ATTEMPTS = 5
RESET_MAX_FAILED_ATTEMPTS_PER_DAY = env.int("RESET_MAX_FAILED_ATTEMPTS_PER_DAY")   # 10, across all codes of an account, 24 h
```
Simplejwt's `JWTAuthentication` rejects inactive users on every request, so deactivation takes effect immediately.

`core/exceptions.py` turns every DRF error into the shared shape, keeping the **codes**:
```python
class BusinessError(APIException):
    def __init__(self, code, message, status_code=400):
        super().__init__(detail=message, code=code); self.status_code = status_code

def api_exception_handler(exc, context):
    response = exception_handler(exc, context)          # DRF default
    if response is None:
        return None                                      # 500 -> Django handles it, nothing leaked
    if isinstance(exc, ValidationError):
        code, message = "validation_error", _("Invalid input.")
        fields = exc.get_full_details()                  # {"email": [{"message": ..., "code": "unique"}]}
        # non_field_errors / list details: put them under fields["non_field_errors"]
    else:
        code, message, fields = exc.get_codes(), str(exc.detail), {}
        # simplejwt's InvalidToken has a dict detail: use detail["code"] ("token_not_valid") and detail["detail"]
    response.data = {"error": {"code": code, "message": message, "fields": fields}}
    return response
```
**Where passwords are validated.** Register: in `RegisterSerializer.validate()` (against an unsaved `User`, keyed `password`). Change and reset: in `services.py` (`_validate_new_password`, keyed `new_password`, raised as a DRF `ValidationError` with the codes kept, because services run outside a serializer). Reset confirm validates twice: first against `User(email=...)` for every email (so known and unknown emails answer alike), then with the real user once the code matches, before the code is consumed.

Django password validators raise Django `ValidationError`s with codes (`password_too_short`, ...). Call `validate_password()` inside the serializer's `validate_<field>` method and **let it raise**: DRF converts it and keeps the codes. Don't re-wrap `e.messages`.

---

## 4. Endpoints

All under `/api/v1/`. `UserOut` (used everywhere):
```json
{
  "id": 12, "email": "amira@example.com", "first_name": "Amira", "last_name": "Ben Salah",
  "phone": "+21620123456", "role": "patient", "preferred_language": "fr", "is_active": true,
  "date_joined": "2026-11-02T10:15:00+01:00",
  "patient_profile": { "date_of_birth": "1999-04-02" }
}
```
`patient_profile` is `null` for doctors and admins. Doctor professional data comes from `GET /api/v1/doctors/me/` (M2).

| # | Method & path | Auth | Throttle scope |
|---|---|---|---|
| 1 | `POST auth/register/` | public | `auth_register` |
| 2 | `POST auth/login/` | public | `auth_login` |
| 3 | `POST auth/token/refresh/` | public (refresh token) | – |
| 4 | `POST auth/logout/` | public (refresh token) | – |
| 5 | `GET / PATCH auth/me/` | logged in | – |
| 6 | `POST auth/password/change/` | logged in | – |
| 7 | `POST auth/password/reset/` | public | `password_reset` |
| 8 | `POST auth/password/reset/confirm/` | public | `password_reset_confirm` |
| 9 | `GET users/` · `GET/PATCH users/{id}/` | `IsAdmin` | – |

Public views (1–4, 7, 8) set `permission_classes = [AllowAny]` **and** `authentication_classes = []`. Otherwise a stale `Authorization` header makes DRF return 401 even on a public endpoint.

Below, errors are written as `status code` (field-level codes in brackets). The app translates by code (TEAM_PLAN §4.3).

### 1. Register (patient only)
Request:
```json
{ "email": "amira@example.com", "password": "S3cure-pass", "first_name": "Amira",
  "last_name": "Ben Salah", "phone": "+21620123456", "date_of_birth": "1999-04-02",
  "preferred_language": "fr" }
```
- `phone`, `date_of_birth` and `preferred_language` are optional. The app always sends its current locale as `preferred_language`; the default is `fr`.
- Any `role` sent by the client is **ignored** (always patient).
- Creates `User` + `PatientProfile` in one transaction.

Responses:
- `201` → `{ "access": "...", "refresh": "...", "user": UserOut }` (the user is logged in right away)
- `400 validation_error` with field codes:
  - `email`: `required`, `invalid`, `unique`
  - `password`: `required`, `password_too_short`, `password_too_common`, `password_entirely_numeric`, `password_too_similar`
  - `first_name`/`last_name`: `required`, `blank`
  - `phone`: `invalid`
  - `date_of_birth`: `invalid`, `date_in_future`
  - `preferred_language`: `invalid_choice`
- `429 throttled`

### 2. Login
Request `{ "email": "...", "password": "..." }` (email case-insensitive).
- `200` → `{ "access", "refresh", "user": UserOut }`. Subclass `TokenObtainPairSerializer` to add `user`.
- `401 authentication_failed`: **same code and message** for unknown email, wrong password and inactive account.
- `429 throttled`

### 3. Refresh
Request `{ "refresh": "..." }` → `200 { "access": "...", "refresh": "..." }`. With rotation, **the client must store the new refresh token**; the old one is blacklisted.
- `401 token_not_valid`: expired, malformed or blacklisted → the client logs out.

### 4. Logout
Request `{ "refresh": "..." }` → `204`. Blacklists the refresh token.
- Idempotent: an already-blacklisted or expired token still returns `204`. A malformed token → `400 validation_error`.
- It is public on purpose: possessing the refresh token is the proof, and it works even when the access token has expired.
- The client clears local tokens whatever the response.

### 5. Me
- `GET` → `200 UserOut`
- `PATCH` request (all optional): `{ "first_name", "last_name", "phone", "preferred_language", "patient_profile": { "date_of_birth" } }` → `200 UserOut`
  - `email`, `role`, `is_active` are read-only (ignored if sent). Email change is out of scope.
  - `patient_profile` sent by a non-patient → `400 validation_error` (`patient_profile: [invalid]`).
- `401 not_authenticated` / `token_not_valid`

### 6. Change password
Request `{ "old_password": "...", "new_password": "..." }`.
- `200` → `{ "access", "refresh" }`. **All** existing refresh tokens of the user are blacklisted (logs out other devices), and a fresh pair is returned so this device stays logged in.
- `400 validation_error`: `old_password: [invalid]`, `new_password: [password_too_short, ...]`.

### 7. Request reset code
Request `{ "email": "..." }` → **always** `202` (the body `{"detail": "..."}` is informational; the app shows its own translated text).

Server side:
- If an *active* user exists: invalidate their previous unused codes, create a code (TTL `PASSWORD_RESET_CODE_TTL_MINUTES`) and email it **in the user's `preferred_language`**.
- If a code was sent less than 60 s ago, do nothing (anti-spam).
- Unknown/inactive email: nothing is sent, and the response is the same.

### 8. Confirm reset (also used by doctors to accept the invite)
Request `{ "email": "...", "code": "482913", "new_password": "..." }`.
- `204` → password set, code marked used, all refresh tokens of the user blacklisted. The app then sends the user to login.
- `400 invalid_code`: **one generic code** for unknown email, no active code, wrong code, expired, attempts ≥ `PASSWORD_CODE_MAX_ATTEMPTS`, already used. Each wrong code increments `attempts` (row locked with `select_for_update`).
- `400 validation_error`: `new_password` codes (the code is **not** consumed in this case).
- `429 throttled`

### 9. Admin users
- `GET users/?role=doctor&is_active=true&search=amira` → paginated `UserOut` list (search on email, first and last name; ordered by `-date_joined`).
- `GET users/{id}/` → `UserOut`.
- `PATCH users/{id}/` `{ "is_active": false }` → `200 UserOut`. Only `is_active` is editable. Deactivating blacklists the user's refresh tokens. Deactivating yourself → `400 cannot_deactivate_self`.
- `403 permission_denied` for non-admins.

---

## 5. Exports for other modules

`accounts/permissions.py`:
```python
class IsPatient(BasePermission):
    def has_permission(self, request, view):
        u = request.user
        return bool(u and u.is_authenticated and u.role == User.Role.PATIENT)
# IsDoctor, IsAdmin: same shape.
# Combine with DRF operators: permission_classes = [IsPatient | IsAdmin]
```
These check the role only. **Object-level ownership** ("is this my appointment?") is each module's job: filter querysets by `request.user` so other users' objects return 404.

`accounts/services.py` (plain functions; views call these):
| Function | Used by |
|---|---|
| `create_user(*, email, first_name, last_name, role, phone="", preferred_language=None, password=None) -> User` | M1 register, M2 create doctor |
| `register_patient(*, data) -> User` | M1 |
| `send_password_code(user, purpose: "reset" \| "invite") -> None` | M1 reset, M2 doctor invite (TTL 72 h, "Welcome, set your password" text) |
| `confirm_password_code(*, email, code, new_password) -> None` | M1 |
| `change_password(user, old, new) -> dict[str, str]` (new token pair) | M1 |
| `revoke_all_refresh_tokens(user) -> None` | M1 (password change/reset, deactivation) |
| `set_user_active(user, is_active, *, by) -> User` | M1 admin |

```python
def revoke_all_refresh_tokens(user):
    for token in OutstandingToken.objects.filter(user=user):
        BlacklistedToken.objects.get_or_create(token=token)

def send_password_code(user, purpose):
    ...create code...
    with translation.override(user.preferred_language):
        subject = gettext("Your MedApp code")             # or "Welcome to MedApp" for invite
        body = render_to_string(f"accounts/email/password_code_{purpose}.txt", {...})
        send_mail(subject, body, None, [user.email])
```
**Transactions:** `send_password_code` sends the email immediately and is not rolled back. A caller inside a transaction (M2 creating a doctor) must use `transaction.on_commit(lambda: send_password_code(user, "invite"))`.

**A reset request cancels a pending doctor invite** (all unused codes of the user are invalidated when a new one is issued). The doctor then uses the "Forgot password" flow to get a fresh code.

**Brute force.** Besides 5 attempts per code, failed attempts are counted per account over 24 h across all codes (`RESET_MAX_FAILED_ATTEMPTS_PER_DAY`). At the limit even a correct code is refused and no new reset code is sent until the window passes. Refresh tokens presented again after rotation or logout are treated as theft: all the user's refresh tokens are revoked (tokens killed by a password change get a plain 401).

- `accounts/serializers.py` exports `UserSummarySerializer` (`id, first_name, last_name, email, phone`) for other modules to embed.
- `backend/conftest.py` fixtures: `api_client`, `patient`, `doctor`, `admin_user`, `auth_client(user)` (`force_authenticate`), plus an autouse `cache.clear()` so throttle counters never leak between tests.
- Email templates: `backend/templates/accounts/email/password_code_reset.txt` and `password_code_invite.txt`, using `{% load i18n %}` / `{% blocktranslate %}`; French in `backend/locale/fr/LC_MESSAGES/django.po` (+ committed `.mo`). Never log the code; in dev/demo read it in Mailpit (http://localhost:8025).

---

## 6. Flutter side

Packages (all in the TEAM_PLAN §9 license table): `flutter_riverpod`, `go_router`, `dio`, `flutter_secure_storage`, `shared_preferences`, `intl`, `flutter_localizations` (SDK); dev: `mocktail`, `flutter_lints`.

### 6.1 Files
```
l10n.yaml                                # arb-dir: lib/l10n, template: app_en.arb, untranslated-messages-file
lib/l10n/app_en.arb, app_fr.arb          # all UI strings (each module adds its keys)
lib/core/config/env.dart                 # API_BASE_URL etc. from --dart-define-from-file; fail fast if empty
lib/core/l10n/locale_controller.dart     # Notifier<Locale>: load/save preference, sync with server
lib/core/l10n/error_text.dart            # ApiException / field code -> ARB string
lib/core/storage/token_storage.dart      # read/save/clear access+refresh (secure storage, cached in memory)
lib/core/network/api_exception.dart      # ApiException.fromDioException(...) parses {"error": {...}}
lib/core/network/api_client.dart         # plainDioProvider (no auth) + dioProvider (with AuthInterceptor)
lib/core/network/auth_interceptor.dart   # bearer header + Accept-Language + refresh-once logic
lib/core/widgets/async_value_view.dart   # loading / error+retry / empty / data
lib/core/widgets/language_switch.dart    # FR | EN segmented control
lib/features/auth/data/models/user.dart  # User, UserRole, PatientProfile (fromJson/toJson)
lib/features/auth/data/auth_api.dart     # one method per endpoint
lib/features/auth/data/auth_repository.dart  # api + token storage
lib/features/auth/presentation/auth_controller.dart  # AsyncNotifier<User?> + currentUserProvider
lib/features/auth/presentation/screens/  splash, login, register, forgot_password, reset_password, profile, change_password
lib/features/users_admin/                # data/users_admin_api.dart, presentation/users_admin_screen.dart
lib/app/app.dart                         # MaterialApp.router with locale, supportedLocales, localizationsDelegates
lib/app/router.dart                      # GoRouter + authRedirect()
lib/app/shells/                          # patient_shell, doctor_shell, admin_shell (bottom nav)
```

### 6.2 Auth state
`AuthController extends AsyncNotifier<User?>`:
- **loading** = unknown (app starting) → splash
- **data(null)** = logged out
- **data(user)** = logged in; `currentUserProvider` exposes the user.

`build()`: if no refresh token is stored → `null`. Otherwise `GET auth/me/` (the interceptor refreshes if the access token expired) → user; on 401 → `null` + clear storage.
Methods: `login`, `register` (both save tokens, then set the user), `logout`, `sessionExpired` (called by the interceptor), `updateProfile`.

`logout()`:
1. M4 hooks: stop notification polling and `LocalReminders.cancelAll()` (the next person using this phone must not get this user's reminders).
2. `POST auth/logout/` with the refresh token (best effort).
3. Clear token storage.
4. Set state to `null`.

User-scoped providers watch `currentUserIdProvider` (the user's id), so they reset automatically on logout or account switch without reloading on profile edits. The language preference is **not** cleared on logout (it is a device setting).

### 6.3 Token refresh interceptor (`QueuedInterceptor`)
- `onRequest`:
  - Always add `Accept-Language: <current locale>`, so server fallback messages match the UI.
  - Skip the auth header on public auth paths (`login`, `register`, `token/refresh`, `logout`, `password/reset*`); otherwise add `Authorization: Bearer <access>`.
  - `logout` must be skipped: if it triggered a refresh, rotation would leave the *new* refresh token valid after logout.
- `onError` on `401`, for a request not already retried:
  1. If the stored access token is **different** from the one this request used, another request already refreshed: retry with the new token. *(Important: with rotation + blacklist, refreshing twice with the same refresh token fails and would log the user out.)*
  2. Otherwise `POST auth/token/refresh/` with `plainDio` → save **both** new tokens → retry the original request once (`options.extra['retried'] = true`).
  3. Refresh returns 401/400 → clear storage, call `sessionExpired()` → the router sends the user to login.
  4. Network error during refresh → do **not** log out; return the network error.
- Avoid a provider cycle (controller → repository → dio → interceptor → controller): the interceptor gets callbacks that call `ref.read(...)` **at call time** (for `sessionExpired()` and the current locale).
- Timeouts on both Dio instances: connect 10 s, receive 15 s (constants in `core/config`).

### 6.4 Routing (`app/router.dart`)
- Public routes: `/splash`, `/login`, `/register`, `/forgot-password`, `/reset-password`.
- Role areas: `/patient/...`, `/doctor/...`, `/admin/...`. Each is a `StatefulShellRoute` with a bottom nav; the `profile` tab in each reuses `ProfileScreen`.
- The router refreshes when the auth state changes (`refreshListenable` fed by `ref.listen(authControllerProvider, ...)`).

`String? authRedirect(AsyncValue<User?> auth, String location)` is a pure function (easy to unit test):
| State | Location | Redirect to |
|---|---|---|
| loading | anything | `/splash` |
| logged out | public route | stay |
| logged out | anything else | `/login` |
| logged in | public route or `/splash` | `/<role>` home |
| logged in | another role's area | `/<role>` home |
| logged in | own area | stay |

Client-side routing is UX only; the **backend permissions are the real protection**.

### 6.5 Screens
Every text comes from the ARB files (`authLoginTitle`, `authEmailLabel`, ...). Server errors are shown with `errorText(context, e)`: field errors under the matching input, others in a snackbar.

| Screen | Notes |
|---|---|
| Splash | Shown while the auth state loads |
| Login | Email, password (obscured, toggle); **language switch in the app bar**; the 401 shows `errorAuthenticationFailed`; links to register and forgot password |
| Register | First/last name, email, phone (opt.), date of birth (opt., localized date picker), password + confirm; sends `preferred_language` = current locale |
| Forgot password | Email → `202` → reset screen with the email pre-filled. Link "I already have a code" (doctor invite) |
| Reset password | Email, 6-digit code, new password + confirm → success → login with a snackbar |
| Profile | View/edit name, phone, date of birth (patients); email/role read-only; **Language setting (FR/EN)**; buttons Change password, Logout |
| Change password | Old, new, confirm → save the returned tokens |
| Admin users | Paginated list, search, role filter chips (translated role names), active switch with confirm dialog |

Client validation (UX only, translated messages): email format, required fields, password ≥ 8 chars, confirm matches.

### 6.6 Language switcher and stored preference
`LocaleController extends Notifier<Locale>` in `core/l10n/locale_controller.dart`; `MaterialApp.router(locale: ref.watch(localeControllerProvider), supportedLocales: AppLocalizations.supportedLocales, ...)`.

| When | Rule |
|---|---|
| App start | Stored choice (`shared_preferences`, key `app_locale`) → else device language if `fr`/`en` → else `fr` |
| Logged out, user taps FR/EN (login screen) | Change locale + store locally |
| Register | Send current locale as `preferred_language` |
| Login / app start with a session | **Server wins:** if `user.preferred_language` ≠ current locale, switch to it and store it |
| Logged in, user changes language (profile) | Switch immediately, `PATCH auth/me/ {preferred_language}`; on failure revert and show an error snackbar, so app and emails never disagree |

Language is not a secret, so `shared_preferences` is fine (tokens stay in secure storage).

---

## 7. Security checklist
- [ ] `AUTH_USER_MODEL` set before the first migration. If anyone already migrated with the default user: `docker compose down -v` (or `podman compose down -v`) and re-migrate.
- [ ] `SECRET_KEY` from env (generated per machine, never committed); the app refuses to start if it is empty, shorter than 50 characters or a placeholder. `DEBUG=False` by default; Django admin mounted only with `DJANGO_ADMIN_ENABLED=True`. `ALLOWED_HOSTS` from env (localhost, `10.0.2.2`, the demo laptop's LAN IP; never `*`).
- [ ] Django password validators on register, change and reset (`validate_password(password, user)`).
- [ ] Throttling on login, register, reset request and confirm (per IP). The default local-memory cache is per process, which is fine for `runserver`.
- [ ] No account enumeration on login and reset (same code/status). Register does reveal `unique` on email: an accepted UX trade-off, and it is throttled.
- [ ] `role` and `is_active` can never be set by a non-admin client; serializers list fields explicitly (no `__all__`).
- [ ] Reset codes: `secrets` module, hashed, 15 min TTL (invite 72 h), 5 attempts, single use, previous codes invalidated.
- [ ] Never log passwords, codes, tokens or `Authorization` headers (backend and Flutter). Dio `LogInterceptor` only in debug, with `requestHeader: false, requestBody: false`.
- [ ] Tokens only in `flutter_secure_storage`; set `android:allowBackup="false"` (restored encrypted prefs can't be decrypted and crash the app). Never put tokens in route params.
- [ ] Cleartext HTTP allowed only in `android/app/src/debug/AndroidManifest.xml` (LAN demo uses a debug build). Known limit: on the LAN demo, traffic is plain HTTP; acceptable for a local demo, not for real use.
- [ ] Known limit: an access token stays valid up to 15 min after a password change (deactivation is immediate).
- [ ] Run `python manage.py flushexpiredtokens` occasionally (blacklist tables grow).

---

## 8. Implementation checklist (in order)

### Week 0: shared skeleton (one PR backend, one PR mobile, reviewed by M2)
1. `backend/config/settings.py` (incl. i18n + sidecar), `config/urls.py` (`/admin/`, `/api/schema/`, `/api/docs/`, `/api/v1/auth/`), `requirements*.txt`, `pyproject.toml` (ruff, pytest), `.env.example`, root `docker-compose.yml`, `.gitignore`, `scripts/check.py`, `README.md` (quickstart + emulator vs phone URL table).
2. `core/exceptions.py` (handler + `BusinessError`), `core/pagination.py`, `core/management/commands/seed_demo.py`, `backend/locale/fr/LC_MESSAGES/` (empty catalog).
3. `accounts/models.py` (`User` incl. `preferred_language`, `UserManager`, `PatientProfile`, `PasswordResetCode`), `accounts/migrations/0001_initial.py` (generated), `accounts/admin.py`, `accounts/permissions.py`, `accounts/urls.py` with default simplejwt login + refresh.
4. `backend/conftest.py` fixtures.
5. Mobile: `flutter create`, `pubspec.yaml` (`generate: true`), `l10n.yaml`, `lib/l10n/app_en.arb` + `app_fr.arb`, `analysis_options.yaml`, `env/example.json`, `core/config/env.dart`, `core/network/api_client.dart`, `api_exception.dart`, `core/widgets/async_value_view.dart`, `app/app.dart` (localization delegates), `app/router.dart` (empty shells), `app/shells/*.dart`, debug manifest cleartext, `allowBackup=false`.

### Week 1
6. `accounts/serializers.py` (`UserOut`, `UserSummarySerializer`, register, login-with-user, me), `accounts/services.py` (`create_user`, `register_patient`), `accounts/views.py`: register, login, me, logout.
7. Mobile: `token_storage.dart`, `auth_interceptor.dart` (incl. `Accept-Language`), `features/auth/data/*`, `auth_controller.dart`, `locale_controller.dart`, `language_switch.dart`, splash, login, register screens, `authRedirect` wired.

### Week 2
8. Backend: change password, `revoke_all_refresh_tokens`, reset request/confirm, `send_password_code` (+ invite purpose for M2), FR/EN email templates, `makemessages`/`compilemessages`.
9. Mobile: profile (with language setting), change password, forgot password, reset password screens; logout.

### Week 3
10. Backend: admin `users/` list/detail/PATCH; throttle scopes; `accounts/seed.py`.
11. Mobile: `features/users_admin/`; `core/l10n/error_text.dart` covering every code in the registry; role redirect polish; M4 logout hooks wired.

### Backend tests (`accounts/tests/`)
- `test_models.py`: email lowercased; duplicate email in other case rejected; `create_user` without password → unusable; `create_superuser` → admin + staff; login case-insensitive; `preferred_language` defaults to `fr`.
- `test_register.py`: 201 with tokens and `PatientProfile`; `role: "admin"` in payload still creates a patient; `preferred_language: "en"` saved; `preferred_language: "de"` → `invalid_choice`; duplicate email → `fields.email[0].code == "unique"`; weak password → `password_too_short`; missing names → `required`; future date of birth → `date_in_future`.
- `test_login.py`: success returns `user`; wrong password, unknown email and inactive user → same 401 body (`authentication_failed`); throttled → 429 `throttled` (patch `ScopedRateThrottle.THROTTLE_RATES` in the test).
- `test_tokens.py`: refresh returns a new refresh; old refresh rejected after rotation; logout → refresh rejected; logout twice → 204.
- `test_me.py`: anonymous 401; PATCH updates names/phone/date of birth/`preferred_language`; `email`/`role` ignored; doctor sending `patient_profile` → 400.
- `test_password_change.py`: wrong old → 400 `old_password[0].code == "invalid"`; success → old refresh rejected, new pair works, login with new password.
- `test_password_reset.py`: unknown email → 202 and `mail.outbox` empty; known → 202 and one email; second request within 60 s → no new email; wrong code increments attempts; 5 wrong → correct code rejected; expired → `invalid_code`; success → login works, code can't be reused, old refresh rejected; inactive user → no email; invite code valid 72 h.
- `test_i18n.py`: a user with `preferred_language="en"` gets an English email subject/body, `"fr"` gets French; `Accept-Language: en` vs `fr` changes the `message` of a validation error but **not** its `code`.
- `test_permissions.py`: `IsPatient/IsDoctor/IsAdmin` with each role and anonymous.
- `test_users_admin.py`: patient/doctor → 403; filters and search; deactivate → existing access token rejected and login fails; self-deactivation → `cannot_deactivate_self`.
- `core/tests/test_exceptions.py`: validation, 401, 403, 404, throttled and `BusinessError` responses all match the error shape with the expected `code`s.

### Mobile tests (`mobile/test/`)
- `core/network/auth_interceptor_test.dart`: adds bearer and `Accept-Language`; 401 → one refresh then retry; two parallel 401s → **one** refresh call; refresh failure → storage cleared + `sessionExpired` called; network error during refresh → no logout; logout request carries no bearer.
- `core/network/api_exception_test.dart`: parses error envelope, nested field errors with codes; network error mapping.
- `core/l10n/error_text_test.dart`: known codes → ARB text in FR and EN; unknown code → server message; nothing → generic text.
- `core/l10n/locale_controller_test.dart`: start-up order (stored → device → `fr`); server value wins after login; failed PATCH reverts.
- `features/auth/auth_controller_test.dart`: no tokens → `null`; tokens + `/me` ok → user; login stores tokens; logout clears storage even if the API call fails.
- `app/router_redirect_test.dart`: every row of the redirect table.
- `features/auth/login_screen_test.dart`: pumped in `fr` and `en`; client validation messages translated; server field error displayed under the field.

Done when: everything above passes in `python scripts/check.py`, every endpoint shows in Swagger, no untranslated ARB keys remain, and demo flows 1, 2, 4 and 5 in `TEAM_PLAN.md` work on a physical phone over the LAN in both languages.
