import pytest

from conftest import PASSWORD

URL = "/api/v1/auth/password/change/"


@pytest.fixture
def logged_in(api_client, patient):
    tokens = api_client.post(
        "/api/v1/auth/login/", {"email": patient.email, "password": PASSWORD}
    ).data
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access']}")
    return tokens


@pytest.mark.django_db
def test_wrong_old_password(api_client, logged_in):
    response = api_client.post(URL, {"old_password": "nope", "new_password": "An0ther-pass!"})
    assert response.status_code == 400
    assert response.data["error"]["fields"]["old_password"][0]["code"] == "invalid"


@pytest.mark.django_db
def test_weak_new_password(api_client, logged_in):
    response = api_client.post(URL, {"old_password": PASSWORD, "new_password": "short"})
    assert response.status_code == 400
    codes = [e["code"] for e in response.data["error"]["fields"]["new_password"]]
    assert "password_too_short" in codes


@pytest.mark.django_db
def test_success_revokes_old_refresh_and_returns_new_pair(api_client, patient, logged_in):
    response = api_client.post(URL, {"old_password": PASSWORD, "new_password": "An0ther-pass!"})
    assert response.status_code == 200

    refresh = "/api/v1/auth/token/refresh/"
    assert api_client.post(refresh, {"refresh": logged_in["refresh"]}).status_code == 401
    assert api_client.post(refresh, {"refresh": response.data["refresh"]}).status_code == 200

    login = {"email": patient.email, "password": "An0ther-pass!"}
    assert api_client.post("/api/v1/auth/login/", login).status_code == 200
    assert (
        api_client.post("/api/v1/auth/login/", {**login, "password": PASSWORD}).status_code == 401
    )


@pytest.mark.django_db
def test_anonymous_is_401(api_client):
    assert api_client.post(URL, {}).status_code == 401
