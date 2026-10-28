from django.utils.translation import gettext
from drf_spectacular.utils import extend_schema_field
from rest_framework import serializers

from accounts.models import User
from accounts.serializers import UserSummarySerializer
from core.fields import SafeDateTimeField
from doctors.serializers import SpecialtySerializer

from .models import REASON_MAX_LENGTH, Appointment


class AppointmentDoctorSerializer(serializers.Serializer):
    """Doctor card embedded in an appointment (no email / phone, like the public card)."""

    id = serializers.IntegerField(source="user_id")
    first_name = serializers.CharField(source="user.first_name")
    last_name = serializers.CharField(source="user.last_name")
    specialty = SpecialtySerializer()


class CancelledBySerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "role"]
        read_only_fields = fields


class AppointmentSerializer(serializers.ModelSerializer):
    # The system's own reasons (account deactivation) are stored in English and translated
    # here; a reason typed by a person is returned as written.
    cancellation_reason = serializers.SerializerMethodField()
    patient = UserSummarySerializer(read_only=True)
    doctor = AppointmentDoctorSerializer(read_only=True)
    cancelled_by = CancelledBySerializer(read_only=True)

    class Meta:
        model = Appointment
        fields = [
            "id",
            "patient",
            "doctor",
            "start_at",
            "end_at",
            "status",
            "reason",
            "cancelled_by",
            "cancellation_reason",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    @extend_schema_field(serializers.CharField())
    def get_cancellation_reason(self, obj) -> str:
        from .services import AUTOMATIC_REASONS

        reason = obj.cancellation_reason
        return gettext(reason) if reason in AUTOMATIC_REASONS else reason


class BookAppointmentSerializer(serializers.Serializer):
    doctor = serializers.IntegerField(min_value=1)
    start_at = SafeDateTimeField()
    reason = serializers.CharField(
        required=False, allow_blank=True, max_length=REASON_MAX_LENGTH, default=""
    )


class CancelAppointmentSerializer(serializers.Serializer):
    reason = serializers.CharField(
        required=False, allow_blank=True, max_length=REASON_MAX_LENGTH, default=""
    )


class SlotQuerySerializer(serializers.Serializer):
    doctor = serializers.IntegerField(min_value=1)
    date = serializers.DateField()


class SlotSerializer(serializers.Serializer):
    start_at = serializers.DateTimeField()
    end_at = serializers.DateTimeField()


class SlotsResponseSerializer(serializers.Serializer):
    """Not paginated: a day holds a bounded number of slots."""

    doctor = serializers.IntegerField()
    date = serializers.DateField()
    consultation_minutes = serializers.IntegerField()
    slots = SlotSerializer(many=True)
