"""Demo appointments for the demo patient (idempotent per doctor and status, one transaction).

Runs after doctors.seed. Rows are created directly (not through `services.book`): past ones
could not be booked, and seeding must not queue notification emails. Dates are relative to
today and land on days the doctor actually works.
"""

from datetime import date, datetime, timedelta

from django.db import transaction
from django.utils import timezone

from accounts.models import User
from doctors.models import DoctorProfile, WeeklyAvailability

from .models import Appointment

PATIENT_EMAIL = "amira@medapp.local"

# (doctor email, days from today (negative = past), status, reason, cancelled by patient)
DEMO_APPOINTMENTS = [
    ("dr.karim@medapp.local", -9, Appointment.Status.COMPLETED, "Contrôle annuel", False),
    ("dr.sarah@medapp.local", -5, Appointment.Status.CANCELLED, "Palpitations", True),
    ("dr.karim@medapp.local", -2, Appointment.Status.NO_SHOW, "Toux persistante", False),
    (
        "dr.karim@medapp.local",
        3,
        Appointment.Status.CONFIRMED,
        "Renouvellement d'ordonnance",
        False,
    ),
    ("dr.sarah@medapp.local", 6, Appointment.Status.CONFIRMED, "Check-up cardiaque", False),
]


def _working_start(profile: DoctorProfile, around: date, step: int) -> datetime | None:
    """First window start on the nearest working day from `around` going `step` days at a
    time (+1 forward, -1 backward)."""
    for offset in range(14):
        day = around + timedelta(days=step * offset)
        window = (
            WeeklyAvailability.objects.filter(doctor=profile, weekday=day.weekday())
            .order_by("start_time")
            .first()
        )
        if window is not None:
            return timezone.make_aware(datetime.combine(day, window.start_time))
    return None


@transaction.atomic
def run() -> None:
    patient = User.objects.filter(email=PATIENT_EMAIL, role=User.Role.PATIENT).first()
    if patient is None:
        return
    today = timezone.localdate()
    for doctor_email, days, status, reason, by_patient in DEMO_APPOINTMENTS:
        profile = DoctorProfile.objects.filter(user__email=doctor_email).first()
        if profile is None:
            continue
        if Appointment.objects.filter(patient=patient, doctor=profile, status=status).exists():
            continue  # already seeded (per doctor and status)
        start = _working_start(profile, today + timedelta(days=days), 1 if days > 0 else -1)
        if start is None:
            continue
        end = start + timedelta(minutes=profile.consultation_minutes)
        busy = Appointment.objects.filter(
            doctor=profile, start_at=start, status=Appointment.Status.CONFIRMED
        )
        if busy.exists():
            continue
        Appointment.objects.create(
            patient=patient,
            doctor=profile,
            start_at=start,
            end_at=end,
            status=status,
            reason=reason,
            cancelled_by=patient if by_patient else None,
            cancellation_reason="Empêchement" if by_patient else "",
        )
