import re
from datetime import timedelta

import pytest
from django.core import mail
from django.utils import timezone

from accounts import services
from accounts.models import PasswordResetCode
from conftest import PASSWORD

REQUEST = "/api/v1/auth/password/reset/"
CONFIRM = "/api/v1/auth/password/reset/confirm/"
NEW_PASSWORD = "Brand-new-pass1"


def last_code():
    return re.search(r"\b(\d{6})\b", mail.outbox[-1].body).group(1)


def confirm(client, email, code, password=NEW_PASSWORD):
    return client.post(CONFIRM, {"email": email, "code": code, "new_password": password})


@pytest.mark.django_db
def test_unknown_email_gets_202_and_no_mail(api_client):
    response = api_client.post(REQUEST, {"email": "ghost@example.com"})
    assert response.status_code == 202
    assert mail.outbox == []


@pytest.mark.django_db
def test_known_email_gets_one_mail(api_client, patient):
    assert api_client.post(REQUEST, {"email": patient.email}).status_code == 202
    assert len(mail.outbox) == 1
    assert mail.outbox[0].to == [patient.email]


@pytest.mark.django_db
def test_second_request_within_60s_sends_nothing(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    assert api_client.post(REQUEST, {"email": patient.email}).status_code == 202
    assert len(mail.outbox) == 1


@pytest.mark.django_db
def test_inactive_user_gets_no_mail(api_client, patient):
    patient.is_active = False
    patient.save()
    assert api_client.post(REQUEST, {"email": patient.email}).status_code == 202
    assert mail.outbox == []


@pytest.mark.django_db
def test_wrong_code_increments_attempts(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    response = confirm(api_client, patient.email, "000000" if last_code() != "000000" else "111111")
    assert response.status_code == 400
    assert response.data["error"]["code"] == "invalid_code"
    assert PasswordResetCode.objects.get(user=patient).attempts == 1


@pytest.mark.django_db
def test_correct_code_is_rejected_after_five_wrong_ones(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    good = last_code()
    wrong = "000000" if good != "000000" else "111111"
    for _attempt in range(5):
        confirm(api_client, patient.email, wrong)
    response = confirm(api_client, patient.email, good)
    assert response.data["error"]["code"] == "invalid_code"


@pytest.mark.django_db
def test_expired_code(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    PasswordResetCode.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
    response = confirm(api_client, patient.email, last_code())
    assert response.data["error"]["code"] == "invalid_code"


@pytest.mark.django_db
def test_unknown_email_confirm_is_invalid_code(api_client):
    response = confirm(api_client, "ghost@example.com", "123456")
    assert response.status_code == 400
    assert response.data["error"]["code"] == "invalid_code"


@pytest.mark.django_db
def test_success_changes_password_once(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    tokens = api_client.post(
        "/api/v1/auth/login/", {"email": patient.email, "password": PASSWORD}
    ).data
    code = last_code()

    assert confirm(api_client, patient.email, code).status_code == 204

    login = {"email": patient.email, "password": NEW_PASSWORD}
    assert api_client.post("/api/v1/auth/login/", login).status_code == 200
    reuse = confirm(api_client, patient.email, code)
    assert reuse.data["error"]["code"] == "invalid_code"
    refresh = api_client.post("/api/v1/auth/token/refresh/", {"refresh": tokens["refresh"]})
    assert refresh.status_code == 401


@pytest.mark.django_db
def test_weak_new_password_does_not_consume_code(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    code = last_code()
    response = confirm(api_client, patient.email, code, password="short")
    assert response.status_code == 400
    assert response.data["error"]["code"] == "validation_error"
    assert response.data["error"]["fields"]["new_password"][0]["code"] == "password_too_short"
    assert confirm(api_client, patient.email, code).status_code == 204


@pytest.mark.django_db
def test_new_request_invalidates_previous_code(api_client, patient):
    api_client.post(REQUEST, {"email": patient.email})
    first = last_code()
    PasswordResetCode.objects.update(created_at=timezone.now() - timedelta(minutes=5))
    api_client.post(REQUEST, {"email": patient.email})
    assert len(mail.outbox) == 2
    if first != last_code():
        assert confirm(api_client, patient.email, first).status_code == 400


@pytest.mark.django_db
def test_invite_code_valid_for_72_hours(api_client, doctor):
    services.send_password_code(doctor, "invite")
    entry = PasswordResetCode.objects.get(user=doctor)
    assert entry.purpose == "invite"
    ttl = entry.expires_at - entry.created_at
    assert timedelta(hours=71, minutes=59) < ttl <= timedelta(hours=72, seconds=5)

    assert confirm(api_client, doctor.email, last_code()).status_code == 204
    doctor.refresh_from_db()
    assert doctor.check_password(NEW_PASSWORD)


@pytest.mark.django_db
def test_reset_request_is_throttled(api_client, patient, monkeypatch):
    from rest_framework.throttling import ScopedRateThrottle

    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"password_reset": "1/hour"})
    assert api_client.post(REQUEST, {"email": patient.email}).status_code == 202
    assert api_client.post(REQUEST, {"email": patient.email}).status_code == 429
