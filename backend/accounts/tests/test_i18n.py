import pytest
from django.core import mail

from accounts import services

REGISTER = "/api/v1/auth/register/"


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("language", "subject"), [("en", "Your MedApp code"), ("fr", "Votre code MedApp")]
)
def test_reset_email_follows_preferred_language(patient, language, subject):
    patient.preferred_language = language
    patient.save()
    services.send_password_code(patient, "reset")
    assert mail.outbox[0].subject == subject
    if language == "en":
        assert "password reset code" in mail.outbox[0].body
    else:
        assert "code de réinitialisation" in mail.outbox[0].body


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("language", "subject"), [("en", "Welcome to MedApp"), ("fr", "Bienvenue sur MedApp")]
)
def test_invite_email_follows_preferred_language(doctor, language, subject):
    doctor.preferred_language = language
    doctor.save()
    services.send_password_code(doctor, "invite")
    assert mail.outbox[0].subject == subject


@pytest.mark.django_db
def test_accept_language_changes_message_not_code(api_client):
    en = api_client.post(REGISTER, {}, format="json", headers={"Accept-Language": "en"})
    fr = api_client.post(REGISTER, {}, format="json", headers={"Accept-Language": "fr"})
    assert en.data["error"]["code"] == fr.data["error"]["code"] == "validation_error"
    assert en.data["error"]["message"] != fr.data["error"]["message"]
    en_email = en.data["error"]["fields"]["email"][0]
    fr_email = fr.data["error"]["fields"]["email"][0]
    assert en_email["code"] == fr_email["code"] == "required"
    assert en_email["message"] != fr_email["message"]
