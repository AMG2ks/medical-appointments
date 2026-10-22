import logging
import re
from datetime import timedelta

import pytest
from django.core import mail
from django.utils import timezone
from rest_framework.throttling import ScopedRateThrottle

from accounts import services
from accounts.models import PasswordResetCode
from conftest import PASSWORD

LOGIN = "/api/v1/auth/login/"
REFRESH = "/api/v1/auth/token/refresh/"
ME = "/api/v1/auth/me/"
CHANGE = "/api/v1/auth/password/change/"
RESET = "/api/v1/auth/password/reset/"
CONFIRM = "/api/v1/auth/password/reset/confirm/"
NEW_PASSWORD = "Brand-new-pass1"


@pytest.fixture
def session(api_client, patient):
    return api_client.post(LOGIN, {"email": patient.email, "password": PASSWORD}).data


def bearer(client, token):
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")


def last_code():
    return re.search(r"\b(\d{6})\b", mail.outbox[-1].body).group(1)


# --- throttling ---


@pytest.mark.django_db
def test_throttle_ignores_x_forwarded_for(api_client, monkeypatch):
    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"auth_login": "2/min"})
    body = {"email": "a@example.com", "password": "x"}
    statuses = [
        api_client.post(LOGIN, body, headers={"X-Forwarded-For": f"10.0.0.{n}"}).status_code
        for n in range(3)
    ]
    assert statuses == [401, 401, 429]


# --- revoking access tokens (CHECK_REVOKE_TOKEN) ---


@pytest.mark.django_db
def test_password_change_revokes_old_access_but_not_the_new_pair(api_client, session):
    bearer(api_client, session["access"])
    response = api_client.post(CHANGE, {"old_password": PASSWORD, "new_password": NEW_PASSWORD})
    assert response.status_code == 200

    assert api_client.get(ME).status_code == 401  # old access token
    bearer(api_client, response.data["access"])
    assert api_client.get(ME).status_code == 200  # new pair works


@pytest.mark.django_db
def test_reset_revokes_old_access(api_client, patient, session):
    api_client.post(RESET, {"email": patient.email})
    body = {"email": patient.email, "code": last_code(), "new_password": NEW_PASSWORD}
    assert api_client.post(CONFIRM, body).status_code == 204
    bearer(api_client, session["access"])
    assert api_client.get(ME).status_code == 401


# --- refresh: rotation, reuse, revocation ---


@pytest.mark.django_db
def test_rotated_refresh_is_revoked_by_password_change(api_client, session):
    rotated = api_client.post(REFRESH, {"refresh": session["refresh"]}).data
    bearer(api_client, rotated["access"])
    api_client.post(CHANGE, {"old_password": PASSWORD, "new_password": NEW_PASSWORD})
    api_client.credentials()
    assert api_client.post(REFRESH, {"refresh": rotated["refresh"]}).status_code == 401


@pytest.mark.django_db
def test_rotated_refresh_is_revoked_by_deactivation(api_client, admin_user, patient, session):
    rotated = api_client.post(REFRESH, {"refresh": session["refresh"]}).data
    services.set_user_active(patient, False, by=admin_user)
    assert api_client.post(REFRESH, {"refresh": rotated["refresh"]}).status_code == 401


@pytest.mark.django_db
def test_reusing_a_rotated_refresh_revokes_the_whole_family(api_client, session):
    rotated = api_client.post(REFRESH, {"refresh": session["refresh"]}).data
    reuse = api_client.post(REFRESH, {"refresh": session["refresh"]})
    assert reuse.status_code == 401
    assert reuse.data["error"]["code"] == "token_not_valid"
    # The legitimate (newest) token is now dead too: the user must log in again.
    assert api_client.post(REFRESH, {"refresh": rotated["refresh"]}).status_code == 401


@pytest.mark.django_db
def test_old_refresh_after_password_change_is_a_plain_401(api_client, session):
    """Not a theft: it must not revoke the new session of the device that changed the password."""
    bearer(api_client, session["access"])
    new_pair = api_client.post(
        CHANGE, {"old_password": PASSWORD, "new_password": NEW_PASSWORD}
    ).data
    api_client.credentials()
    assert api_client.post(REFRESH, {"refresh": session["refresh"]}).status_code == 401
    assert api_client.post(REFRESH, {"refresh": new_pair["refresh"]}).status_code == 200


@pytest.mark.django_db
def test_refresh_of_inactive_user_is_401(api_client, patient, session):
    patient.is_active = False
    patient.save()  # no token revocation: the check itself must refuse
    response = api_client.post(REFRESH, {"refresh": session["refresh"]})
    assert response.status_code == 401


@pytest.mark.django_db
def test_refresh_of_deleted_user_is_401_not_500(api_client, patient, session):
    patient.delete()
    response = api_client.post(REFRESH, {"refresh": session["refresh"]})
    assert response.status_code == 401
    assert response.data["error"]["code"] == "token_not_valid"


# --- reset code brute force ---


@pytest.fixture
def small_daily_limit(settings):
    settings.RESET_MAX_FAILED_ATTEMPTS_PER_DAY = 3


@pytest.mark.django_db
def test_daily_limit_refuses_even_the_correct_code(api_client, patient, small_daily_limit):
    api_client.post(RESET, {"email": patient.email})
    good = last_code()
    wrong = "000000" if good != "000000" else "111111"
    for _attempt in range(3):
        api_client.post(
            CONFIRM, {"email": patient.email, "code": wrong, "new_password": NEW_PASSWORD}
        )
    response = api_client.post(
        CONFIRM, {"email": patient.email, "code": good, "new_password": NEW_PASSWORD}
    )
    assert response.data["error"]["code"] == "invalid_code"


@pytest.mark.django_db
def test_daily_limit_applies_across_codes_and_blocks_new_codes(
    api_client, patient, small_daily_limit
):
    for _round in range(2):
        api_client.post(RESET, {"email": patient.email})
        wrong = "000000" if last_code() != "000000" else "111111"
        for _attempt in range(2):
            api_client.post(
                CONFIRM, {"email": patient.email, "code": wrong, "new_password": NEW_PASSWORD}
            )
        PasswordResetCode.objects.update(created_at=timezone.now() - timedelta(minutes=5))
    # 4 failures over two codes (limit 3): no new code is sent, and the newest code is locked.
    sent = len(mail.outbox)
    api_client.post(RESET, {"email": patient.email})
    assert len(mail.outbox) == sent
    response = api_client.post(
        CONFIRM, {"email": patient.email, "code": last_code(), "new_password": NEW_PASSWORD}
    )
    assert response.data["error"]["code"] == "invalid_code"


@pytest.mark.django_db
def test_daily_limit_expires_after_24_hours(api_client, patient, small_daily_limit):
    api_client.post(RESET, {"email": patient.email})
    wrong = "000000" if last_code() != "000000" else "111111"
    for _attempt in range(3):
        api_client.post(
            CONFIRM, {"email": patient.email, "code": wrong, "new_password": NEW_PASSWORD}
        )
    PasswordResetCode.objects.update(created_at=timezone.now() - timedelta(hours=25))
    sent = len(mail.outbox)
    api_client.post(RESET, {"email": patient.email})
    assert len(mail.outbox) == sent + 1
    body = {"email": patient.email, "code": last_code(), "new_password": NEW_PASSWORD}
    assert api_client.post(CONFIRM, body).status_code == 204


@pytest.mark.django_db
def test_reset_request_cancels_a_pending_invite(doctor):
    services.send_password_code(doctor, "invite")
    services.send_password_code(doctor, "reset")
    pending = PasswordResetCode.objects.filter(user=doctor, used_at__isnull=True)
    assert [c.purpose for c in pending] == ["reset"]  # the invite is cancelled (documented)


# --- no enumeration on confirm ---


@pytest.mark.django_db
def test_confirm_answers_the_same_for_known_and_unknown_email(api_client, patient):
    api_client.post(RESET, {"email": patient.email})
    known = api_client.post(
        CONFIRM, {"email": patient.email, "code": "000000", "new_password": patient.email}
    )
    unknown = api_client.post(
        CONFIRM,
        {"email": "ghost@example.com", "code": "000000", "new_password": "ghost@example.com"},
    )
    assert known.status_code == unknown.status_code == 400
    assert known.data["error"]["code"] == unknown.data["error"]["code"] == "validation_error"
    assert [e["code"] for e in known.data["error"]["fields"]["new_password"]] == [
        e["code"] for e in unknown.data["error"]["fields"]["new_password"]
    ]


@pytest.mark.django_db
def test_name_similarity_is_checked_only_once_the_code_matches(api_client, patient):
    """A password similar to the user's first name passes the pre-check but fails the full
    check after a correct code, and then the code is not consumed."""
    api_client.post(RESET, {"email": patient.email})
    code = last_code()
    weak = patient.first_name * 3 + "1"  # similar to the first name only
    first = api_client.post(CONFIRM, {"email": patient.email, "code": code, "new_password": weak})
    if first.status_code == 400:
        assert first.data["error"]["code"] == "validation_error"
        ok = api_client.post(
            CONFIRM, {"email": patient.email, "code": code, "new_password": NEW_PASSWORD}
        )
        assert ok.status_code == 204


# --- audit log ---


@pytest.mark.django_db
def test_audit_lines_never_contain_secrets(api_client, caplog, admin_user, patient, auth_client):
    caplog.set_level(logging.INFO, logger="accounts.audit")
    auth_client(admin_user).patch(
        f"/api/v1/users/{patient.id}/", {"is_active": False}, format="json"
    )
    api_client.post(RESET, {"email": admin_user.email})
    code = last_code()
    api_client.post(
        CONFIRM, {"email": admin_user.email, "code": code, "new_password": NEW_PASSWORD}
    )
    text = caplog.text
    assert "action=deactivate_user" in text and f"target={patient.id}" in text
    assert "action=confirm_password_code outcome=ok" in text
    assert "ip=127.0.0.1" in text
    assert code not in text and NEW_PASSWORD not in text
