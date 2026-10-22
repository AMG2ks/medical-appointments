import pytest
from rest_framework.throttling import ScopedRateThrottle

from conftest import PASSWORD

URL = "/api/v1/auth/login/"


@pytest.mark.django_db
def test_login_returns_tokens_and_user(api_client, patient):
    response = api_client.post(URL, {"email": "PATIENT@example.com", "password": PASSWORD})
    assert response.status_code == 200
    assert response.data["access"] and response.data["refresh"]
    assert response.data["user"]["id"] == patient.id
    assert response.data["user"]["patient_profile"] == {"date_of_birth": None}


@pytest.mark.django_db
def test_all_failures_look_the_same(api_client, patient):
    wrong_password = api_client.post(URL, {"email": patient.email, "password": "nope"})
    unknown_email = api_client.post(URL, {"email": "ghost@example.com", "password": PASSWORD})
    patient.is_active = False
    patient.save()
    inactive = api_client.post(URL, {"email": patient.email, "password": PASSWORD})

    for response in (wrong_password, unknown_email, inactive):
        assert response.status_code == 401
        assert response.data["error"]["code"] == "authentication_failed"
    assert wrong_password.data == unknown_email.data == inactive.data


@pytest.mark.django_db
def test_login_is_throttled(api_client, patient, monkeypatch):
    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"auth_login": "2/min"})
    body = {"email": patient.email, "password": "nope"}
    assert api_client.post(URL, body).status_code == 401
    assert api_client.post(URL, body).status_code == 401
    response = api_client.post(URL, body)
    assert response.status_code == 429
    assert response.data["error"]["code"] == "throttled"
