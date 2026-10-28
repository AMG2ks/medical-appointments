"""Business rules of the doctors module (plain functions, no HTTP)."""

import logging
from collections.abc import Callable
from datetime import UTC, date, datetime, time, timedelta

from django.contrib.auth.hashers import UNUSABLE_PASSWORD_PREFIX
from django.db import IntegrityError, transaction
from django.db.models import ProtectedError
from django.utils import timezone
from django.utils.translation import gettext as _
from rest_framework.exceptions import ErrorDetail, ValidationError

from accounts import services as accounts_services
from accounts.models import User
from core.exceptions import BusinessError

from .models import DoctorProfile, Specialty, TimeOff, WeeklyAvailability

logger = logging.getLogger(__name__)

# --- doctors ---


def visible_doctors(user):
    """Doctors a user may see: active doctor accounts. Doctors who have not accepted their
    invite yet (no usable password) are hidden from everyone but admins, so nobody can book
    an account that cannot log in. Booking and slots apply the same rule."""
    doctors = DoctorProfile.objects.filter(
        user__is_active=True, user__role=User.Role.DOCTOR
    ).select_related("user", "specialty")
    if getattr(user, "role", None) != User.Role.ADMIN:  # anonymous: schema generation
        doctors = doctors.exclude(user__password__startswith=UNUSABLE_PASSWORD_PREFIX)
    return doctors


def _send_invite(user: User) -> None:
    """After commit. The doctor already exists: a mail failure must not turn the admin's
    successful create into a 500. The doctor can still use "Forgot password"."""
    try:
        accounts_services.send_password_code(user, purpose="invite")
    except Exception:  # noqa: BLE001 - any mail/SMTP failure; logged with traceback, no address
        logger.exception("Invite email failed for doctor user %s", user.pk)


def create_doctor(*, data: dict) -> DoctorProfile:
    """Admin creates a doctor: User(role=doctor, no password) + profile, then an invite code.

    `data` is already validated (CreateDoctorSerializer). The invite email is sent only once
    the transaction committed, so a rollback never mails a code for a missing account.
    """
    try:
        with transaction.atomic():
            user = accounts_services.create_user(
                email=data["email"],
                first_name=data["first_name"],
                last_name=data["last_name"],
                role=User.Role.DOCTOR,
                phone=data.get("phone", ""),
                preferred_language=data.get("preferred_language"),
            )
            profile = DoctorProfile.objects.create(
                user=user,
                specialty=data["specialty"],
                bio=data.get("bio", ""),
                consultation_minutes=data.get("consultation_minutes", 30),
            )
            transaction.on_commit(lambda: _send_invite(user))
    except IntegrityError:
        # Two admins creating the same email at once: the serializer check passed for both.
        if User.objects.filter(email__iexact=data["email"]).exists():
            raise ValidationError(
                {"email": [ErrorDetail(_("A user with this email already exists."), code="unique")]}
            ) from None
        raise
    return profile


# --- specialties ---


def delete_specialty(specialty: Specialty) -> None:
    try:
        specialty.delete()
    except ProtectedError as exc:
        raise BusinessError(
            "specialty_in_use", _("This specialty is used by doctors."), status_code=409
        ) from exc


# --- weekly availability ---


def _raise_overlap() -> None:
    raise BusinessError("availability_overlap", _("This period overlaps an existing availability."))


def save_availability(
    doctor: DoctorProfile,
    *,
    weekday: int,
    start_time: time,
    end_time: time,
    instance: WeeklyAvailability | None = None,
) -> WeeklyAvailability:
    """Create or update a window; windows of one weekday must not overlap (touching is fine)."""
    with transaction.atomic():
        # Serialize concurrent edits of the same doctor so two requests cannot both pass the check.
        DoctorProfile.objects.select_for_update().get(pk=doctor.pk)
        clashes = WeeklyAvailability.objects.filter(
            doctor=doctor, weekday=weekday, start_time__lt=end_time, end_time__gt=start_time
        )
        if instance is not None:
            clashes = clashes.exclude(pk=instance.pk)
        if clashes.exists():
            _raise_overlap()
        if instance is None:
            instance = WeeklyAvailability(doctor=doctor)
        instance.weekday, instance.start_time, instance.end_time = weekday, start_time, end_time
        instance.save()
    return instance


# --- time off ---

# A guard is called as guard(doctor, start_at, end_at) under the doctor's row lock and returns
# None (fine) or a JSON-serializable dict explaining why the time off cannot be created. Apps
# that depend on doctors (appointments) register one in AppConfig.ready(): doctors never
# imports them.
TimeOffGuard = Callable[[DoctorProfile, datetime, datetime], "dict | None"]
_time_off_guards: list[TimeOffGuard] = []


def register_time_off_guard(guard: TimeOffGuard) -> None:
    if guard not in _time_off_guards:
        _time_off_guards.append(guard)


def create_time_off(
    doctor: DoctorProfile, *, start_at: datetime, end_at: datetime, reason: str = ""
) -> TimeOff:
    """Create a time off unless a guard refuses (409 `time_off_conflict`, details attached).

    Runs under the same doctor-row lock as booking, so a booking cannot slip in between the
    check and the insert."""
    with transaction.atomic():
        DoctorProfile.objects.select_for_update().get(pk=doctor.pk)
        for guard in _time_off_guards:
            details = guard(doctor, start_at, end_at)
            if details:
                raise BusinessError(
                    "time_off_conflict",
                    _("Appointments are already booked during this period."),
                    status_code=409,
                    details=details,
                )
        return TimeOff.objects.create(
            doctor=doctor, start_at=start_at, end_at=end_at, reason=reason
        )


# --- working intervals (contract for M3) ---


def _instant(day: date, at: time, tz) -> datetime:
    """Wall-clock `at` on `day` in `tz`, as a UTC instant. A nonexistent local time (DST
    gap) resolves to the instant after the gap; an ambiguous one to its first occurrence."""
    return datetime.combine(day, at, tzinfo=tz).astimezone(UTC)


def working_intervals(doctor: DoctorProfile, day: date) -> list[tuple[datetime, datetime]]:
    """Time windows in which `doctor` works on calendar `day`, as sorted, timezone-aware
    `(start, end)` pairs expressed in `settings.TIME_ZONE`, with time off already removed.

    Availability is wall-clock in the configured zone, so a window is 09:00-12:00 local even
    on a DST change day. All the arithmetic is done on UTC instants, so DST gaps (a window
    lying entirely inside the missing hour disappears) and repeated hours are handled.
    `doctor` is a DoctorProfile (or anything with a `pk` equal to the doctor id).
    """
    tz = timezone.get_default_timezone()
    windows = [
        (_instant(day, a.start_time, tz), _instant(day, a.end_time, tz))
        for a in WeeklyAvailability.objects.filter(doctor_id=doctor.pk, weekday=day.weekday())
    ]
    windows = [(start, end) for start, end in windows if start < end]
    if not windows:
        return []

    day_start = _instant(day, time.min, tz)
    day_end = _instant(day + timedelta(days=1), time.min, tz)
    # Time off may start before or end after the day: select everything that touches it.
    blocks = list(
        TimeOff.objects.filter(doctor_id=doctor.pk, start_at__lt=day_end, end_at__gt=day_start)
        .order_by("start_at")
        .values_list("start_at", "end_at")
    )

    result: list[tuple[datetime, datetime]] = []
    for start, end in sorted(windows):
        cursor = start
        for off_start, off_end in blocks:  # sorted by start, may overlap each other
            if off_end <= cursor:
                continue
            if off_start >= end:
                break
            if off_start > cursor:
                result.append((cursor, off_start))
            cursor = max(cursor, off_end)
            if cursor >= end:
                break
        if cursor < end:
            result.append((cursor, end))
    return [(s.astimezone(tz), e.astimezone(tz)) for s, e in result]


__all__ = [
    "create_doctor",
    "create_time_off",
    "delete_specialty",
    "register_time_off_guard",
    "visible_doctors",
    "save_availability",
    "working_intervals",
]
