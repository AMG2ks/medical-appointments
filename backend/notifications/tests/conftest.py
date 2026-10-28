"""Fixtures of the notifications tests.

The clock of `appointments.services` is frozen at Monday 2026-11-02 07:00 in Tunis, and the
doctor works 09:00-12:00 every day (30-minute consultations).
"""

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from django.utils import timezone

from accounts.models import User
from appointments import services as appointment_services
from appointments.models import Appointment
from doctors.models import WeeklyAvailability

NOW = datetime(2026, 11, 2, 6, 0, tzinfo=UTC)  # 07:00 in Tunis
TUNIS = ZoneInfo("Africa/Tunis")
DAY = date(2026, 11, 5)  # Thursday, 3 days after NOW

NOTIFICATIONS = "/api/v1/notifications/"


def at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=TUNIS)


@pytest.fixture(autouse=True)
def clock(monkeypatch, settings):
    monkeypatch.setattr(appointment_services, "_now", lambda: NOW)
    # The worker's own clock (relevance checks, purge), and created_at.
    monkeypatch.setattr(timezone, "now", lambda: NOW)
    settings.BOOKING_HORIZON_DAYS = 30
    settings.BOOKING_MIN_LEAD_MINUTES = 60
    settings.CANCELLATION_MIN_HOURS = 24
    settings.NOTIFICATION_MAX_ATTEMPTS = 3
    settings.REMINDER_MINUTES_BEFORE = 1440


@pytest.fixture
def profile(doctor):
    profile = doctor.doctor_profile
    WeeklyAvailability.objects.bulk_create(
        WeeklyAvailability(doctor=profile, weekday=d, start_time=time(9), end_time=time(12))
        for d in range(7)
    )
    return profile


@pytest.fixture
def book(patient, profile):
    """`book(hour)` books the patient with the doctor on DAY through the real service."""

    def make(hour: int = 10) -> Appointment:
        return appointment_services.book(
            patient=patient, doctor_id=profile.pk, start_at=at(DAY, hour), reason="x"
        )

    return make


@pytest.fixture
def make_appointment(patient, profile):
    """A confirmed appointment created directly (no signal), `delta` after NOW."""

    def make(delta: timedelta, status=Appointment.Status.CONFIRMED) -> Appointment:
        start = NOW + delta
        return Appointment.objects.create(
            patient=patient,
            doctor=profile,
            start_at=start,
            end_at=start + timedelta(minutes=30),
            status=status,
        )

    return make


@pytest.fixture
def french(patient, doctor):
    User.objects.filter(pk=patient.pk).update(preferred_language="fr")
    User.objects.filter(pk=doctor.pk).update(preferred_language="fr")
