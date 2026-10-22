import pytest

from accounts.models import PatientProfile, User

URL = "/api/v1/auth/register/"
VALID = {
    "email": "amira@example.com",
    "password": "S3cure-pass!",
    "first_name": "Amira",
    "last_name": "Ben Salah",
}


def codes(response, field):
    return [e["code"] for e in response.data["error"]["fields"][field]]


@pytest.mark.django_db
def test_register_returns_tokens_and_creates_profile(api_client):
    response = api_client.post(URL, {**VALID, "date_of_birth": "1999-04-02"}, format="json")
    assert response.status_code == 201
    assert response.data["access"] and response.data["refresh"]
    assert response.data["user"]["email"] == "amira@example.com"
    assert response.data["user"]["patient_profile"] == {"date_of_birth": "1999-04-02"}
    user = User.objects.get(email="amira@example.com")
    assert PatientProfile.objects.filter(user=user).exists()


@pytest.mark.django_db
def test_role_in_payload_is_ignored(api_client):
    response = api_client.post(URL, {**VALID, "role": "admin"}, format="json")
    assert response.status_code == 201
    assert response.data["user"]["role"] == "patient"


@pytest.mark.django_db
def test_preferred_language_saved(api_client):
    response = api_client.post(URL, {**VALID, "preferred_language": "en"}, format="json")
    assert response.data["user"]["preferred_language"] == "en"


@pytest.mark.django_db
def test_invalid_preferred_language(api_client):
    response = api_client.post(URL, {**VALID, "preferred_language": "de"}, format="json")
    assert response.status_code == 400
    assert codes(response, "preferred_language") == ["invalid_choice"]


@pytest.mark.django_db
def test_duplicate_email_in_other_case(api_client):
    api_client.post(URL, VALID, format="json")
    response = api_client.post(URL, {**VALID, "email": "AMIRA@example.com"}, format="json")
    assert response.status_code == 400
    assert response.data["error"]["code"] == "validation_error"
    assert response.data["error"]["fields"]["email"][0]["code"] == "unique"


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("password", "code"),
    [("short1!", "password_too_short"), ("12345678901", "password_entirely_numeric")],
)
def test_weak_password(api_client, password, code):
    response = api_client.post(URL, {**VALID, "password": password}, format="json")
    assert response.status_code == 400
    assert code in codes(response, "password")


@pytest.mark.django_db
def test_common_and_similar_password(api_client):
    response = api_client.post(URL, {**VALID, "password": "password123"}, format="json")
    assert "password_too_common" in codes(response, "password")
    response = api_client.post(URL, {**VALID, "password": "amira@example"}, format="json")
    assert "password_too_similar" in codes(response, "password")


@pytest.mark.django_db
def test_missing_names(api_client):
    body = {"email": "a@example.com", "password": "S3cure-pass!"}
    response = api_client.post(URL, body, format="json")
    assert codes(response, "first_name") == ["required"]
    assert codes(response, "last_name") == ["required"]


@pytest.mark.django_db
def test_future_date_of_birth(api_client):
    response = api_client.post(URL, {**VALID, "date_of_birth": "2999-01-01"}, format="json")
    assert codes(response, "date_of_birth") == ["date_in_future"]


@pytest.mark.django_db
def test_invalid_phone(api_client):
    response = api_client.post(URL, {**VALID, "phone": "abc"}, format="json")
    assert codes(response, "phone") == ["invalid"]


@pytest.mark.django_db
def test_stale_authorization_header_does_not_break_public_endpoint(api_client):
    api_client.credentials(HTTP_AUTHORIZATION="Bearer not-a-token")
    assert api_client.post(URL, VALID, format="json").status_code == 201
