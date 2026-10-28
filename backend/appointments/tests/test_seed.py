import pytest
from django.core.management import call_command

from accounts.models import User
from appointments.models import Appointment


@pytest.mark.django_db
def test_seed_creates_past_and_upcoming_demo_appointments_once(settings):
    settings.SEED_DEMO_PASSWORD = "Demo-Pass-2026!x"
    call_command("seed_demo")
    amira = User.objects.get(email="amira@medapp.local")
    appointments = Appointment.objects.filter(patient=amira)
    assert appointments.count() == 5
    statuses = set(appointments.values_list("status", flat=True))
    assert statuses == {"confirmed", "completed", "cancelled", "no_show"}
    assert {a.doctor.user.email for a in appointments} == {
        "dr.karim@medapp.local",
        "dr.sarah@medapp.local",
    }
    cancelled = appointments.get(status="cancelled")
    assert cancelled.cancelled_by_id == amira.pk
    call_command("seed_demo")
    assert Appointment.objects.count() == 5
