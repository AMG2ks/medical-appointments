"""Names are copied into emails sent to other people: no control characters, no links."""

import pytest

from accounts.models import User

REGISTER = "/api/v1/auth/register/"
ME = "/api/v1/auth/me/"
BAD_NAMES = [
    "Amira\nBcc: x@y.z",
    "Ami\rra",
    "Amira‮evil",  # right-to-left override (Cf)
    "Ami​ra",  # zero-width space (Cf)
    "tab\there",
    "Visit http://evil.example",
    "see HTTPS://evil.example",
    "www.evil.example",
]


def register_body(**extra):
    return {
        "email": "n@example.com",
        "password": "S3cure-pass!x",
        "first_name": "Amira",
        "last_name": "Ben Salah",
        **extra,
    }


@pytest.mark.django_db
class TestRegister:
    @pytest.mark.parametrize("field", ["first_name", "last_name"])
    @pytest.mark.parametrize("bad", BAD_NAMES)
    def test_rejected(self, api_client, field, bad):
        response = api_client.post(REGISTER, register_body(**{field: bad}), format="json")
        assert response.status_code == 400
        assert response.data["error"]["fields"][field][0]["code"] == "invalid"
        assert not User.objects.filter(email="n@example.com").exists()

    def test_whitespace_is_collapsed_and_accents_are_kept(self, api_client):
        body = register_body(first_name="  Jean   Éloïse ", last_name="Ben  Salah")
        assert api_client.post(REGISTER, body, format="json").status_code == 201
        user = User.objects.get(email="n@example.com")
        assert (user.first_name, user.last_name) == ("Jean Éloïse", "Ben Salah")


@pytest.mark.django_db
class TestProfileUpdate:
    @pytest.mark.parametrize("field", ["first_name", "last_name"])
    @pytest.mark.parametrize("bad", BAD_NAMES)
    def test_rejected(self, auth_client, patient, field, bad):
        response = auth_client(patient).patch(ME, {field: bad}, format="json")
        assert response.status_code == 400
        assert response.data["error"]["fields"][field][0]["code"] == "invalid"
        patient.refresh_from_db()
        assert patient.first_name == "Pat"

    def test_collapses_whitespace(self, auth_client, patient):
        response = auth_client(patient).patch(ME, {"first_name": " A   B "}, format="json")
        assert response.status_code == 200
        assert response.data["first_name"] == "A B"
