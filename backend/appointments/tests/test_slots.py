from datetime import UTC, date, datetime, time

import pytest

from appointments import services
from doctors.models import TimeOff, WeeklyAvailability

from .conftest import DAY, SLOTS, at, code


def starts(response):
    return [s["start_at"] for s in response.data["slots"]]


def get(client, profile, day=DAY):
    return client.get(SLOTS, {"doctor": profile.pk, "date": day.isoformat()})


@pytest.mark.django_db
class TestSlotsApi:
    def test_grid_is_cut_into_consultation_length_with_clinic_offset(
        self, auth_client, patient, profile
    ):
        response = get(auth_client(patient), profile)
        assert response.status_code == 200
        assert starts(response) == [
            "2026-11-05T09:00:00+01:00",
            "2026-11-05T09:30:00+01:00",
            "2026-11-05T10:00:00+01:00",
            "2026-11-05T10:30:00+01:00",
            "2026-11-05T11:00:00+01:00",
            "2026-11-05T11:30:00+01:00",
        ]
        assert response.data["slots"][-1]["end_at"] == "2026-11-05T12:00:00+01:00"
        assert response.data["consultation_minutes"] == 30
        assert response.data["doctor"] == profile.pk

    def test_booked_slots_are_removed_and_cancelled_ones_are_not(
        self, auth_client, patient, profile, make_appointment
    ):
        make_appointment(at(DAY, 9, 30))
        make_appointment(at(DAY, 10), status="cancelled")
        make_appointment(at(DAY, 10, 30), status="completed")  # not "confirmed": frees the slot
        got = starts(get(auth_client(patient), profile))
        assert "2026-11-05T09:30:00+01:00" not in got
        assert "2026-11-05T10:00:00+01:00" in got
        assert len(got) == 5  # only the confirmed booking removed a slot

    def test_a_longer_booking_removes_every_overlapped_slot(
        self, auth_client, patient, profile, make_appointment
    ):
        make_appointment(at(DAY, 9, 45), minutes=40)  # 09:45-10:25 touches 09:30, 10:00
        got = starts(get(auth_client(patient), profile))
        assert got == [
            "2026-11-05T09:00:00+01:00",
            "2026-11-05T10:30:00+01:00",
            "2026-11-05T11:00:00+01:00",
            "2026-11-05T11:30:00+01:00",
        ]

    def test_trailing_remainder_shorter_than_a_consultation_is_dropped(
        self, auth_client, patient, profile
    ):
        profile.consultation_minutes = 50
        profile.save()
        got = starts(get(auth_client(patient), profile))
        assert got == [
            "2026-11-05T09:00:00+01:00",
            "2026-11-05T09:50:00+01:00",
            "2026-11-05T10:40:00+01:00",
        ]

    def test_time_off_removes_slots(self, auth_client, patient, profile):
        TimeOff.objects.create(doctor=profile, start_at=at(DAY, 10), end_at=at(DAY, 11))
        got = starts(get(auth_client(patient), profile))
        assert got == [
            "2026-11-05T09:00:00+01:00",
            "2026-11-05T09:30:00+01:00",
            "2026-11-05T11:00:00+01:00",
            "2026-11-05T11:30:00+01:00",
        ]

    def test_day_without_availability_is_empty(self, auth_client, patient, profile):
        WeeklyAvailability.objects.filter(doctor=profile, weekday=DAY.weekday()).delete()
        response = get(auth_client(patient), profile)
        assert response.status_code == 200
        assert response.data["slots"] == []

    def test_lead_time_hides_slots_that_start_too_soon(
        self, auth_client, patient, profile, monkeypatch, settings
    ):
        # 08:30 local + 60 min lead: 09:30 is the first bookable slot of that day.
        monkeypatch.setattr(services, "_now", lambda: at(DAY, 8, 30))
        assert starts(get(auth_client(patient), profile))[0] == "2026-11-05T09:30:00+01:00"
        settings.BOOKING_MIN_LEAD_MINUTES = 0
        assert starts(get(auth_client(patient), profile))[0] == "2026-11-05T09:00:00+01:00"

    def test_past_days_and_days_beyond_the_horizon_are_empty(
        self, auth_client, patient, profile, settings
    ):
        client = auth_client(patient)
        assert get(client, profile, date(2026, 11, 1)).data["slots"] == []
        settings.BOOKING_HORIZON_DAYS = 2
        assert get(client, profile).data["slots"] == []  # day is 3 days away
        settings.BOOKING_HORIZON_DAYS = 3
        assert get(client, profile).data["slots"] != []

    def test_dst_day_is_cut_on_real_elapsed_time(
        self, auth_client, patient, profile, settings, monkeypatch
    ):
        # Paris springs forward on 2026-03-29 (Sunday): 01:00-05:00 local is 3 real hours.
        settings.TIME_ZONE = "Europe/Paris"
        WeeklyAvailability.objects.filter(doctor=profile).delete()
        WeeklyAvailability.objects.create(
            doctor=profile, weekday=6, start_time=time(1), end_time=time(5)
        )
        profile.consultation_minutes = 60
        profile.save()
        monkeypatch.setattr(services, "_now", lambda: datetime(2026, 3, 20, 12, tzinfo=UTC))
        response = get(auth_client(patient), profile, date(2026, 3, 29))
        assert starts(response) == [
            "2026-03-29T01:00:00+01:00",
            "2026-03-29T03:00:00+02:00",
            "2026-03-29T04:00:00+02:00",
        ]

    def test_validation(self, auth_client, patient, profile):
        client = auth_client(patient)
        missing = client.get(SLOTS)
        assert missing.status_code == 400
        assert code(missing) == "validation_error"
        assert {"doctor", "date"} <= set(missing.data["error"]["fields"])
        bad = client.get(SLOTS, {"doctor": profile.pk, "date": "05/11/2026"})
        assert bad.status_code == 400
        assert bad.data["error"]["fields"]["date"][0]["code"] == "invalid"
        assert client.get(SLOTS, {"doctor": "abc", "date": "2026-11-05"}).status_code == 400

    def test_anonymous_is_401_and_any_role_can_read(
        self, api_client, auth_client, patient, doctor, admin_user, profile
    ):
        assert get(api_client, profile).status_code == 401
        for user in (patient, doctor, admin_user):
            assert get(auth_client(user), profile).status_code == 200

    def test_unknown_inactive_pending_and_non_doctor_are_404(
        self, auth_client, patient, doctor, profile
    ):
        client = auth_client(patient)
        assert client.get(SLOTS, {"doctor": 99999, "date": "2026-11-05"}).status_code == 404
        assert client.get(SLOTS, {"doctor": patient.pk, "date": "2026-11-05"}).status_code == 404
        doctor.set_unusable_password()  # invite not accepted yet
        doctor.save()
        assert get(client, profile).status_code == 404
        doctor.set_password("x")
        doctor.is_active = False
        doctor.save()
        assert get(client, profile).status_code == 404

    def test_admin_sees_slots_of_a_pending_doctor(self, auth_client, admin_user, doctor, profile):
        doctor.set_unusable_password()
        doctor.save()
        assert get(auth_client(admin_user), profile).status_code == 200


@pytest.mark.django_db
def test_free_slots_is_pure_utc_arithmetic(profile):
    slots = services.free_slots(profile, DAY)
    assert slots[0][0].utcoffset().total_seconds() == 0
    assert slots[0][0] == at(DAY, 9)
