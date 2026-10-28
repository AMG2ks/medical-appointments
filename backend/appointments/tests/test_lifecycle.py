from datetime import timedelta

import pytest

from appointments.models import Appointment

from .conftest import APPOINTMENTS, DAY, NOW, at, code

CONFIRMED = Appointment.Status.CONFIRMED
FINISHED = ["cancelled", "completed", "no_show"]


def url(appointment, action):
    return f"{APPOINTMENTS}{appointment.pk}/{action}/"


@pytest.fixture
def future(make_appointment):
    return make_appointment(at(DAY, 10))  # 3 days ahead: before the cancellation cutoff


@pytest.fixture
def started(make_appointment):
    return make_appointment(NOW - timedelta(minutes=10))


@pytest.mark.django_db
class TestCancelByPatient:
    def test_before_the_cutoff(self, auth_client, patient, future):
        response = auth_client(patient).post(
            url(future, "cancel"), {"reason": "Sick"}, format="json"
        )
        assert response.status_code == 200
        assert response.data["status"] == "cancelled"
        assert response.data["cancellation_reason"] == "Sick"
        assert response.data["cancelled_by"] == {"id": patient.pk, "role": "patient"}
        future.refresh_from_db()
        assert future.status == "cancelled" and future.cancelled_by_id == patient.pk

    def test_reason_is_optional_for_the_patient(self, auth_client, patient, future):
        assert auth_client(patient).post(url(future, "cancel")).status_code == 200

    def test_exactly_at_the_cutoff_is_allowed_one_second_later_is_too_late(
        self, auth_client, patient, make_appointment
    ):
        client = auth_client(patient)
        ok = make_appointment(NOW + timedelta(hours=24))
        assert client.post(url(ok, "cancel")).status_code == 200
        late = make_appointment(NOW + timedelta(hours=24) - timedelta(seconds=1))
        response = client.post(url(late, "cancel"))
        assert response.status_code == 400
        assert code(response) == "cancellation_too_late"
        late.refresh_from_db()
        assert late.status == CONFIRMED

    def test_cutoff_follows_the_setting(self, auth_client, patient, future, settings):
        settings.CANCELLATION_MIN_HOURS = 100  # the appointment is ~75 h away
        response = auth_client(patient).post(url(future, "cancel"))
        assert code(response) == "cancellation_too_late"

    def test_after_the_start_is_too_late(self, auth_client, patient, started):
        assert code(auth_client(patient).post(url(started, "cancel"))) == "cancellation_too_late"

    def test_someone_elses_appointment_is_404(self, auth_client, other_patient, future):
        assert auth_client(other_patient).post(url(future, "cancel")).status_code == 404

    def test_anonymous_is_401(self, api_client, future):
        assert api_client.post(url(future, "cancel")).status_code == 401

    def test_long_reason_is_rejected(self, auth_client, patient, future):
        response = auth_client(patient).post(
            url(future, "cancel"), {"reason": "x" * 501}, format="json"
        )
        assert response.status_code == 400
        assert response.data["error"]["fields"]["reason"][0]["code"] == "max_length"


@pytest.mark.django_db
class TestCancelByDoctorOrAdmin:
    @pytest.mark.parametrize("who", ["doctor", "admin_user"])
    def test_with_a_reason_until_the_start(self, auth_client, request, who, make_appointment):
        user = request.getfixturevalue(who)
        soon = make_appointment(NOW + timedelta(hours=2))  # inside the patient's cutoff
        response = auth_client(user).post(
            url(soon, "cancel"), {"reason": "Emergency"}, format="json"
        )
        assert response.status_code == 200
        assert response.data["cancelled_by"] == {"id": user.pk, "role": user.role}
        assert response.data["cancellation_reason"] == "Emergency"

    @pytest.mark.parametrize("who", ["doctor", "admin_user"])
    def test_reason_is_required(self, auth_client, request, who, future):
        client = auth_client(request.getfixturevalue(who))
        for body in ({}, {"reason": "   "}):
            response = client.post(url(future, "cancel"), body, format="json")
            assert response.status_code == 400
            assert code(response) == "validation_error"
            assert response.data["error"]["fields"]["reason"][0]["code"] == "blank"
        future.refresh_from_db()
        assert future.status == CONFIRMED

    @pytest.mark.parametrize("who", ["doctor", "admin_user"])
    def test_once_started_it_is_an_invalid_transition(self, auth_client, request, who, started):
        response = auth_client(request.getfixturevalue(who)).post(
            url(started, "cancel"), {"reason": "x"}, format="json"
        )
        assert response.status_code == 409
        assert code(response) == "invalid_status_transition"

    def test_another_doctor_gets_404(self, auth_client, other_doctor, future):
        assert (
            auth_client(other_doctor.user)
            .post(url(future, "cancel"), {"reason": "x"}, format="json")
            .status_code
            == 404
        )


@pytest.mark.django_db
class TestStateMatrix:
    """confirmed -> cancelled | completed | no_show, and nothing else."""

    @pytest.mark.parametrize("final", FINISHED)
    @pytest.mark.parametrize("action", ["cancel", "complete", "no-show"])
    def test_a_finished_appointment_never_changes(
        self, auth_client, patient, doctor, make_appointment, final, action
    ):
        appointment = make_appointment(NOW - timedelta(days=1), status=final)
        user = patient if action == "cancel" else doctor
        response = auth_client(user).post(url(appointment, action), {"reason": "x"}, format="json")
        assert response.status_code == 409
        assert code(response) == "invalid_status_transition"
        appointment.refresh_from_db()
        assert appointment.status == final

    @pytest.mark.parametrize(
        ("action", "final"), [("complete", "completed"), ("no-show", "no_show")]
    )
    def test_doctor_closes_a_started_appointment(self, auth_client, doctor, started, action, final):
        response = auth_client(doctor).post(url(started, action))
        assert response.status_code == 200
        assert response.data["status"] == final
        started.refresh_from_db()
        assert started.status == final

    def test_it_is_allowed_exactly_at_the_start(self, auth_client, doctor, make_appointment):
        at_start = make_appointment(NOW)
        assert auth_client(doctor).post(url(at_start, "complete")).status_code == 200

    @pytest.mark.parametrize("action", ["complete", "no-show"])
    def test_not_before_the_start(self, auth_client, doctor, future, action):
        response = auth_client(doctor).post(url(future, action))
        assert response.status_code == 409
        assert code(response) == "invalid_status_transition"

    @pytest.mark.parametrize("action", ["complete", "no-show"])
    def test_permissions(
        self, api_client, auth_client, patient, admin_user, other_doctor, started, action
    ):
        assert api_client.post(url(started, action)).status_code == 401
        assert auth_client(patient).post(url(started, action)).status_code == 403
        assert auth_client(admin_user).post(url(started, action)).status_code == 403
        assert auth_client(other_doctor.user).post(url(started, action)).status_code == 404
        started.refresh_from_db()
        assert started.status == CONFIRMED

    def test_unknown_appointment_is_404(self, auth_client, doctor, profile):
        assert auth_client(doctor).post(f"{APPOINTMENTS}99999/complete/").status_code == 404
