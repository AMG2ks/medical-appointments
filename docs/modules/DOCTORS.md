# Module 2 — Doctors, specialties & availability

Django app: `doctors` · Flutter: `features/doctors/`
Conventions (error shape and codes, i18n, pagination, env, git, licenses): see [`../TEAM_PLAN.md`](../TEAM_PLAN.md). Auth contracts used here: [`AUTH.md`](AUTH.md).

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Doctor id | `DoctorProfile.user` is the primary key. "Doctor 12" is user 12 in URLs, in `Appointment.doctor_id` and in ownership checks | TEAM_PLAN §3 |
| Specialty names | Stored in both languages (`name_fr`, `name_en`, each unique); the API returns both and the app shows the one of the current locale. `bio` is free text, not translated | Names are data, not UI strings |
| Deleting a specialty | `PROTECT`: deleting one that doctors use answers `409 specialty_in_use` | Never leave a doctor without a specialty |
| Availability | Weekly windows in wall-clock time of `settings.TIME_ZONE` (`APP_TIME_ZONE`, default `Africa/Tunis`). Windows of one weekday must not overlap (touching, e.g. 09-12 and 12-14, is allowed) | DST-safe: "09:00" stays 09:00 local |
| Time off | Absolute `start_at`/`end_at` instants (aware datetimes), any length, may span days | Holidays, one afternoon, etc. |
| Public doctor card | `id, first_name, last_name, specialty, bio, consultation_minutes, invite_pending`. **No email or phone**: patients do not need them. The doctor's own `/doctors/me/` and the admin create answer add `email` and `phone` | Data minimisation |
| **Visibility rule** | A doctor is *visible* when the account is active, has `role=doctor` **and has a usable password** (the invite was accepted). `GET doctors/` and `GET doctors/{id}/` return only visible doctors to patients and doctors (`404` otherwise). **Admins** also see doctors whose invite is still pending, flagged `"invite_pending": true`. Implemented once in `services.visible_doctors(user)` (still importable from `views`) | Nobody can book an account that cannot log in yet |
| Lists | Every list is paginated (`page_size` max 100). The app asks `page_size=100` for the small reference lists (specialties, availability, time off) instead of paging them | TEAM_PLAN §4.3 |
| Bounded input | `bio` ≤ 2000 characters (`models.BIO_MAX_LENGTH`); `consultation_minutes` 5–240 (`models.CONSULTATION_MINUTES_MIN/MAX`, also a DB check); the doctors `search` keeps at most the first 100 characters and 5 words | Limits live once, in `models.py` / `views.py` |
| Doctor creation | One transaction creates `User(role=doctor, unusable password)` + `DoctorProfile`; the invite email (`send_password_code(user, "invite")`) is sent in `transaction.on_commit`, so a rollback never mails a code for a missing account. A mail failure after commit is logged (`logger.exception`, no address) and the request still answers `201`: the doctor can use "Forgot password". Two admins creating the same email at once: the DB unique constraint is mapped to `400 validation_error` with `email: [unique]` | Contract of `send_password_code` |
| Time off over booked days | `POST doctors/me/time-off/` is refused with `409 time_off_conflict` (+ `error.details` listing the confirmed appointments in the way) while any `confirmed` appointment overlaps the period; the doctor cancels them first. The check runs in `services.create_time_off` under the doctor-row lock that booking also takes. `doctors` never imports `appointments`: the latter registers a guard with `register_time_off_guard` in its `AppConfig.ready()` | Booked patients must not be silently abandoned (M3, see APPOINTMENTS.md) |
| Availability edits vs bookings | Editing or deleting weekly availability never touches existing appointments: they stay valid and only the free slots change | A booking is a promise; the doctor cancels it explicitly if needed |
| Concurrent availability edits | `services.save_availability` locks the `DoctorProfile` row (`select_for_update`) before checking overlaps | Two requests cannot both pass the check |

## 2. Data model (`doctors/models.py`)

```python
class Specialty(models.Model):
    name_fr = CharField(max_length=100, unique=True)
    name_en = CharField(max_length=100, unique=True)

class DoctorProfile(models.Model):
    user = OneToOneField(User, primary_key=True, related_name="doctor_profile")
    specialty = ForeignKey(Specialty, on_delete=PROTECT, related_name="doctors")
    bio = TextField(blank=True)
    consultation_minutes = PositiveSmallIntegerField(default=30)   # DB check: 5..240

class WeeklyAvailability(models.Model):   # ordered by weekday, start_time
    doctor = ForeignKey(DoctorProfile, related_name="availabilities")
    weekday = PositiveSmallIntegerField()     # 0 = Monday ... 6 = Sunday (date.weekday()); DB check 0..6
    start_time = TimeField(); end_time = TimeField()   # DB check start < end

class TimeOff(models.Model):              # ordered by -start_at
    doctor = ForeignKey(DoctorProfile, related_name="time_offs")
    start_at = DateTimeField(); end_at = DateTimeField()   # DB check start < end
    reason = CharField(max_length=200, blank=True)
```

## 3. Endpoints

All under `/api/v1/`. "Logged in" = any role.

| # | Method & path | Who |
|---|---|---|
| 1 | `GET specialties/` | logged in |
| 2 | `POST specialties/` · `PATCH/DELETE specialties/{id}/` | admin |
| 3 | `GET doctors/?specialty=<id>&search=<text>` | logged in (active doctors only) |
| 4 | `GET doctors/{id}/` | logged in (404 if inactive) |
| 5 | `POST doctors/` | admin |
| 6 | `GET/PATCH doctors/me/` | doctor |
| 7 | `GET/POST doctors/me/availability/` · `PATCH/DELETE doctors/me/availability/{id}/` | doctor (own rows only; others' ids are `404`) |
| 8 | `GET/POST doctors/me/time-off/` · `DELETE doctors/me/time-off/{id}/` | doctor (own rows only) |

`search` matches first or last name (case-insensitive). Non-admin on an admin endpoint: `403 permission_denied`. Not logged in: `401`.

### Examples

`Specialty` (1, 2): `{ "id": 3, "name_fr": "Cardiologie", "name_en": "Cardiology" }`

`GET doctors/` (3), paginated (`invite_pending` is only ever `true` for an admin); also the shape of `GET doctors/{id}/`:
```json
{ "count": 1, "next": null, "previous": null, "results": [
  { "id": 12, "first_name": "Sarah", "last_name": "Miller",
    "specialty": { "id": 3, "name_fr": "Cardiologie", "name_en": "Cardiology" },
    "bio": "Cardiologist focused on prevention.", "consultation_minutes": 20, "invite_pending": false } ] }
```

`POST doctors/` (5) request, then `201` with the "me" shape (public card + `email`, `phone`):
```json
{ "email": "new.doc@example.com", "first_name": "New", "last_name": "Doc", "phone": "+21620123456",
  "preferred_language": "en", "specialty_id": 3, "bio": "", "consultation_minutes": 30 }
```
- Required: `email`, `first_name`, `last_name`, `specialty_id`. Optional: `phone`, `preferred_language` (`fr`/`en`, default `fr`), `bio`, `consultation_minutes` (5–240, default 30).
- Creates the user with no password and emails an invite code in `preferred_language` (read it in Mailpit). The doctor sets a password with that code on the login screen's "Forgot password" → "I already have a code" flow. Until then the doctor is hidden from patients (see the visibility rule).

`GET/PATCH doctors/me/` (6): the "me" shape. PATCH accepts `specialty_id`, `bio`, `consultation_minutes`; name, phone and language go through `auth/me/`.
```json
{ "id": 12, "first_name": "Sarah", "last_name": "Miller", "email": "dr.sarah@medapp.local", "phone": "",
  "specialty": { "id": 3, "name_fr": "Cardiologie", "name_en": "Cardiology" },
  "bio": "...", "consultation_minutes": 20 }
```

`WeeklyAvailability` (7): `{ "id": 5, "weekday": 0, "start_time": "09:00:00", "end_time": "12:00:00" }`. Requests send `"09:00"`. The list is paginated and ordered by weekday then start.

`TimeOff` (8), newest first, paginated. Requests may send ISO datetimes **without offset** (`2026-12-24T00:00:00`): the server reads them in `TIME_ZONE`; responses carry the clinic offset:
```json
{ "id": 2, "start_at": "2026-12-24T00:00:00+01:00", "end_at": "2026-12-27T00:00:00+01:00", "reason": "Holidays" }
```

## 4. Error codes

Every error has the shape of TEAM_PLAN §4.3; the app translates by `code`.

| Status | `code` | When | Added to ARB |
|---|---|---|---|
| 409 | `time_off_conflict` | `POST doctors/me/time-off/` over confirmed appointments (details: `{"count", "appointments": [{"id", "start_at", "end_at", "patient_name"}]}`, first 50) | `errorTimeOffConflict` |
| 400 | `availability_overlap` | A weekly window overlaps another window of the same weekday (create or update) | `errorAvailabilityOverlap` |
| 409 | `specialty_in_use` | `DELETE specialties/{id}/` while doctors use it | `errorSpecialtyInUse` |
| 400 | `validation_error` | Field codes below (also a duplicate doctor email, even in a race) | – |
| 401/403/404 | generic | not logged in / wrong role / not found or not your row | – |

Field codes returned in `fields` (beyond the generic registry): `unique` (specialty names, doctor email), `does_not_exist` (unknown `specialty_id`), `min_value`/`max_value` (`consultation_minutes`, `weekday`), `max_length` (`bio`), `incorrect_type`, `invalid` on `end_time`/`end_at` when the end is not after the start. The `min_value`, `max_value`, `does_not_exist` and `incorrect_type` codes were added to the app's `error_text.dart` with ARB strings.

## 5. Contract for M3: `working_intervals`

```python
from doctors.services import working_intervals

working_intervals(doctor: DoctorProfile, day: datetime.date) -> list[tuple[datetime, datetime]]
```
- **M3 booking must also reject doctors who are not visible** (inactive, not `role=doctor`, or invite pending): reuse `doctors.services.visible_doctors(request.user)` (or the same filter) when resolving the doctor of a slot or booking request, so a pending doctor can be neither listed nor booked by direct id.
- The `(start, end)` pairs are the windows in which the doctor works on calendar `day`, **sorted, timezone-aware** (in `settings.TIME_ZONE`), with all `TimeOff` already removed. A window split by a time off gives two pairs; fully covered gives none; no availability that weekday gives `[]`.
- `day` is a calendar date in `settings.TIME_ZONE`. A time off that starts before or ends after `day` (spanning days) is clipped correctly.
- Availability is wall-clock, so on a DST change day a "09:00–12:00" window is still 09:00–12:00 local. All arithmetic is done on UTC instants. A nonexistent local time (spring-forward gap) resolves to the instant after the gap, so a window lying entirely inside the missing hour (e.g. 02:30–03:15 on 2026-03-29 in Paris) yields no interval; an ambiguous one (fall-back) resolves to its first occurrence.
- **Pitfall:** the returned datetimes carry a `ZoneInfo`, and Python compares/subtracts two aware datetimes *of the same zone* by wall clock, ignoring DST. To compute durations, compare, or cut into slots, convert to UTC first (`dt.astimezone(UTC)`) or add `timedelta`s to UTC values and convert back.
- It does **not** know about appointments, the booking horizon or the lead time: that is M3.
- `doctor` is a `DoctorProfile`; only `.pk` is used (the doctor's user id), so `doctor.pk` of the `User` works too.

## 6. Tests and fixtures

- `backend/conftest.py`: `doctor` fixture is now a doctor `User` with a `DoctorProfile` (same id; `doctor.doctor_profile`), and a `specialty` fixture exists.
- `doctors/tests/`: `test_services.py` (working intervals incl. overlapping/spanning time off and DST in `Europe/Paris`, overlap rule), `test_api.py` (every endpoint: happy path, validation, 401, 403, not-your-resource, invite mail), `test_seed.py`.
- `doctors/seed.py` (run by `seed_demo`, idempotent): 5 specialties, specialty + bio + weekly availability for `dr.karim@medapp.local` (Mon–Fri 09–12, 14–17, 30 min) and `dr.sarah@medapp.local` (Mon/Wed/Fri 10–13, Thu 14–18, 20 min).

## 7. Flutter side

No new package. Files under `lib/features/doctors/`:
```
data/models/        specialty.dart doctor.dart availability.dart time_off.dart   # hand-written fromJson
data/doctors_repository.dart        # every call; doctorsRepositoryProvider (fake it in tests)
presentation/doctors_providers.dart # specialtiesProvider, doctorsListProvider (filter/search/paging),
                                    # doctorProvider(id), myDoctorProfileProvider, availabilityProvider, timeOffProvider
presentation/doctors_routes.dart    # bookingRoute(doctorId): the M3 hook
presentation/screens/               # doctors list, doctor detail, doctor profile, availability, time off,
                                    # specialties admin, create doctor
```
Routes and tabs (in `app/router.dart` and the shells):

| Role | Tab | Route |
|---|---|---|
| Patient | Doctors (home) | `/patient` list → `/patient/doctors/:id` → `/patient/doctors/:id/book` |
| Doctor | Availability | `/doctor/availability` → `/doctor/availability/time-off` |
| Doctor | Practice | `/doctor/practice` (specialty, bio, duration) |
| Admin | Doctors | `/admin/doctors` → `/admin/doctors/new`, `/admin/doctors/:id` |
| Admin | Specialties | `/admin/specialties` |

- **M3 hook (done):** the detail's "Book" button (patients only) pushes `bookingRoute(doctorId)` = `/patient/doctors/:id/book`, which M3 mounts as `BookingScreen`. The doctor's tab 0 (`/doctor`) is now M3's agenda.
- Specialty names are shown with `specialtyName(context, s)` (current locale). Weekday names come from `intl`, times from `TimeOfDay.format`.
- When the server answers `time_off_conflict`, the time off dialog lists the blocking appointments (date, patient) under the error; the doctor cancels them from the agenda, then saves again.
- Time off is chosen as whole days (first day 00:00 to the midnight after the last day) and sent as wall-clock datetimes without offset, so the server applies `APP_TIME_ZONE` whatever the phone's zone. The list parses the response keeping the clinic's wall clock, and shows whole days as a date range (end minus one day).
- The admin doctors list shows an "Invitation pending" line for doctors who have not accepted yet. After a specialty rename the doctor providers are invalidated so cards show the new name.
- `start_at` / `end_at` of a time off use `core.fields.SafeDateTimeField` (shared with M3's booking): a naive year-1 / year-9999 value is a `400 invalid`, never a 500 (regression test `test_year_one_naive_datetime_is_a_400_not_a_500`).
- `test/support/fake_doctors_repository.dart` (`FakeDoctorsRepository`, `fakeDoctor()`) is meant to be reused by M3/M4 tests.
