"""Creating a time off over confirmed appointments is refused (409 time_off_conflict)."""

import pytest

from doctors.models import TimeOff, WeeklyAvailability

from .conftest import DAY, at, code

TIME_OFF = "/api/v1/doctors/me/time-off/"


def post(client, start, end, reason=""):
    return client.post(
        TIME_OFF,
        {"start_at": start.isoformat(), "end_at": end.isoformat(), "reason": reason},
        format="json",
    )


@pytest.mark.django_db
class TestTimeOffConflict:
    def test_overlapping_a_confirmed_appointment_is_409_with_the_list(
        self, auth_client, doctor, patient, make_appointment
    ):
        first = make_appointment(at(DAY, 10))
        second = make_appointment(at(DAY, 11), reason="x")
        response = post(auth_client(doctor), at(DAY, 9), at(DAY, 12))
        assert response.status_code == 409
        assert code(response) == "time_off_conflict"
        details = response.data["error"]["details"]
        assert details["count"] == 2
        assert details["appointments"] == [
            {
                "id": first.pk,
                "start_at": "2026-11-05T10:00:00+01:00",
                "end_at": "2026-11-05T10:30:00+01:00",
                "patient_name": "Pat Ient",
            },
            {
                "id": second.pk,
                "start_at": "2026-11-05T11:00:00+01:00",
                "end_at": "2026-11-05T11:30:00+01:00",
                "patient_name": "Pat Ient",
            },
        ]
        assert TimeOff.objects.count() == 0

    def test_partial_overlap_counts_touching_does_not(self, auth_client, doctor, make_appointment):
        make_appointment(at(DAY, 10))  # 10:00-10:30
        client = auth_client(doctor)
        assert post(client, at(DAY, 10, 29), at(DAY, 12)).status_code == 409
        assert post(client, at(DAY, 9), at(DAY, 10, 1)).status_code == 409
        assert post(client, at(DAY, 10, 30), at(DAY, 12)).status_code == 201  # starts at its end
        assert post(client, at(DAY, 8), at(DAY, 10)).status_code == 201  # ends at its start

    @pytest.mark.parametrize("status", ["cancelled", "completed", "no_show"])
    def test_only_confirmed_appointments_block(self, auth_client, doctor, make_appointment, status):
        make_appointment(at(DAY, 10), status=status)
        assert post(auth_client(doctor), at(DAY, 9), at(DAY, 12)).status_code == 201

    def test_after_cancelling_the_time_off_can_be_created(
        self, auth_client, doctor, make_appointment
    ):
        appointment = make_appointment(at(DAY, 10))
        client = auth_client(doctor)
        assert post(client, at(DAY, 9), at(DAY, 12)).status_code == 409
        cancel = client.post(
            f"/api/v1/appointments/{appointment.pk}/cancel/", {"reason": "Away"}, format="json"
        )
        assert cancel.status_code == 200
        created = post(client, at(DAY, 9), at(DAY, 12), reason="Conference")
        assert created.status_code == 201
        assert created.data["reason"] == "Conference"

    def test_other_doctors_appointments_do_not_block(
        self, auth_client, doctor, make_appointment, other_doctor
    ):
        make_appointment(at(DAY, 10), doctor_=other_doctor)
        assert post(auth_client(doctor), at(DAY, 9), at(DAY, 12)).status_code == 201

    def test_the_list_is_capped_but_the_count_is_exact(self, auth_client, doctor, patient, profile):
        from datetime import timedelta

        from appointments.models import Appointment

        start = at(DAY, 9)
        Appointment.objects.bulk_create(
            Appointment(
                patient=patient,
                doctor=profile,
                start_at=start + timedelta(days=i),
                end_at=start + timedelta(days=i, minutes=30),
            )
            for i in range(55)
        )
        response = post(auth_client(doctor), start, start + timedelta(days=60))
        assert response.status_code == 409
        assert response.data["error"]["details"]["count"] == 55
        assert len(response.data["error"]["details"]["appointments"]) == 50

    def test_validation_still_comes_first(self, auth_client, doctor):
        response = post(auth_client(doctor), at(DAY, 12), at(DAY, 9))
        assert response.status_code == 400
        assert code(response) == "validation_error"


@pytest.mark.django_db
class TestAvailabilityEditsKeepBookings:
    """Documented decision: editing weekly availability never touches existing bookings."""

    def test_removing_a_window_keeps_the_booking_but_closes_the_slots(
        self, auth_client, doctor, patient, profile, make_appointment
    ):
        appointment = make_appointment(at(DAY, 10))
        window = WeeklyAvailability.objects.get(doctor=profile, weekday=DAY.weekday())
        response = auth_client(doctor).delete(f"/api/v1/doctors/me/availability/{window.pk}/")
        assert response.status_code == 204
        appointment.refresh_from_db()
        assert appointment.status == "confirmed"
        slots = auth_client(patient).get(
            "/api/v1/appointments/slots/", {"doctor": profile.pk, "date": DAY.isoformat()}
        )
        assert slots.data["slots"] == []
        assert (
            auth_client(patient).get(f"/api/v1/appointments/{appointment.pk}/").status_code == 200
        )
