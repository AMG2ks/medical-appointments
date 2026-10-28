"""Business rules of the appointments module (plain functions, no HTTP).

All arithmetic is done on UTC instants: `working_intervals` returns datetimes carrying a
ZoneInfo, and subtracting two of them ignores DST (see docs/modules/DOCTORS.md section 5).
"""

from datetime import UTC, date, datetime, timedelta

from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import Q
from django.utils import timezone
from django.utils.translation import gettext as _
from django.utils.translation import gettext_noop
from rest_framework.exceptions import ErrorDetail, PermissionDenied, ValidationError

from accounts.models import User
from core.exceptions import BusinessError
from doctors.models import DoctorProfile
from doctors.services import visible_doctors, working_intervals

from .models import Appointment
from .signals import EVENT_CANCELLED, EVENT_CONFIRMED, appointment_event

Slot = tuple[datetime, datetime]

# Reasons written by the system when an account is deactivated. Stored in English (the source
# language, whatever language the acting admin uses) and translated when an appointment is
# serialized (`AppointmentSerializer`), in the language of whoever reads it.
REASON_PATIENT_DEACTIVATED = gettext_noop("Account deactivated by an administrator.")
REASON_DOCTOR_DEACTIVATED = gettext_noop(
    "The doctor's account was deactivated by an administrator."
)
AUTOMATIC_REASONS = {REASON_PATIENT_DEACTIVATED, REASON_DOCTOR_DEACTIVATED}

# Most conflicting appointments listed in a `time_off_conflict` answer (the count is exact).
TIME_OFF_CONFLICTS_LISTED = 50


def _now() -> datetime:
    """The one clock of this module (tests patch it)."""
    return timezone.now()


# --- slots ---


def bookable_doctor(user, doctor_id: int, *, lock: bool = False) -> DoctorProfile | None:
    """The doctor if `user` may see (hence book) them: active, role=doctor, invite accepted
    (`doctors.views.visible_doctors`). `lock=True` takes the doctor-row lock that serializes
    bookings and time off of this doctor (must run inside a transaction)."""
    doctors = visible_doctors(user)
    if lock:
        doctors = doctors.select_for_update(of=("self",))
    return doctors.filter(pk=doctor_id).first()


def _grid(doctor: DoctorProfile, day: date) -> list[Slot]:
    """Working intervals of `day` cut into consultation-length slots (UTC), sorted. A trailing
    remainder shorter than a consultation is dropped."""
    step = timedelta(minutes=doctor.consultation_minutes)
    slots: list[Slot] = []
    for start, end in working_intervals(doctor, day):
        cursor, stop = start.astimezone(UTC), end.astimezone(UTC)
        while cursor + step <= stop:
            slots.append((cursor, cursor + step))
            cursor += step
    return slots


def _bookable_grid(doctor: DoctorProfile, day: date, now: datetime) -> list[Slot]:
    """Grid slots of `day` that respect the booking horizon (calendar days: today up to
    today + BOOKING_HORIZON_DAYS inclusive, in TIME_ZONE) and the minimum lead time."""
    today = timezone.localtime(now).date()
    # Checked before the grid is computed: absurd dates (year 1, 9999) never reach datetime
    # arithmetic that could overflow.
    if day < today or day > today + timedelta(days=settings.BOOKING_HORIZON_DAYS):
        return []
    earliest = now + timedelta(minutes=settings.BOOKING_MIN_LEAD_MINUTES)
    return [slot for slot in _grid(doctor, day) if slot[0] >= earliest]


def _overlapping(doctor_id: int, start: datetime, end: datetime):
    return Appointment.objects.filter(
        doctor_id=doctor_id,
        status=Appointment.Status.CONFIRMED,
        start_at__lt=end,
        end_at__gt=start,
    )


def free_slots(doctor: DoctorProfile, day: date) -> list[Slot]:
    """Free slots of `doctor` on calendar `day` (in TIME_ZONE): working intervals cut into
    `consultation_minutes`, minus confirmed appointments, inside the horizon and at least
    BOOKING_MIN_LEAD_MINUTES from now. Past days, far days and days off give []."""
    candidates = _bookable_grid(doctor, day, _now())
    if not candidates:
        return []
    booked = list(
        _overlapping(doctor.pk, candidates[0][0], candidates[-1][1]).values_list(
            "start_at", "end_at"
        )
    )
    return [
        (start, end)
        for start, end in candidates
        if not any(b_start < end and b_end > start for b_start, b_end in booked)
    ]


# --- booking ---


def _slot_taken() -> BusinessError:
    return BusinessError("slot_taken", _("This slot is already taken."), status_code=409)


def _limit_reached(reason: str, message: str) -> BusinessError:
    """`details.reason`: max_upcoming | same_doctor | overlap."""
    return BusinessError(
        "booking_limit_reached", message, status_code=409, details={"reason": reason}
    )


def _check_patient_limits(patient: User, doctor_id: int, slot: Slot, now: datetime) -> None:
    mine = Appointment.objects.filter(patient=patient, status=Appointment.Status.CONFIRMED)
    if mine.filter(start_at__lt=slot[1], end_at__gt=slot[0]).exists():
        raise _limit_reached("overlap", _("You already have an appointment at that time."))
    upcoming = mine.filter(start_at__gte=now)
    if upcoming.filter(doctor_id=doctor_id).exists():
        raise _limit_reached(
            "same_doctor", _("You already have an upcoming appointment with this doctor.")
        )
    if upcoming.count() >= settings.MAX_UPCOMING_APPOINTMENTS_PER_PATIENT:
        raise _limit_reached(
            "max_upcoming", _("You have reached the maximum number of upcoming appointments.")
        )


def book(*, patient: User, doctor_id: int, start_at: datetime, reason: str = "") -> Appointment:
    """Book `start_at` with a doctor; confirmed at once.

    Runs in one transaction that locks the patient row (so one patient booking several
    doctors in parallel is serialized for the per-patient limits) and then the doctor row (so
    two bookings, or a booking and a time off, of the same doctor are serialized). The partial
    unique constraint is the DB backstop. `appointment_event("confirmed")` is sent inside the
    transaction."""
    now = _now()
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=patient.pk)
        if not locked.is_active:  # deactivated while the request was in flight
            raise PermissionDenied()
        doctor = bookable_doctor(patient, doctor_id, lock=True)
        if doctor is None:  # unknown, inactive, not a doctor, or invite not accepted
            raise ValidationError(
                {"doctor": [ErrorDetail(_("This doctor does not exist."), code="does_not_exist")]}
            )
        try:
            start = start_at.astimezone(UTC)
            day = timezone.localtime(start).date()
        except (OverflowError, ValueError):  # year 1, year 9999...
            raise BusinessError(
                "slot_not_available", _("This time is not available for booking.")
            ) from None
        slot = next((s for s in _bookable_grid(doctor, day, now) if s[0] == start), None)
        if slot is None:
            raise BusinessError("slot_not_available", _("This time is not available for booking."))
        if _overlapping(doctor.pk, *slot).exists():
            raise _slot_taken()
        _check_patient_limits(patient, doctor.pk, slot, now)
        try:
            with transaction.atomic():  # savepoint: keep the outer transaction usable
                appointment = Appointment.objects.create(
                    patient=patient, doctor=doctor, start_at=slot[0], end_at=slot[1], reason=reason
                )
        except IntegrityError:
            raise _slot_taken() from None
        appointment_event.send(sender=Appointment, appointment=appointment, event=EVENT_CONFIRMED)
    return appointment


# --- lifecycle ---


def _lock(appointment: Appointment) -> Appointment:
    return (
        Appointment.objects.select_for_update(of=("self",))
        .select_related("patient", "doctor__user", "doctor__specialty")
        .get(pk=appointment.pk)
    )


def _invalid_transition() -> BusinessError:
    return BusinessError(
        "invalid_status_transition",
        _("This appointment cannot change to that status."),
        status_code=409,
    )


def _ensure_participant(appointment: Appointment, actor: User) -> None:
    """Defence in depth: views already scope the queryset (others get 404)."""
    allowed = (
        actor.role == User.Role.ADMIN
        or (actor.role == User.Role.PATIENT and appointment.patient_id == actor.pk)
        or (actor.role == User.Role.DOCTOR and appointment.doctor_id == actor.pk)
    )
    if not allowed:
        raise PermissionDenied()


def cancel(appointment: Appointment, *, actor: User, reason: str = "") -> Appointment:
    """Cancel a confirmed appointment.

    The patient may cancel until CANCELLATION_MIN_HOURS before the start (else
    `cancellation_too_late`); the doctor and admins until the start, and they must give a
    reason. Sends `appointment_event("cancelled")` inside the transaction."""
    now = _now()
    with transaction.atomic():
        appointment = _lock(appointment)
        _ensure_participant(appointment, actor)
        if appointment.status != Appointment.Status.CONFIRMED:
            raise _invalid_transition()
        if actor.role == User.Role.PATIENT:
            cutoff = appointment.start_at - timedelta(hours=settings.CANCELLATION_MIN_HOURS)
            if now > cutoff:
                raise BusinessError(
                    "cancellation_too_late",
                    _("It is too late to cancel this appointment."),
                )
        else:
            if appointment.start_at <= now:  # started: complete or no-show it instead
                raise _invalid_transition()
            if not reason.strip():
                raise ValidationError(
                    {"reason": [ErrorDetail(_("This field may not be blank."), code="blank")]}
                )
        appointment.status = Appointment.Status.CANCELLED
        appointment.cancelled_by = actor
        appointment.cancellation_reason = reason
        appointment.save(
            update_fields=["status", "cancelled_by", "cancellation_reason", "updated_at"]
        )
        appointment_event.send(sender=Appointment, appointment=appointment, event=EVENT_CANCELLED)
    return appointment


def _finish(appointment: Appointment, *, actor: User, status: str) -> Appointment:
    now = _now()
    with transaction.atomic():
        appointment = _lock(appointment)
        if actor.role != User.Role.DOCTOR or appointment.doctor_id != actor.pk:
            raise PermissionDenied()
        if appointment.status != Appointment.Status.CONFIRMED or appointment.start_at > now:
            raise _invalid_transition()
        appointment.status = status
        appointment.save(update_fields=["status", "updated_at"])
    return appointment


def complete(appointment: Appointment, *, actor: User) -> Appointment:
    """The owning doctor marks a confirmed appointment that has started as completed."""
    return _finish(appointment, actor=actor, status=Appointment.Status.COMPLETED)


def mark_no_show(appointment: Appointment, *, actor: User) -> Appointment:
    """The owning doctor marks a confirmed appointment that has started as a no-show."""
    return _finish(appointment, actor=actor, status=Appointment.Status.NO_SHOW)


# --- time off guard (registered in apps.py, called by doctors.services.create_time_off) ---


def time_off_conflicts(doctor: DoctorProfile, start_at: datetime, end_at: datetime) -> dict | None:
    """Confirmed appointments overlapping [start_at, end_at) block a time off. Returns the
    `error.details` payload (exact count + the first ones) or None."""
    conflicts = _overlapping(doctor.pk, start_at, end_at).select_related("patient")
    count = conflicts.count()
    if not count:
        return None
    return {
        "count": count,
        "appointments": [
            {
                "id": a.pk,
                "start_at": timezone.localtime(a.start_at).isoformat(),
                "end_at": timezone.localtime(a.end_at).isoformat(),
                "patient_name": f"{a.patient.first_name} {a.patient.last_name}".strip(),
            }
            for a in conflicts.order_by("start_at")[:TIME_OFF_CONFLICTS_LISTED]
        ],
    }


# --- account deactivation (receiver of accounts.signals.user_deactivated, see apps.py) ---


def cancel_future_appointments_of(user: User, *, by: User, **kwargs) -> None:
    """A deactivated patient or doctor keeps no future appointment: they are cancelled by the
    acting admin (slots freed, `appointment_event("cancelled", automatic=True)` for each),
    inside the caller's transaction. Appointments already started are left for the doctor to
    close. Admins: nothing to cancel."""
    if user.role == User.Role.PATIENT:
        who = Q(patient=user)
        reason = REASON_PATIENT_DEACTIVATED
    elif user.role == User.Role.DOCTOR:
        who = Q(doctor_id=user.pk)
        reason = REASON_DOCTOR_DEACTIVATED
    else:
        return
    now = _now()
    with transaction.atomic():
        User.objects.select_for_update().get(pk=user.pk)
        if user.role == User.Role.DOCTOR:
            # Same lock as booking: a booking in flight finishes first, a later one no longer
            # sees the doctor (inactive).
            DoctorProfile.objects.select_for_update().filter(pk=user.pk).first()
        pending = list(
            Appointment.objects.select_for_update(of=("self",))
            .select_related("patient", "doctor__user", "doctor__specialty")
            .filter(who, status=Appointment.Status.CONFIRMED, start_at__gt=now)
            .order_by("start_at")
        )
        for appointment in pending:
            appointment.status = Appointment.Status.CANCELLED
            appointment.cancelled_by = by
            appointment.cancellation_reason = reason
            appointment.save(
                update_fields=["status", "cancelled_by", "cancellation_reason", "updated_at"]
            )
            appointment_event.send(
                sender=Appointment,
                appointment=appointment,
                event=EVENT_CANCELLED,
                automatic=True,
            )
