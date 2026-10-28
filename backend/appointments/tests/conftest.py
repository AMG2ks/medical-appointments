"""Fixtures of the appointments tests.

The clock is frozen (`services._now`) at Monday 2026-11-02 07:00 in Tunis (UTC+1), so every
test is deterministic. All week days have a 09:00-12:00 window (30-minute consultations).
"""

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest

from accounts.models import PatientProfile, User
from appointments import services
from appointments.models import Appointment
from doctors.models import DoctorProfile, WeeklyAvailability

NOW = datetime(2026, 11, 2, 6, 0, tzinfo=UTC)  # 07:00 in Tunis
TUNIS = ZoneInfo("Africa/Tunis")
DAY = date(2026, 11, 5)  # Thursday, 3 days after NOW

SLOTS = "/api/v1/appointments/slots/"
APPOINTMENTS = "/api/v1/appointments/"


def at(day: date, hour: int, minute: int = 0) -> datetime:
    """Wall-clock time in the clinic's zone, as an aware datetime."""
    return datetime.combine(day, time(hour, minute), tzinfo=TUNIS)


def code(response) -> str:
    return response.data["error"]["code"]


@pytest.fixture(autouse=True)
def clock(monkeypatch, settings):
    monkeypatch.setattr(services, "_now", lambda: NOW)
    # Independent of backend/.env.
    settings.BOOKING_HORIZON_DAYS = 30
    settings.BOOKING_MIN_LEAD_MINUTES = 60
    settings.CANCELLATION_MIN_HOURS = 24


@pytest.fixture
def profile(doctor) -> DoctorProfile:
    profile = doctor.doctor_profile
    WeeklyAvailability.objects.bulk_create(
        WeeklyAvailability(doctor=profile, weekday=d, start_time=time(9), end_time=time(12))
        for d in range(7)
    )
    return profile


@pytest.fixture
def other_patient(db):
    user = User.objects.create_user(
        "other.patient@example.com", "x", first_name="Oth", last_name="Er", role=User.Role.PATIENT
    )
    PatientProfile.objects.create(user=user)
    return user


@pytest.fixture
def other_doctor(db, specialty):
    user = User.objects.create_user(
        "other.doctor@example.com", "x", first_name="Ot", last_name="Doc", role=User.Role.DOCTOR
    )
    return DoctorProfile.objects.create(user=user, specialty=specialty)


@pytest.fixture
def make_appointment(patient, profile):
    def make(
        start: datetime,
        *,
        status=Appointment.Status.CONFIRMED,
        patient_=None,
        doctor_=None,
        minutes=30,
        reason="",
    ) -> Appointment:
        return Appointment.objects.create(
            patient=patient_ or patient,
            doctor=doctor_ or profile,
            start_at=start,
            end_at=start + timedelta(minutes=minutes),
            status=status,
            reason=reason,
        )

    return make
