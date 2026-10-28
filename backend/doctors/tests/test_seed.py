import pytest
from django.core.management import call_command

from accounts.models import User
from doctors.models import DoctorProfile, Specialty, WeeklyAvailability


@pytest.mark.django_db
def test_seed_is_idempotent_and_equips_demo_doctors(settings):
    settings.SEED_DEMO_PASSWORD = "Demo-Pass-2026!x"
    call_command("seed_demo")
    counts = (
        Specialty.objects.count(),
        DoctorProfile.objects.count(),
        WeeklyAvailability.objects.count(),
    )
    call_command("seed_demo")
    assert counts == (
        Specialty.objects.count(),
        DoctorProfile.objects.count(),
        WeeklyAvailability.objects.count(),
    )
    for email in ("dr.karim@medapp.local", "dr.sarah@medapp.local"):
        profile = User.objects.get(email=email).doctor_profile
        assert profile.availabilities.exists()
