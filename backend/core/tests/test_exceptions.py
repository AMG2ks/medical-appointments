import pytest
from rest_framework.throttling import ScopedRateThrottle

from core.exceptions import BusinessError, api_exception_handler


def error_of(response):
    error = response.data["error"]
    assert set(error) == {"code", "message", "fields"}
    return error


@pytest.mark.django_db
def test_validation_error_shape(api_client):
    response = api_client.post("/api/v1/auth/register/", {}, format="json")
    error = error_of(response)
    assert response.status_code == 400
    assert error["code"] == "validation_error"
    assert error["fields"]["email"] == [
        {"message": error["fields"]["email"][0]["message"], "code": "required"}
    ]


@pytest.mark.django_db
def test_401_shape(api_client):
    response = api_client.get("/api/v1/auth/me/")
    assert response.status_code == 401
    assert error_of(response)["code"] == "not_authenticated"
    assert error_of(response)["fields"] == {}


@pytest.mark.django_db
def test_403_shape(auth_client, patient):
    response = auth_client(patient).get("/api/v1/users/")
    assert response.status_code == 403
    assert error_of(response)["code"] == "permission_denied"


@pytest.mark.django_db
def test_404_shape(auth_client, admin_user):
    response = auth_client(admin_user).get("/api/v1/users/99999/")
    assert response.status_code == 404
    assert error_of(response)["code"] == "not_found"


@pytest.mark.django_db
def test_throttled_shape(api_client, monkeypatch):
    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"auth_login": "1/min"})
    body = {"email": "a@example.com", "password": "x"}
    api_client.post("/api/v1/auth/login/", body)
    response = api_client.post("/api/v1/auth/login/", body)
    assert response.status_code == 429
    assert error_of(response)["code"] == "throttled"


@pytest.mark.django_db
def test_parse_error_shape(api_client):
    response = api_client.post("/api/v1/auth/login/", "{not json", content_type="application/json")
    assert response.status_code == 400
    assert error_of(response)["code"] == "parse_error"


def test_business_error_keeps_code_and_status():
    response = api_exception_handler(BusinessError("slot_taken", "Taken.", status_code=409), {})
    assert response.status_code == 409
    assert response.data == {"error": {"code": "slot_taken", "message": "Taken.", "fields": {}}}


def test_unexpected_error_is_left_to_django():
    assert api_exception_handler(RuntimeError("boom"), {}) is None
