"""Business rules of Auth as plain functions. Views stay thin and call these.

Other modules use: create_user, send_password_code, revoke_all_refresh_tokens.
"""

import logging
import secrets
from datetime import timedelta
from functools import cache

from django.conf import settings
from django.contrib.auth.hashers import check_password, make_password
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.core.mail import send_mail
from django.db import transaction
from django.db.models import Sum
from django.template.loader import render_to_string
from django.utils import timezone, translation
from django.utils.translation import gettext as _
from rest_framework.exceptions import ErrorDetail, ValidationError
from rest_framework.fields import get_error_detail
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken
from rest_framework_simplejwt.tokens import RefreshToken

from core.exceptions import BusinessError

from .models import PasswordResetCode, PatientProfile, User

RESEND_COOLDOWN_SECONDS = 60
FAILED_ATTEMPTS_WINDOW = timedelta(hours=24)

audit = logging.getLogger("accounts.audit")


def _audit(action: str, *, actor, target, ip: str | None, outcome: str = "ok") -> None:
    """One structured line per sensitive action. Ids only: never passwords, codes or tokens."""
    audit.info(
        "action=%s outcome=%s actor=%s target=%s ip=%s", action, outcome, actor, target, ip or "-"
    )


def create_user(
    *,
    email: str,
    first_name: str,
    last_name: str,
    role: str,
    phone: str = "",
    preferred_language: str | None = None,
    password: str | None = None,
) -> User:
    """No password means an unusable one (invited doctors set it with a code)."""
    extra = {"first_name": first_name, "last_name": last_name, "role": role, "phone": phone}
    if preferred_language:
        extra["preferred_language"] = preferred_language
    return User.objects.create_user(email, password, **extra)


def register_patient(*, data: dict) -> User:
    """`data` is already validated (RegisterSerializer)."""
    with transaction.atomic():
        user = create_user(
            email=data["email"],
            first_name=data["first_name"],
            last_name=data["last_name"],
            role=User.Role.PATIENT,
            phone=data.get("phone", ""),
            preferred_language=data.get("preferred_language"),
            password=data["password"],
        )
        PatientProfile.objects.create(user=user, date_of_birth=data.get("date_of_birth"))
    return user


def issue_tokens(user: User) -> dict[str, str]:
    refresh = RefreshToken.for_user(user)
    return {"access": str(refresh.access_token), "refresh": str(refresh)}


def revoke_all_refresh_tokens(user: User) -> None:
    for token in OutstandingToken.objects.filter(user=user):
        BlacklistedToken.objects.get_or_create(token=token)


def _validate_new_password(password: str, user: User | None) -> None:
    """Django's validators; their error codes (password_too_short, ...) are kept."""
    try:
        validate_password(password, user)
    except DjangoValidationError as exc:
        raise ValidationError({"new_password": get_error_detail(exc)}) from exc


def change_password(user: User, old: str, new: str, *, ip: str | None = None) -> dict[str, str]:
    """Returns a fresh token pair; every other session is logged out."""
    if not user.check_password(old):
        _audit("change_password", actor=user.pk, target=user.pk, ip=ip, outcome="wrong_password")
        raise ValidationError(
            {"old_password": [ErrorDetail(_("The current password is wrong."), code="invalid")]}
        )
    _validate_new_password(new, user)
    user.set_password(new)
    user.save(update_fields=["password"])
    revoke_all_refresh_tokens(user)
    _audit("change_password", actor=user.pk, target=user.pk, ip=ip)
    return issue_tokens(user)


def set_user_active(user: User, is_active: bool, *, by: User, ip: str | None = None) -> User:
    action = "activate_user" if is_active else "deactivate_user"
    if not is_active and user.pk == by.pk:
        _audit(action, actor=by.pk, target=user.pk, ip=ip, outcome="refused_self")
        raise BusinessError("cannot_deactivate_self", _("You cannot deactivate your own account."))
    user.is_active = is_active
    user.save(update_fields=["is_active"])
    if not is_active:
        revoke_all_refresh_tokens(user)
    _audit(action, actor=by.pk, target=user.pk, ip=ip)
    return user


# --- password codes (reset + doctor invite) ---


def _active_user_by_email(email: str) -> User | None:
    return User.objects.filter(email__iexact=email, is_active=True).first()


@cache
def _dummy_hash() -> str:
    return make_password("not-a-real-code")


def _failed_attempts_last_day(user: User) -> int:
    """Wrong codes typed for this account in the last 24 h, over all its codes."""
    since = timezone.now() - FAILED_ATTEMPTS_WINDOW
    total = PasswordResetCode.objects.filter(user=user, created_at__gte=since).aggregate(
        total=Sum("attempts")
    )["total"]
    return total or 0


def send_password_code(user: User, purpose: str) -> None:
    """Create a one-time code and email it in the user's language.

    purpose: "reset" or "invite". Older unused codes of the user stop working, so a reset
    request also cancels a doctor's pending invite (the doctor can request a new code).
    The clear code only exists in the email: never log it.

    Sending is not rolled back with the database. A caller inside a transaction (M2: create
    doctor) must call this with `transaction.on_commit(lambda: send_password_code(...))`,
    otherwise a rollback leaves a code mailed for an account that does not exist.
    """
    now = timezone.now()
    if purpose == PasswordResetCode.Purpose.INVITE:
        ttl = timedelta(hours=settings.PASSWORD_INVITE_CODE_TTL_HOURS)
    else:
        ttl = timedelta(minutes=settings.PASSWORD_RESET_CODE_TTL_MINUTES)

    code = f"{secrets.randbelow(10**6):06d}"
    with transaction.atomic():
        PasswordResetCode.objects.filter(user=user, used_at__isnull=True).update(used_at=now)
        PasswordResetCode.objects.create(
            user=user, purpose=purpose, code_hash=make_password(code), expires_at=now + ttl
        )

    with translation.override(user.preferred_language):
        if purpose == PasswordResetCode.Purpose.INVITE:
            subject = _("Welcome to MedApp")
        else:
            subject = _("Your MedApp code")
        body = render_to_string(
            f"accounts/email/password_code_{purpose}.txt",
            {
                "user": user,
                "code": code,
                "minutes": settings.PASSWORD_RESET_CODE_TTL_MINUTES,
                "hours": settings.PASSWORD_INVITE_CODE_TTL_HOURS,
            },
        )
        send_mail(subject, body, None, [user.email])


def request_password_reset(email: str) -> None:
    """Does nothing for unknown/inactive emails, if a code was sent < 60 s ago, or if the
    account hit its daily limit of failed codes. The caller answers the same way in every
    case (no account enumeration)."""
    user = _active_user_by_email(email)
    if user is None:
        return
    since = timezone.now() - timedelta(seconds=RESEND_COOLDOWN_SECONDS)
    if PasswordResetCode.objects.filter(user=user, created_at__gt=since).exists():
        return
    if _failed_attempts_last_day(user) >= settings.RESET_MAX_FAILED_ATTEMPTS_PER_DAY:
        return
    send_password_code(user, PasswordResetCode.Purpose.RESET)


def confirm_password_code(
    *, email: str, code: str, new_password: str, ip: str | None = None
) -> None:
    """Set a new password with a valid code. Any failure of the code raises the same
    `invalid_code` error (unknown email, wrong, expired, used, too many attempts, daily
    limit reached)."""
    user = _active_user_by_email(email)
    # Same check for known and unknown emails (no names, no enumeration). A weak password
    # is reported before touching the code, so the code is not consumed.
    _validate_new_password(new_password, User(email=email))

    accepted = False
    with transaction.atomic():
        entry = None
        locked = True
        if user is not None:
            entry = (
                PasswordResetCode.objects.select_for_update()
                .filter(user=user, used_at__isnull=True)
                .order_by("-created_at")
                .first()
            )
            locked = _failed_attempts_last_day(user) >= settings.RESET_MAX_FAILED_ATTEMPTS_PER_DAY
        usable = (
            entry is not None
            and not locked
            and not entry.is_expired()
            and entry.attempts < settings.PASSWORD_CODE_MAX_ATTEMPTS
        )
        if not usable:
            check_password(code, _dummy_hash())  # same work as a real check (timing)
        elif check_password(code, entry.code_hash):
            # Full check with the user's names; raising here rolls back, code not consumed.
            _validate_new_password(new_password, user)
            accepted = True
            entry.used_at = timezone.now()
            entry.save(update_fields=["used_at"])
            user.set_password(new_password)
            user.save(update_fields=["password"])
            revoke_all_refresh_tokens(user)
        else:
            entry.attempts += 1  # committed, because we raise only after the block
            entry.save(update_fields=["attempts"])
    target = user.pk if user else None
    _audit(
        "confirm_password_code",
        actor=target,
        target=target,
        ip=ip,
        outcome="ok" if accepted else "invalid_code",
    )
    if not accepted:
        raise BusinessError("invalid_code", _("Invalid or expired code."))
