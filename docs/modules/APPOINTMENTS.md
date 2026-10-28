# Module 3 — Appointments

Django app: `appointments` · Flutter: `features/appointments/`
Conventions (error shape and codes, i18n, pagination, env, git, licenses): see [`../TEAM_PLAN.md`](../TEAM_PLAN.md). Contracts used here: [`AUTH.md`](AUTH.md), [`DOCTORS.md`](DOCTORS.md) (`working_intervals`, `visible_doctors`).

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Booking is immediate | `POST appointments/` creates a `confirmed` appointment. No pending state | TEAM_PLAN §1 |
| Statuses | `confirmed → cancelled \| completed \| no_show`. Nothing else, and a finished appointment never changes (`409 invalid_status_transition`) | TEAM_PLAN §2 |
| Who can book | Only patients. Doctors and admins get `403` | |
| Bookable doctors | Same rule as the doctors list: `doctors.services.visible_doctors(user)` (active, `role=doctor`, invite accepted). Unknown, inactive, pending-invite and non-doctor ids are all answered alike: `GET slots` → `404`, `POST` → `400 validation_error` with `doctor: [does_not_exist]` (nothing leaks about why) | DOCTORS.md §5 |
| Slots | `working_intervals(doctor, day)` (time off already removed) cut every `consultation_minutes` from the start of each interval, a trailing remainder shorter than a consultation is dropped, minus every `confirmed` appointment that overlaps the slot. All arithmetic is on UTC instants (DST-safe: 01:00–05:00 on the spring-forward day is 3 real hours) | DOCTORS.md §5 pitfall |
| Horizon and lead time | A day is bookable from today up to **today + `BOOKING_HORIZON_DAYS`** (calendar days in `TIME_ZONE`, last day inclusive), and a slot must start at least `BOOKING_MIN_LEAD_MINUTES` after now. Outside that, slots are `[]` (GET) / `slot_not_available` (POST) | |
| Double booking | `services.book` runs in one transaction: `select_for_update` on the **doctor row** (`DoctorProfile`, the same lock `doctors.services.save_availability` and `create_time_off` take), re-checks that `start_at` is a real bookable slot, checks overlap with confirmed appointments (so a longer booking made before the doctor changed `consultation_minutes` also blocks), then inserts. Backstop: partial `UniqueConstraint(doctor, start_at, condition=status="confirmed")`; its `IntegrityError` also becomes `slot_taken` | TEAM_PLAN §2 |
| Booking limits (owner decision) | Per patient, checked inside `book()` after locking the **patient's User row** (the doctor lock alone cannot serialize one patient booking several doctors in parallel; lock order is always patient, then doctor): at most `MAX_UPCOMING_APPOINTMENTS_PER_PATIENT` (default 5) upcoming confirmed appointments, at most 1 upcoming confirmed per doctor, and no overlap with the patient's own confirmed appointments. One code, `409 booking_limit_reached`, with `error.details.reason` = `max_upcoming` \| `same_doctor` \| `overlap`. Checked after `slot_not_available` and `slot_taken` | |
| Throttle | `POST appointments/` and `POST appointments/{id}/cancel/` use scope `appointment_write` (`THROTTLE_APPOINTMENT_WRITE`, default `20/hour`, per user); reads are not throttled | |
| Deactivated patients | `accounts.services.set_user_active(..., False)` sends `accounts.signals.user_deactivated(user, by)` inside its transaction; appointments listens (connected in `ready()`; accounts imports nothing from it) and cancels the patient's future confirmed appointments: `cancelled_by` = the acting admin, fixed reason "Account deactivated by an administrator." (translated), slots freed, `appointment_event("cancelled")` for each. Started appointments are left to the doctor. Doctors/admins deactivated: nothing is cancelled. A booking whose patient was deactivated meanwhile is refused (`403`) | |
| Absurd dates | `date=0001-01-01` / `9999-12-31` give empty slots, `400 invalid` on the list `date` filter, and `slot_not_available` / `400 invalid` on a booking `start_at` (never a 500) | |
| Back office | `/admin/` (when enabled) shows appointments read-only: no add / change / delete, so rules, locks and events cannot be bypassed | |
| Cancellation rules | Patient: until `CANCELLATION_MIN_HOURS` before the start (exactly at the cutoff is still allowed), else `400 cancellation_too_late`; reason optional. Doctor and admin: until the start, **reason required** (`400 validation_error`, `reason: [blank]`); once started → `409 invalid_status_transition` (use complete / no-show). Cancelling a non-confirmed appointment → `409 invalid_status_transition` | |
| Complete / no-show | Only the owning doctor (admin and patients: `403`; another doctor: `404`), only a `confirmed` appointment whose start is now or past, else `409 invalid_status_transition` | TEAM_PLAN §2 |
| Visibility | Patient: own appointments. Doctor: own agenda. Admin: all. An appointment that is not yours is `404` (not `403`), for the detail and every action | accounts convention |
| `scope` | `upcoming` = `confirmed` **and** not started (earliest first). `past` = everything else: started, or cancelled / completed / no-show; the still-`confirmed` (started, to be closed) first, then latest first. So a doctor finds the started-but-unclosed appointments in "past" to complete them, and a cancelled future appointment moves to the history | one list per tab, no overlap |
| Time off over booked days (decision of the project owner) | A time off that overlaps any `confirmed` appointment is refused by M2's endpoint with `409 time_off_conflict` listing the appointments; the doctor cancels them first. Done under the same doctor-row lock, so it cannot race a booking. See DOCTORS.md | |
| Availability edits | Allowed at any time; existing appointments stay valid (only free slots change). The doctor cancels explicitly if needed | A booking is a promise |
| Seed | `seed.py` inserts rows directly (past ones cannot be booked, and the seed must not queue emails): amira has 2 upcoming + completed, cancelled-by-patient and no-show ones, with dr.karim / dr.sarah, on days the doctor works | |
| Not paginated | `GET slots` (a day holds a bounded number of slots) | |

Settings (`backend/.env`, read in `settings.py`): `BOOKING_HORIZON_DAYS=30`, `BOOKING_MIN_LEAD_MINUTES=60`, `CANCELLATION_MIN_HOURS=24`, `MAX_UPCOMING_APPOINTMENTS_PER_PATIENT=5`, `THROTTLE_APPOINTMENT_WRITE=20/hour` (the last two have those defaults when absent from `.env`). Mobile only limits its date picker with `BOOKING_HORIZON_DAYS` (`env/*.json`, default 30); the server is the judge.

## 2. Data model (`appointments/models.py`)

```python
class Appointment(models.Model):          # ordered by start_at
    patient = ForeignKey(User, PROTECT, related_name="appointments")
    doctor = ForeignKey("doctors.DoctorProfile", PROTECT, related_name="appointments")
    start_at = DateTimeField(); end_at = DateTimeField()      # DB check start < end
    status = CharField(choices=confirmed|cancelled|completed|no_show, default="confirmed")
    reason = CharField(max_length=500, blank=True)
    cancelled_by = ForeignKey(User, null=True, SET_NULL); cancellation_reason = CharField(max_length=500, blank=True)
    created_at, updated_at
    # UniqueConstraint(doctor, start_at) WHERE status = 'confirmed'
```
`doctor_id` is the doctor's user id, like everywhere (TEAM_PLAN §3).

## 3. Endpoints

All under `/api/v1/`. Anonymous: `401` everywhere.

| # | Method & path | Who |
|---|---|---|
| 1 | `GET appointments/slots/?doctor=<id>&date=YYYY-MM-DD` | any logged-in user (doctor must be visible, else `404`) |
| 2 | `POST appointments/` `{doctor, start_at, reason?}` | patient |
| 3 | `GET appointments/?scope=upcoming\|past&status=&date=&doctor=&patient=` | logged in, scoped by role (filters `doctor`, `patient` are meant for admins; they can never widen another role's scope) |
| 4 | `GET appointments/{id}/` | participant or admin (else `404`) |
| 5 | `POST appointments/{id}/cancel/` `{reason?}` | patient (own), doctor (own), admin |
| 6 | `POST appointments/{id}/complete/` · `POST appointments/{id}/no-show/` (no body) | owning doctor |

`date` filters on the clinic day (`TIME_ZONE`) of `start_at`. Invalid `scope`, `status` or `date` → `400 validation_error` with the field code (`invalid_choice`, `invalid`). The list is paginated (TEAM_PLAN §4.3).

### Examples

`GET appointments/slots/?doctor=12&date=2026-11-05` → `200` (offsets are the clinic's):
```json
{ "doctor": 12, "date": "2026-11-05", "consultation_minutes": 30,
  "slots": [ { "start_at": "2026-11-05T09:00:00+01:00", "end_at": "2026-11-05T09:30:00+01:00" } ] }
```
Book by sending a slot's `start_at` unchanged (an instant, with or without offset; no offset is read in `TIME_ZONE`):
```json
{ "doctor": 12, "start_at": "2026-11-05T09:00:00+01:00", "reason": "Palpitations" }
```
`Appointment` (answer of 2, 4, 5, 6; items of 3). The doctor card has no email or phone; the patient is the `UserSummary` of AUTH.md. `cancelled_by` is `null` or `{id, role}`:
```json
{ "id": 41,
  "patient": { "id": 7, "first_name": "Amira", "last_name": "Ben Salah", "email": "amira@medapp.local", "phone": "" },
  "doctor": { "id": 12, "first_name": "Sarah", "last_name": "Miller",
              "specialty": { "id": 3, "name_fr": "Cardiologie", "name_en": "Cardiology" } },
  "start_at": "2026-11-05T09:00:00+01:00", "end_at": "2026-11-05T09:30:00+01:00",
  "status": "confirmed", "reason": "Palpitations",
  "cancelled_by": null, "cancellation_reason": "",
  "created_at": "2026-11-02T07:00:12.481312+01:00", "updated_at": "2026-11-02T07:00:12.481312+01:00" }
```

## 4. Error codes

| Status | `code` | When | ARB |
|---|---|---|---|
| 409 | `slot_taken` | the slot is already booked (including the race lost to another patient) | `errorSlotTaken` |
| 400 | `slot_not_available` | `start_at` is not a slot start of that doctor, is in the past, inside the lead time, beyond the horizon, or in a time off / day off | `errorSlotNotAvailable` |
| 400 | `cancellation_too_late` | patient cancels after the cutoff | `errorCancellationTooLate` |
| 409 | `invalid_status_transition` | any action on a non-`confirmed` appointment; complete / no-show before the start; doctor/admin cancel after the start | `errorInvalidStatusTransition` |
| 409 | `booking_limit_reached` | patient limits above; `details.reason` tells which | `errorBookingLimitReached` |
| 429 | `throttled` | too many booking / cancel requests | – |
| 409 | `time_off_conflict` | M2's `POST doctors/me/time-off/` over confirmed appointments (has `error.details`) | `errorTimeOffConflict` |
| 400 | `validation_error` | `doctor` unknown / not bookable (`does_not_exist`), missing fields (`required`), bad `start_at` (`invalid`), `reason` too long (`max_length`), doctor/admin cancel without reason (`blank`), bad filters | – |
| 401/403/404 | generic | not logged in / wrong role (e.g. a patient on `complete`) / not your appointment | – |

`time_off_conflict` answer: the usual envelope plus
```json
"details": { "count": 2, "appointments": [ { "id": 41, "start_at": "2026-11-05T09:00:00+01:00", "end_at": "2026-11-05T09:30:00+01:00", "patient_name": "Amira Ben Salah" } ] }
```
(`appointments` holds at most the first 50; `count` is exact.) `details` is a generic optional field of `BusinessError` (TEAM_PLAN §4.3).

## 5. Contract for M4: `appointment_event`

```python
from appointments.signals import appointment_event   # Signal; sender = Appointment

@receiver(appointment_event)
def on_event(sender, appointment, event, **kwargs): ...
```
- `event` is `"confirmed"` (after a booking) or `"cancelled"` (after a cancellation, **including the automatic ones when an admin deactivates a patient**: one event per appointment, `cancelled_by` = the admin, inside the deactivation transaction). Constants: `signals.EVENT_CONFIRMED`, `EVENT_CANCELLED`. `complete` and `no-show` send nothing.
- Sent with `Signal.send` **inside** the booking / cancellation `transaction.atomic()`, after the row is written. A receiver can create its outbox rows in the same transaction (never lost, never created for a failed booking). **A receiver that raises rolls the booking back**: keep receivers small and don't send email there.
- `appointment` is fresh: `.patient`, `.doctor` (`.doctor.user`, `.doctor.specialty`) are loaded for `cancelled`; for `confirmed` they are the objects used by the service. `cancelled_by` (a `User`, `.role` tells patient / doctor / admin) and `cancellation_reason` are set on `cancelled`. Use `appointment.pk`, `start_at`, `end_at`, `reason`.
- Not sent when the action fails (`slot_taken`, `cancellation_too_late`, …). Reminders are M4's worker business (`status=confirmed` and starting soon).
- For tests without M3 internals: `appointment_event.send(sender=Appointment, appointment=a, event="confirmed")`.

Python helpers other apps may use: `appointments.services.free_slots(doctor, day)`, `book`, `cancel`, `complete`, `mark_no_show`. The clock of the module is `services._now()` (patch it in tests).

## 6. Tests and fixtures

`appointments/tests/` (clock frozen at 2026-11-02 07:00 Tunis, settings pinned, every weekday 09–12 in `conftest.py`):
- `test_slots.py`: grid, booked/cancelled/overlapping, remainder, time off, lead time, horizon, DST, validation, roles, hidden doctors.
- `test_booking.py`: happy path, `slot_taken`, every `slot_not_available` case, roles, validation, hidden doctors by direct id, DB constraints, `Accept-Language`.
- `test_lifecycle.py`: cancellation cutoff (exact boundary), doctor/admin rules, the whole state matrix, permissions.
- `test_list.py`: scoping per role, detail 404s, `scope` / `status` / `date` / admin filters, pagination.
- `test_signals.py`: event inside the transaction, rollback when a receiver fails, nothing sent on failure.
- `test_concurrency.py`: **real threads against Postgres** (racing patients: exactly one winner; the second booking blocks on the doctor row until the first commits; a time off waits for an in-flight booking then conflicts). Uses `django_db(transaction=True)`.
- `test_limits.py`: booking limits (+ a real-thread test that one patient cannot exceed the cap across doctors), throttle, absurd dates, read-only admin, deactivation cancels.
- `test_time_off.py`: `time_off_conflict` (boundaries, statuses, cap) and "availability edits keep bookings".
- `test_seed.py`.

## 7. Flutter side

No new package. Files under `lib/features/appointments/`:
```
data/models/appointment.dart            # Appointment, AppointmentPerson, Slot, AppointmentStatus/Scope
data/appointments_repository.dart       # every call; appointmentsRepositoryProvider (fake it in tests)
presentation/appointments_providers.dart# appointmentsListProvider(query), appointmentProvider(id), slotsProvider,
                                        # upcomingConfirmedProvider, appointmentsActionsProvider
presentation/appointments_routes.dart   # patientAppointmentRoute(id), doctorAppointmentRoute(id)
presentation/screens/                   # booking, appointments_tabs (patient + doctor agenda), appointment_detail
presentation/widgets/                   # tile, status chip, cancel dialog
```
Routes and tabs (in `app/router.dart` and the shells):

| Role | Tab | Route |
|---|---|---|
| Patient | Doctors | `/patient` → `/patient/doctors/:id` → `/patient/doctors/:id/book` (`BookingScreen`; after booking, `go` to the detail) |
| Patient | Appointments (new, tab 2) | `/patient/appointments` (upcoming / past) → `/patient/appointments/:id` |
| Doctor | Agenda (home, was the placeholder) | `/doctor` (today / upcoming / past) → `/doctor/appointments/:id` |

- Admin has no appointments screen (not in the plan; the admin API with `doctor` / `patient` / `date` filters exists, and M4's dashboard shows counts).
- Times are displayed in the **clinic's wall clock** (`Appointment.start/end`, parsed like M2's time off), while `startAt/endAt` are absolute UTC instants for comparisons and reminders. A slot's `startIso` is posted back unchanged.
- Detail actions: patient: cancel while the appointment has not started (the server decides the cutoff and answers `cancellation_too_late` inside the dialog); doctor: cancel (reason required) before the start, complete / no-show once started.
- Detail screens are not cached (auto-dispose), support pull-to-refresh, and reload themselves when the server refuses an action; empty lists can be pulled to refresh too. After a booking the booking screen is popped before going to the new appointment.
- After any write, lists, details, slots and `upcomingConfirmedProvider` are invalidated, so screens reload from the server.
- **For M4 (on-device reminders):** `ref.read(appointmentsRepositoryProvider).fetchUpcoming()` returns every confirmed upcoming appointment (all pages, earliest first, capped at 10 pages of 100 = 1000 appointments, far above the per-patient limit; `startAt` is the UTC instant to schedule at). `upcomingConfirmedProvider` wraps it and is invalidated by every booking / cancellation; M4 can `ref.listen` it to resync. `test/support/fake_appointments_repository.dart` (`FakeAppointmentsRepository`, `fakeAppointment()`) is meant for M4's tests.
- Time off screen (M2): `TimeOffConflict.from(error)` reads the `time_off_conflict` details and the dialog lists the blocking appointments.
