from datetime import timedelta

import pytest
from rest_framework_simplejwt.tokens import AccessToken

from conftest import PASSWORD

REFRESH = "/api/v1/auth/token/refresh/"
LOGOUT = "/api/v1/auth/logout/"


@pytest.fixture
def session(api_client, patient):
    return api_client.post(
        "/api/v1/auth/login/", {"email": patient.email, "password": PASSWORD}
    ).data


@pytest.mark.django_db
def test_refresh_rotates_and_blacklists_old_token(api_client, session):
    response = api_client.post(REFRESH, {"refresh": session["refresh"]})
    assert response.status_code == 200
    assert response.data["refresh"] != session["refresh"]
    assert response.data["access"]

    reused = api_client.post(REFRESH, {"refresh": session["refresh"]})
    assert reused.status_code == 401
    assert reused.data["error"]["code"] == "token_not_valid"
    # Reuse is treated as theft: the newest token of the family is revoked too.
    assert api_client.post(REFRESH, {"refresh": response.data["refresh"]}).status_code == 401


@pytest.mark.django_db
def test_refresh_with_garbage_is_token_not_valid(api_client):
    response = api_client.post(REFRESH, {"refresh": "garbage"})
    assert response.status_code == 401
    assert response.data["error"]["code"] == "token_not_valid"


@pytest.mark.django_db
def test_logout_blacklists_refresh(api_client, session):
    assert api_client.post(LOGOUT, {"refresh": session["refresh"]}).status_code == 204
    assert api_client.post(REFRESH, {"refresh": session["refresh"]}).status_code == 401


@pytest.mark.django_db
def test_logout_twice_is_204(api_client, session):
    assert api_client.post(LOGOUT, {"refresh": session["refresh"]}).status_code == 204
    assert api_client.post(LOGOUT, {"refresh": session["refresh"]}).status_code == 204


@pytest.mark.django_db
def test_logout_malformed_token_is_400(api_client):
    response = api_client.post(LOGOUT, {"refresh": "garbage"})
    assert response.status_code == 400
    assert response.data["error"]["code"] == "validation_error"


@pytest.mark.django_db
def test_expired_access_token_is_token_not_valid(api_client, patient):
    token = AccessToken.for_user(patient)
    token.set_exp(lifetime=timedelta(seconds=-10))
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    response = api_client.get("/api/v1/auth/me/")
    assert response.status_code == 401
    assert response.data["error"]["code"] == "token_not_valid"


@pytest.mark.django_db
def test_garbage_access_token_is_token_not_valid(api_client):
    api_client.credentials(HTTP_AUTHORIZATION="Bearer garbage")
    response = api_client.get("/api/v1/auth/me/")
    assert response.status_code == 401
    assert response.data["error"]["code"] == "token_not_valid"
