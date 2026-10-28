from datetime import UTC, datetime, timedelta

import pytest

from accounts.models import PatientProfile, User
from appointments.models import Appointment
from dashboard import services
from doctors.models import DoctorProfile

STATS = "/api/v1/dashboard/stats/"
# Sunday 2026-11-01 23:30 UTC = Monday 2026-11-02 00:30 in Tunis (UTC+1): after midnight there.
NOW = datetime(2026, 11, 1, 23, 30, tzinfo=UTC)


@pytest.fixture(autouse=True)
def clock(monkeypatch):
    monkeypatch.setattr(services, "_now", lambda: NOW)


@pytest.fixture
def appointments(patient, doctor):
    profile = doctor.doctor_profile

    def make(start, status="confirmed"):
        return Appointment.objects.create(
            patient=patient,
            doctor=profile,
            start_at=start,
            end_at=start + timedelta(minutes=30),
            status=status,
        )

    return make


@pytest.mark.django_db
class TestPermissions:
    def test_anonymous_is_401(self, api_client):
        assert api_client.get(STATS).status_code == 401

    @pytest.mark.parametrize("who", ["patient", "doctor"])
    def test_non_admin_is_403(self, auth_client, request, who):
        response = auth_client(request.getfixturevalue(who)).get(STATS)
        assert response.status_code == 403
        assert response.data["error"]["code"] == "permission_denied"


@pytest.mark.django_db
class TestStats:
    def test_empty_database_has_every_key_at_zero(self, auth_client, admin_user):
        response = auth_client(admin_user).get(STATS)
        assert response.status_code == 200
        assert response.data["appointments"] == {
            "total": 0,
            "today": 0,
            "this_week": 0,
            "by_status": {"confirmed": 0, "cancelled": 0, "completed": 0, "no_show": 0},
        }
        assert response.data["patients"] == {"total": 0, "active": 0}

    def test_users_are_counted_by_role_and_activity(
        self, auth_client, admin_user, patient, doctor, specialty
    ):
        inactive = User.objects.create_user(
            "gone@example.com", "x", role=User.Role.PATIENT, is_active=False
        )
        PatientProfile.objects.create(user=inactive)
        second = User.objects.create_user("d2@example.com", "x", role=User.Role.DOCTOR)
        DoctorProfile.objects.create(user=second, specialty=specialty)
        data = auth_client(admin_user).get(STATS).data
        assert data["patients"] == {"total": 2, "active": 1}
        assert data["doctors"] == {"total": 2, "active": 2}

    def test_today_and_week_follow_the_clinic_time_zone(
        self, auth_client, admin_user, appointments
    ):
        # "Today" is Monday 2 Nov in Tunis, although it is still Sunday in UTC.
        appointments(datetime(2026, 11, 2, 8, 0, tzinfo=UTC))  # Mon 09:00 local: today
        appointments(datetime(2026, 11, 2, 9, 0, tzinfo=UTC), "cancelled")  # today, any status
        appointments(datetime(2026, 11, 8, 22, 30, tzinfo=UTC))  # Sun 8 Nov 23:30 local: week
        appointments(datetime(2026, 11, 8, 23, 30, tzinfo=UTC))  # Mon 9 Nov 00:30 local: next week
        appointments(
            datetime(2026, 11, 1, 22, 30, tzinfo=UTC), "completed"
        )  # Sun 1 Nov 23:30 local
        data = auth_client(admin_user).get(STATS).data["appointments"]
        assert data["today"] == 2
        assert data["this_week"] == 3
        assert data["total"] == 5
        assert data["by_status"] == {
            "confirmed": 3,
            "cancelled": 1,
            "completed": 1,
            "no_show": 0,
        }
