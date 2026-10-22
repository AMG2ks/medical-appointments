import pytest

URL = "/api/v1/auth/me/"


@pytest.mark.django_db
def test_anonymous_is_401(api_client):
    response = api_client.get(URL)
    assert response.status_code == 401
    assert response.data["error"]["code"] == "not_authenticated"


@pytest.mark.django_db
def test_get_me(auth_client, patient):
    response = auth_client(patient).get(URL)
    assert response.status_code == 200
    assert response.data["email"] == patient.email


@pytest.mark.django_db
def test_patch_updates_profile_fields(auth_client, patient):
    body = {
        "first_name": "New",
        "last_name": "Name",
        "phone": "+21620123456",
        "preferred_language": "en",
        "patient_profile": {"date_of_birth": "1999-04-02"},
    }
    response = auth_client(patient).patch(URL, body, format="json")
    assert response.status_code == 200
    assert response.data["first_name"] == "New"
    assert response.data["phone"] == "+21620123456"
    assert response.data["preferred_language"] == "en"
    assert response.data["patient_profile"]["date_of_birth"] == "1999-04-02"
    patient.refresh_from_db()
    assert patient.patient_profile.date_of_birth.isoformat() == "1999-04-02"


@pytest.mark.django_db
def test_email_role_and_is_active_are_ignored(auth_client, patient):
    body = {"email": "other@example.com", "role": "admin", "is_active": False, "first_name": "Z"}
    response = auth_client(patient).patch(URL, body, format="json")
    assert response.status_code == 200
    patient.refresh_from_db()
    assert (patient.email, patient.role, patient.is_active) == (
        "patient@example.com",
        "patient",
        True,
    )


@pytest.mark.django_db
def test_doctor_cannot_send_patient_profile(auth_client, doctor):
    body = {"patient_profile": {"date_of_birth": "1999-04-02"}}
    response = auth_client(doctor).patch(URL, body, format="json")
    assert response.status_code == 400
    assert response.data["error"]["fields"]["patient_profile"][0]["code"] == "invalid"


@pytest.mark.django_db
def test_doctor_me_has_no_patient_profile(auth_client, doctor):
    assert auth_client(doctor).get(URL).data["patient_profile"] is None


@pytest.mark.django_db
def test_future_date_of_birth_rejected(auth_client, patient):
    body = {"patient_profile": {"date_of_birth": "2999-01-01"}}
    response = auth_client(patient).patch(URL, body, format="json")
    fields = response.data["error"]["fields"]
    assert fields["patient_profile"]["date_of_birth"][0]["code"] == "date_in_future"


@pytest.mark.django_db
@pytest.mark.parametrize("field", ["first_name", "last_name"])
def test_names_cannot_be_blank(auth_client, patient, field):
    response = auth_client(patient).patch(URL, {field: ""}, format="json")
    assert response.status_code == 400
    assert response.data["error"]["fields"][field][0]["code"] == "blank"
