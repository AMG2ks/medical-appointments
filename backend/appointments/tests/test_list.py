from datetime import timedelta

import pytest

from .conftest import APPOINTMENTS, DAY, NOW, at, code


def ids(response):
    return [item["id"] for item in response.data["results"]]


@pytest.fixture
def world(make_appointment, other_patient, other_doctor):
    """Mine (patient + profile): past, upcoming x2, cancelled-in-the-future. Others': 2."""
    mine = {
        "past": make_appointment(NOW - timedelta(days=2), status="completed"),
        "started": make_appointment(NOW - timedelta(hours=1)),  # confirmed, already started
        "soon": make_appointment(at(DAY, 9)),
        "later": make_appointment(at(DAY, 11)),
        "cancelled": make_appointment(at(DAY, 10), status="cancelled"),
    }
    theirs = {
        "other_patient": make_appointment(at(DAY, 9, 30), patient_=other_patient),
        "other_doctor": make_appointment(at(DAY, 9), doctor_=other_doctor),
    }
    return mine, theirs


@pytest.mark.django_db
class TestScoping:
    def test_patient_sees_only_own(self, auth_client, patient, world):
        mine, theirs = world
        response = auth_client(patient).get(APPOINTMENTS)
        assert response.status_code == 200
        assert set(ids(response)) == {a.pk for a in mine.values()} | {theirs["other_doctor"].pk}

    def test_doctor_sees_only_own_agenda(self, auth_client, doctor, world):
        mine, theirs = world
        got = set(ids(auth_client(doctor).get(APPOINTMENTS)))
        assert got == {a.pk for a in mine.values()} | {theirs["other_patient"].pk}

    def test_other_doctor_sees_only_theirs(self, auth_client, other_doctor, world):
        _, theirs = world
        assert ids(auth_client(other_doctor.user).get(APPOINTMENTS)) == [theirs["other_doctor"].pk]

    def test_admin_sees_all(self, auth_client, admin_user, world):
        assert len(ids(auth_client(admin_user).get(APPOINTMENTS))) == 7

    def test_anonymous_is_401(self, api_client):
        assert api_client.get(APPOINTMENTS).status_code == 401
        assert api_client.get(f"{APPOINTMENTS}1/").status_code == 401

    def test_detail_for_participants_and_admin_only(
        self, auth_client, patient, doctor, admin_user, other_patient, other_doctor, world
    ):
        mine, _ = world
        url = f"{APPOINTMENTS}{mine['soon'].pk}/"
        for user in (patient, doctor, admin_user):
            response = auth_client(user).get(url)
            assert response.status_code == 200
            assert response.data["id"] == mine["soon"].pk
            assert response.data["patient"]["email"] == patient.email
        assert auth_client(other_patient).get(url).status_code == 404
        assert auth_client(other_doctor.user).get(url).status_code == 404
        assert auth_client(patient).get(f"{APPOINTMENTS}99999/").status_code == 404

    def test_the_list_does_not_leak_other_patients_data_to_a_patient(
        self, auth_client, patient, world
    ):
        for item in auth_client(patient).get(APPOINTMENTS).data["results"]:
            assert item["patient"]["id"] == patient.pk


@pytest.mark.django_db
class TestFilters:
    def test_upcoming_is_confirmed_and_not_started_earliest_first(
        self, auth_client, patient, world
    ):
        mine, theirs = world
        response = auth_client(patient).get(APPOINTMENTS, {"scope": "upcoming"})
        assert ids(response) == [mine["soon"].pk, theirs["other_doctor"].pk, mine["later"].pk]

    def test_past_is_everything_else_unclosed_first_then_latest_first(
        self, auth_client, patient, world
    ):
        mine, _ = world
        response = auth_client(patient).get(APPOINTMENTS, {"scope": "past"})
        # the started-but-still-confirmed one first (the doctor must close it)
        assert ids(response) == [mine["started"].pk, mine["cancelled"].pk, mine["past"].pk]

    def test_scopes_partition_the_list(self, auth_client, patient, world):
        client = auth_client(patient)
        everything = set(ids(client.get(APPOINTMENTS)))
        up = set(ids(client.get(APPOINTMENTS, {"scope": "upcoming"})))
        past = set(ids(client.get(APPOINTMENTS, {"scope": "past"})))
        assert up | past == everything and not up & past

    def test_status_filter(self, auth_client, patient, world):
        mine, _ = world
        response = auth_client(patient).get(APPOINTMENTS, {"status": "cancelled"})
        assert ids(response) == [mine["cancelled"].pk]
        both = auth_client(patient).get(APPOINTMENTS, {"scope": "past", "status": "confirmed"})
        assert ids(both) == [mine["started"].pk]

    def test_date_filter_uses_the_clinic_day(self, auth_client, doctor, make_appointment):
        late = make_appointment(at(DAY, 23, 30))  # 22:30Z, still DAY in Tunis
        next_day_early = make_appointment(at(DAY + timedelta(days=1), 0, 15))  # 23:15Z of DAY
        client = auth_client(doctor)
        assert ids(client.get(APPOINTMENTS, {"date": DAY.isoformat()})) == [late.pk]
        assert ids(client.get(APPOINTMENTS, {"date": (DAY + timedelta(days=1)).isoformat()})) == [
            next_day_early.pk
        ]

    def test_admin_filters_by_doctor_patient_and_date(
        self, auth_client, admin_user, profile, patient, other_patient, other_doctor, world
    ):
        mine, theirs = world
        client = auth_client(admin_user)
        assert set(ids(client.get(APPOINTMENTS, {"doctor": other_doctor.pk}))) == {
            theirs["other_doctor"].pk
        }
        assert set(ids(client.get(APPOINTMENTS, {"patient": other_patient.pk}))) == {
            theirs["other_patient"].pk
        }
        on_day = ids(client.get(APPOINTMENTS, {"doctor": profile.pk, "date": DAY.isoformat()}))
        assert set(on_day) == {
            mine["soon"].pk,
            mine["later"].pk,
            mine["cancelled"].pk,
            theirs["other_patient"].pk,
        }

    def test_a_patient_cannot_widen_the_scope_with_filters(
        self, auth_client, patient, other_patient, world
    ):
        _, theirs = world
        response = auth_client(patient).get(APPOINTMENTS, {"patient": other_patient.pk})
        assert ids(response) == []

    @pytest.mark.parametrize(
        ("params", "field"),
        [({"scope": "soon"}, "scope"), ({"status": "nope"}, "status"), ({"date": "x"}, "date")],
    )
    def test_invalid_filters_are_400(self, auth_client, patient, params, field):
        response = auth_client(patient).get(APPOINTMENTS, params)
        assert response.status_code == 400
        assert code(response) == "validation_error"
        assert field in response.data["error"]["fields"]


@pytest.mark.django_db
def test_list_is_paginated(auth_client, patient, make_appointment):
    for i in range(25):
        make_appointment(at(DAY, 9) + timedelta(days=i))
    client = auth_client(patient)
    first = client.get(APPOINTMENTS)
    assert first.data["count"] == 25 and len(first.data["results"]) == 20
    assert first.data["next"] is not None and first.data["previous"] is None
    assert len(client.get(APPOINTMENTS, {"page": 2}).data["results"]) == 5
    assert len(client.get(APPOINTMENTS, {"page_size": 100}).data["results"]) == 25


@pytest.mark.django_db
def test_shape_of_a_cancelled_appointment(auth_client, patient, doctor, make_appointment):
    appointment = make_appointment(at(DAY, 9), status="cancelled", reason="Cough")
    appointment.cancelled_by = doctor
    appointment.cancellation_reason = "Away"
    appointment.save()
    body = auth_client(patient).get(f"{APPOINTMENTS}{appointment.pk}/").data
    assert set(body) == {
        "id",
        "patient",
        "doctor",
        "start_at",
        "end_at",
        "status",
        "reason",
        "cancelled_by",
        "cancellation_reason",
        "created_at",
        "updated_at",
    }
    assert body["cancelled_by"] == {"id": doctor.pk, "role": "doctor"}
    assert set(body["doctor"]) == {"id", "first_name", "last_name", "specialty"}
