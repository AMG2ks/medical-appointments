from django.utils.translation import gettext as _
from rest_framework import serializers

from accounts.models import User, phone_validator
from accounts.serializers import CleanNamesMixin
from core.fields import SafeDateTimeField

from .models import (
    BIO_MAX_LENGTH,
    CONSULTATION_MINUTES_MAX,
    CONSULTATION_MINUTES_MIN,
    DoctorProfile,
    Specialty,
    TimeOff,
    WeeklyAvailability,
)

CONSULTATION_RANGE = {
    "min_value": CONSULTATION_MINUTES_MIN,
    "max_value": CONSULTATION_MINUTES_MAX,
}


class SpecialtySerializer(serializers.ModelSerializer):
    class Meta:
        model = Specialty
        fields = ["id", "name_fr", "name_en"]


class DoctorSerializer(serializers.ModelSerializer):
    """Public card of a doctor. `id` is the user id. No email/phone: patients do not need them."""

    id = serializers.IntegerField(source="user_id", read_only=True)
    first_name = serializers.CharField(source="user.first_name", read_only=True)
    last_name = serializers.CharField(source="user.last_name", read_only=True)
    specialty = SpecialtySerializer(read_only=True)
    # True until the doctor sets a password with the invite code. Only admins ever see such
    # doctors (patients get them filtered out), so for everyone else it is always false.
    invite_pending = serializers.SerializerMethodField()

    class Meta:
        model = DoctorProfile
        fields = [
            "id",
            "first_name",
            "last_name",
            "specialty",
            "bio",
            "consultation_minutes",
            "invite_pending",
        ]
        read_only_fields = fields

    def get_invite_pending(self, obj) -> bool:
        return not obj.user.has_usable_password()


class DoctorMeSerializer(DoctorSerializer):
    """The doctor's own profile (GET/PATCH). Only professional fields are writable;
    name, phone and language go through /auth/me/."""

    email = serializers.EmailField(source="user.email", read_only=True)
    phone = serializers.CharField(source="user.phone", read_only=True)
    specialty_id = serializers.PrimaryKeyRelatedField(
        source="specialty", queryset=Specialty.objects.all(), write_only=True, required=False
    )
    consultation_minutes = serializers.IntegerField(**CONSULTATION_RANGE, required=False)

    class Meta:
        model = DoctorProfile
        fields = [
            *DoctorSerializer.Meta.fields,
            "email",
            "phone",
            "specialty_id",
        ]
        read_only_fields = ["id", "first_name", "last_name", "specialty", "email", "phone"]


class CreateDoctorSerializer(CleanNamesMixin, serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    first_name = serializers.CharField(max_length=150)
    last_name = serializers.CharField(max_length=150)
    phone = serializers.CharField(
        max_length=20, required=False, allow_blank=True, validators=[phone_validator]
    )
    preferred_language = serializers.ChoiceField(choices=User.Language.choices, required=False)
    specialty_id = serializers.PrimaryKeyRelatedField(
        source="specialty", queryset=Specialty.objects.all()
    )
    bio = serializers.CharField(required=False, allow_blank=True, max_length=BIO_MAX_LENGTH)
    consultation_minutes = serializers.IntegerField(**CONSULTATION_RANGE, required=False)

    def validate_email(self, value):
        value = value.lower()
        if User.objects.filter(email__iexact=value).exists():
            raise serializers.ValidationError(
                _("A user with this email already exists."), code="unique"
            )
        return value


class WeeklyAvailabilitySerializer(serializers.ModelSerializer):
    weekday = serializers.IntegerField(min_value=0, max_value=6)

    class Meta:
        model = WeeklyAvailability
        fields = ["id", "weekday", "start_time", "end_time"]

    def validate(self, attrs):
        # PATCH may send only one of the two times: compare with the stored value.
        start = attrs.get("start_time", getattr(self.instance, "start_time", None))
        end = attrs.get("end_time", getattr(self.instance, "end_time", None))
        if start is not None and end is not None and start >= end:
            raise serializers.ValidationError(
                {"end_time": [_("The end must be after the start.")]}, code="invalid"
            )
        return attrs


class TimeOffSerializer(serializers.ModelSerializer):
    start_at = SafeDateTimeField()
    end_at = SafeDateTimeField()

    class Meta:
        model = TimeOff
        fields = ["id", "start_at", "end_at", "reason"]

    def validate(self, attrs):
        if attrs["start_at"] >= attrs["end_at"]:
            raise serializers.ValidationError(
                {"end_at": [_("The end must be after the start.")]}, code="invalid"
            )
        return attrs
