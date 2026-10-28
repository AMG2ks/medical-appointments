import re
import unicodedata

from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import serializers
from rest_framework.exceptions import AuthenticationFailed
from rest_framework_simplejwt.exceptions import InvalidToken, TokenBackendError
from rest_framework_simplejwt.serializers import (
    TokenObtainPairSerializer,
    TokenRefreshSerializer,
)
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.state import token_backend
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken
from rest_framework_simplejwt.utils import get_md5_hash_password

from . import services
from .models import PatientProfile, User, phone_validator

URL_LIKE = re.compile(r"(https?://|www\.)", re.IGNORECASE)


def clean_person_name(value: str) -> str:
    """Names end up in emails sent to other people: refuse control / format characters
    (line breaks, bidi overrides, zero-width...) and link-like text, collapse whitespace."""
    if any(unicodedata.category(ch) in ("Cc", "Cf") for ch in value) or URL_LIKE.search(value):
        raise serializers.ValidationError(_("Enter a valid name."), code="invalid")
    return " ".join(value.split())


class CleanNamesMixin:
    def validate_first_name(self, value):
        return clean_person_name(value)

    def validate_last_name(self, value):
        return clean_person_name(value)


def _not_in_future(value):
    if value and value > timezone.localdate():
        raise serializers.ValidationError(
            _("The date of birth cannot be in the future."), code="date_in_future"
        )
    return value


class PatientProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = PatientProfile
        fields = ["date_of_birth"]

    def validate_date_of_birth(self, value):
        return _not_in_future(value)


class UserSerializer(CleanNamesMixin, serializers.ModelSerializer):
    """`UserOut` of the API. Also used by PATCH auth/me/ (only the writable fields count)."""

    patient_profile = PatientProfileSerializer(required=False)  # null for doctors and admins

    class Meta:
        model = User
        fields = [
            "id",
            "email",
            "first_name",
            "last_name",
            "phone",
            "role",
            "preferred_language",
            "is_active",
            "date_joined",
            "patient_profile",
        ]
        read_only_fields = ["id", "email", "role", "is_active", "date_joined"]
        extra_kwargs = {
            "first_name": {"allow_blank": False},
            "last_name": {"allow_blank": False},
        }

    def validate_patient_profile(self, value):
        if self.instance is not None and self.instance.role != User.Role.PATIENT:
            raise serializers.ValidationError(_("Only patients have this profile."), code="invalid")
        return value

    def update(self, instance, validated_data):
        profile_data = validated_data.pop("patient_profile", None)
        instance = super().update(instance, validated_data)
        if profile_data is not None:
            try:
                profile = instance.patient_profile
            except PatientProfile.DoesNotExist:
                profile = PatientProfile(user=instance)
            for field, value in profile_data.items():
                setattr(profile, field, value)
            profile.save()
        return instance


class UserSummarySerializer(serializers.ModelSerializer):
    """Small user card for other modules to embed (a patient or a doctor)."""

    class Meta:
        model = User
        fields = ["id", "first_name", "last_name", "email", "phone"]
        read_only_fields = fields


class RegisterSerializer(CleanNamesMixin, serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(write_only=True, trim_whitespace=False)
    first_name = serializers.CharField(max_length=150)
    last_name = serializers.CharField(max_length=150)
    phone = serializers.CharField(
        max_length=20, required=False, allow_blank=True, validators=[phone_validator]
    )
    date_of_birth = serializers.DateField(required=False, allow_null=True)
    preferred_language = serializers.ChoiceField(choices=User.Language.choices, required=False)
    # Any `role` sent by the client is ignored: this endpoint only creates patients.

    def validate_email(self, value):
        value = value.lower()
        if User.objects.filter(email__iexact=value).exists():
            raise serializers.ValidationError(
                _("A user with this email already exists."), code="unique"
            )
        return value

    def validate_date_of_birth(self, value):
        return _not_in_future(value)

    def validate(self, attrs):
        candidate = User(
            email=attrs["email"], first_name=attrs["first_name"], last_name=attrs["last_name"]
        )
        try:
            validate_password(attrs["password"], candidate)
        except DjangoValidationError as exc:
            # DRF turns this into {"password": [{code, message}]} and keeps the codes.
            raise DjangoValidationError({"password": exc}) from exc
        return attrs


class LoginSerializer(TokenObtainPairSerializer):
    """Login with email + password; the answer also carries the user."""

    def validate(self, attrs):
        try:
            data = super().validate(attrs)
        except AuthenticationFailed as exc:
            # Same code and message for unknown email, wrong password, inactive account.
            raise AuthenticationFailed(
                _("Invalid email or password."), code="authentication_failed"
            ) from exc
        data["user"] = UserSerializer(self.user).data
        return data


class RefreshSerializer(TokenRefreshSerializer):
    """Refresh with rotation, plus two protections:
    - a rotated or logged-out refresh token that is presented again is a sign of theft: every
      refresh token of that user is revoked, and the answer is 401 (tokens killed by a
      password change are told apart by their password-hash claim: plain 401);
    - a deleted or inactive user gets 401 (not a 500).
    """

    def validate(self, attrs):
        try:
            payload = token_backend.decode(attrs["refresh"])
        except TokenBackendError:
            payload = None  # malformed / expired / bad signature: the parent raises the 401
        if payload is not None:
            user = User.objects.filter(pk=payload.get(api_settings.USER_ID_CLAIM)).first()
            if user is None or not user.is_active:
                raise InvalidToken(_("Token is not valid for this user."))
            jti = payload.get(api_settings.JTI_CLAIM)
            if BlacklistedToken.objects.filter(token__jti=jti).exists():
                if payload.get(api_settings.REVOKE_TOKEN_CLAIM) != get_md5_hash_password(
                    user.password
                ):
                    # Revoked by a password change/reset (the token predates the new
                    # password): an old session, not a theft. Plain 401.
                    raise InvalidToken(_("Token is blacklisted"))
                services.revoke_all_refresh_tokens(user)
                services.audit.warning("refresh token reuse: all tokens revoked target=%s", user.pk)
                raise InvalidToken(_("Token is blacklisted"))
        return super().validate(attrs)


class RefreshTokenSerializer(serializers.Serializer):
    """Body of logout: {"refresh": "..."}. Rejects only malformed tokens."""

    refresh = serializers.CharField()

    def validate_refresh(self, value):
        try:
            token_backend.decode(value, verify=False)  # structure only; the view checks the rest
        except TokenBackendError as exc:
            raise serializers.ValidationError(_("Malformed token."), code="invalid") from exc
        return value


class TokenPairSerializer(serializers.Serializer):
    """Documentation only: shape of refresh / change-password answers."""

    access = serializers.CharField()
    refresh = serializers.CharField()


class AuthResponseSerializer(TokenPairSerializer):
    """Documentation only: shape of register / login answers."""

    user = UserSerializer()


class ChangePasswordSerializer(serializers.Serializer):
    old_password = serializers.CharField(write_only=True, trim_whitespace=False)
    new_password = serializers.CharField(write_only=True, trim_whitespace=False)


class PasswordResetRequestSerializer(serializers.Serializer):
    email = serializers.EmailField()


class PasswordResetConfirmSerializer(serializers.Serializer):
    email = serializers.EmailField()
    code = serializers.CharField(max_length=6)
    new_password = serializers.CharField(write_only=True, trim_whitespace=False)


class UserActiveSerializer(serializers.Serializer):
    """Admin PATCH users/{id}/: only is_active is editable."""

    is_active = serializers.BooleanField()
