from datetime import date, time

import pytest
from django.db import IntegrityError, transaction

from appointments.models import Appointment
from doctors.models import TimeOff, WeeklyAvailability

from .conftest import APPOINTMENTS, DAY, at, code


def book(client, profile, start, **extra):
    return client.post(
        APPOINTMENTS,
        {"doctor": profile.pk, "start_at": start.isoformat(), **extra},
        format="json",
    )


@pytest.mark.django_db
class TestBook:
    def test_patient_books_a_free_slot_confirmed_immediately(self, auth_client, patient, profile):
        response = book(auth_client(patient), profile, at(DAY, 10), reason="Checkup")
        assert response.status_code == 201
        body = response.data
        assert body["status"] == "confirmed"
        assert body["reason"] == "Checkup"
        assert body["start_at"] == "2026-11-05T10:00:00+01:00"
        assert body["end_at"] == "2026-11-05T10:30:00+01:00"
        assert body["patient"]["id"] == patient.pk
        assert body["doctor"]["id"] == profile.pk
        assert body["doctor"]["specialty"]["name_en"] == "Cardiology"
        assert "email" not in body["doctor"]
        assert body["cancelled_by"] is None
        stored = Appointment.objects.get(pk=body["id"])
        assert stored.patient_id == patient.pk and stored.doctor_id == profile.pk

    def test_reason_is_optional(self, auth_client, patient, profile):
        assert book(auth_client(patient), profile, at(DAY, 10)).status_code == 201

    def test_start_may_be_sent_in_utc(self, auth_client, patient, profile):
        response = auth_client(patient).post(
            APPOINTMENTS,
            {"doctor": profile.pk, "start_at": "2026-11-05T09:00:00Z"},  # 10:00 in Tunis
            format="json",
        )
        assert response.status_code == 201
        assert response.data["start_at"] == "2026-11-05T10:00:00+01:00"

    def test_taken_slot_is_409_slot_taken(self, auth_client, patient, other_patient, profile):
        assert book(auth_client(other_patient), profile, at(DAY, 10)).status_code == 201
        response = book(auth_client(patient), profile, at(DAY, 10))
        assert response.status_code == 409
        assert code(response) == "slot_taken"
        assert Appointment.objects.count() == 1

    def test_cancelled_slot_can_be_booked_again(self, auth_client, patient, other_patient, profile):
        first = book(auth_client(other_patient), profile, at(DAY, 10))
        Appointment.objects.filter(pk=first.data["id"]).update(status="cancelled")
        assert book(auth_client(patient), profile, at(DAY, 10)).status_code == 201

    def test_overlap_with_a_longer_existing_booking_is_slot_taken(
        self, auth_client, patient, profile, make_appointment
    ):
        make_appointment(at(DAY, 9, 45), minutes=40)  # e.g. booked before the duration changed
        response = book(auth_client(patient), profile, at(DAY, 10))
        assert response.status_code == 409
        assert code(response) == "slot_taken"

    @pytest.mark.parametrize(
        "when",
        [
            "off_grid",  # 10:10 is not a slot start
            "outside_hours",  # 14:00
            "past",
            "too_soon",  # inside the lead time
            "beyond_horizon",
            "day_without_availability",
            "time_off",
        ],
    )
    def test_not_bookable_times_are_400_slot_not_available(
        self, auth_client, patient, profile, settings, when
    ):
        start = {
            "off_grid": at(DAY, 10, 10),
            "outside_hours": at(DAY, 14),
            "past": at(date(2026, 11, 1), 10),
            "too_soon": at(date(2026, 11, 2), 9, 30),  # NOW 07:00 + 180 min lead = 10:00
            "beyond_horizon": at(date(2026, 12, 20), 10),
            "day_without_availability": at(DAY, 10),
            "time_off": at(DAY, 10),
        }[when]
        if when == "too_soon":
            settings.BOOKING_MIN_LEAD_MINUTES = 180
        if when == "day_without_availability":
            WeeklyAvailability.objects.filter(doctor=profile, weekday=DAY.weekday()).delete()
        if when == "time_off":
            TimeOff.objects.create(doctor=profile, start_at=at(DAY, 9), end_at=at(DAY, 11))
        response = book(auth_client(patient), profile, start)
        assert response.status_code == 400
        assert code(response) == "slot_not_available"
        assert Appointment.objects.count() == 0

    def test_first_bookable_instant_after_the_lead_time(self, auth_client, patient, profile):
        # NOW 07:00 + 60 min lead = 08:00; an 08:00 slot exactly at the limit is allowed.
        WeeklyAvailability.objects.filter(doctor=profile, weekday=0).delete()
        WeeklyAvailability.objects.create(
            doctor=profile, weekday=0, start_time=time(8), end_time=time(9)
        )
        response = book(auth_client(patient), profile, at(date(2026, 11, 2), 8))
        assert response.status_code == 201

    @pytest.mark.parametrize("who", ["doctor", "admin_user"])
    def test_only_patients_book(self, auth_client, request, who, profile):
        user = request.getfixturevalue(who)
        assert book(auth_client(user), profile, at(DAY, 10)).status_code == 403

    def test_anonymous_is_401(self, api_client, profile):
        assert book(api_client, profile, at(DAY, 10)).status_code == 401

    def test_validation_errors_carry_codes(self, auth_client, patient, profile):
        client = auth_client(patient)
        empty = client.post(APPOINTMENTS, {}, format="json")
        assert empty.status_code == 400
        assert code(empty) == "validation_error"
        assert empty.data["error"]["fields"]["doctor"][0]["code"] == "required"
        assert empty.data["error"]["fields"]["start_at"][0]["code"] == "required"
        bad = client.post(
            APPOINTMENTS, {"doctor": profile.pk, "start_at": "tomorrow"}, format="json"
        )
        assert bad.data["error"]["fields"]["start_at"][0]["code"] == "invalid"
        long = book(client, profile, at(DAY, 10), reason="x" * 501)
        assert long.data["error"]["fields"]["reason"][0]["code"] == "max_length"

    def test_naive_start_is_read_in_the_clinic_zone(self, auth_client, patient, profile):
        response = auth_client(patient).post(
            APPOINTMENTS, {"doctor": profile.pk, "start_at": "2026-11-05T10:00:00"}, format="json"
        )
        assert response.status_code == 201
        assert response.data["start_at"] == "2026-11-05T10:00:00+01:00"

    @pytest.mark.parametrize("state", ["unknown", "inactive", "pending_invite", "not_a_doctor"])
    def test_hidden_doctors_cannot_be_booked_by_direct_id(
        self, auth_client, patient, doctor, profile, state
    ):
        target = doctor.pk
        if state == "unknown":
            target = 99999
        elif state == "inactive":
            doctor.is_active = False
            doctor.save()
        elif state == "pending_invite":
            doctor.set_unusable_password()
            doctor.save()
        else:
            target = patient.pk
        response = auth_client(patient).post(
            APPOINTMENTS, {"doctor": target, "start_at": at(DAY, 10).isoformat()}, format="json"
        )
        assert response.status_code == 400
        assert code(response) == "validation_error"
        assert response.data["error"]["fields"]["doctor"][0]["code"] == "does_not_exist"
        assert Appointment.objects.count() == 0


@pytest.mark.django_db
class TestConstraints:
    def test_db_rejects_two_confirmed_with_the_same_start(self, make_appointment):
        make_appointment(at(DAY, 10))
        with pytest.raises(IntegrityError), transaction.atomic():
            make_appointment(at(DAY, 10))

    def test_db_allows_same_start_when_one_is_not_confirmed(self, make_appointment):
        make_appointment(at(DAY, 10), status="cancelled")
        make_appointment(at(DAY, 10), status="completed")
        make_appointment(at(DAY, 10))
        assert Appointment.objects.count() == 3

    def test_db_allows_same_start_for_two_doctors(self, make_appointment, other_doctor):
        make_appointment(at(DAY, 10))
        make_appointment(at(DAY, 10), doctor_=other_doctor)

    def test_db_rejects_end_before_start(self, make_appointment):
        with pytest.raises(IntegrityError), transaction.atomic():
            make_appointment(at(DAY, 10), minutes=-5)


@pytest.mark.django_db
def test_error_messages_follow_accept_language(auth_client, patient, profile, make_appointment):
    make_appointment(at(DAY, 10))
    client = auth_client(patient)
    body = {"doctor": profile.pk, "start_at": at(DAY, 10).isoformat()}
    fr = client.post(APPOINTMENTS, body, format="json", headers={"accept-language": "fr"})
    en = client.post(APPOINTMENTS, body, format="json", headers={"accept-language": "en"})
    assert fr.data["error"]["message"] == "Ce créneau est déjà pris."
    assert en.data["error"]["message"] == "This slot is already taken."


@pytest.mark.django_db
def test_a_longer_overlapping_booking_is_slot_taken_by_the_overlap_check(
    auth_client, patient, profile, make_appointment
):
    """Different start instants: only the overlap check (not the unique constraint) refuses."""
    make_appointment(at(DAY, 9, 45), minutes=40, patient_=None)
    response = book(auth_client(patient), profile, at(DAY, 10))
    assert response.status_code == 409
    assert code(response) == "slot_taken"
