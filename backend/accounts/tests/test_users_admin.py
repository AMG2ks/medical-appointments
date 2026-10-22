import pytest

from accounts.models import User
from conftest import PASSWORD

LIST = "/api/v1/users/"


@pytest.mark.django_db
@pytest.mark.parametrize("who", ["patient", "doctor"])
def test_non_admin_is_403(auth_client, request, who):
    client = auth_client(request.getfixturevalue(who))
    response = client.get(LIST)
    assert response.status_code == 403
    assert response.data["error"]["code"] == "permission_denied"
    assert client.patch(f"{LIST}1/", {"is_active": False}).status_code == 403


@pytest.mark.django_db
def test_anonymous_is_401(api_client):
    assert api_client.get(LIST).status_code == 401


@pytest.mark.django_db
def test_list_is_paginated_with_filters_and_search(auth_client, admin_user, patient, doctor):
    client = auth_client(admin_user)
    response = client.get(LIST)
    assert response.data["count"] == 3
    assert set(response.data) == {"count", "next", "previous", "results"}

    assert client.get(LIST, {"role": "doctor"}).data["count"] == 1
    assert client.get(LIST, {"search": "PATIENT@"}).data["results"][0]["id"] == patient.id
    patient.is_active = False
    patient.save()
    assert client.get(LIST, {"is_active": "false"}).data["count"] == 1


@pytest.mark.django_db
def test_detail_and_404(auth_client, admin_user, patient):
    client = auth_client(admin_user)
    assert client.get(f"{LIST}{patient.id}/").data["email"] == patient.email
    response = client.get(f"{LIST}99999/")
    assert response.status_code == 404
    assert response.data["error"]["code"] == "not_found"


@pytest.mark.django_db
def test_deactivation_blocks_token_and_login(api_client, auth_client, admin_user, patient):
    login = {"email": patient.email, "password": PASSWORD}
    tokens = api_client.post("/api/v1/auth/login/", login).data

    response = auth_client(admin_user).patch(
        f"{LIST}{patient.id}/", {"is_active": False}, format="json"
    )
    assert response.status_code == 200
    assert response.data["is_active"] is False

    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access']}")
    assert api_client.get("/api/v1/auth/me/").status_code == 401
    api_client.credentials()
    assert (
        api_client.post("/api/v1/auth/token/refresh/", {"refresh": tokens["refresh"]}).status_code
        == 401
    )
    assert api_client.post("/api/v1/auth/login/", login).status_code == 401


@pytest.mark.django_db
def test_reactivation(auth_client, admin_user, patient):
    patient.is_active = False
    patient.save()
    response = auth_client(admin_user).patch(
        f"{LIST}{patient.id}/", {"is_active": True}, format="json"
    )
    assert response.data["is_active"] is True
    assert User.objects.get(pk=patient.pk).is_active


@pytest.mark.django_db
def test_cannot_deactivate_self(auth_client, admin_user):
    response = auth_client(admin_user).patch(
        f"{LIST}{admin_user.id}/", {"is_active": False}, format="json"
    )
    assert response.status_code == 400
    assert response.data["error"]["code"] == "cannot_deactivate_self"
