from rest_framework import serializers

from appointments.models import Appointment


class UserCountsSerializer(serializers.Serializer):
    total = serializers.IntegerField()
    active = serializers.IntegerField()


# One integer per appointment status (confirmed, cancelled, completed, no_show).
StatusCountsSerializer = type(
    "StatusCountsSerializer",
    (serializers.Serializer,),
    {s: serializers.IntegerField() for s in Appointment.Status.values},
)


class AppointmentCountsSerializer(serializers.Serializer):
    total = serializers.IntegerField()
    today = serializers.IntegerField()
    this_week = serializers.IntegerField()
    by_status = StatusCountsSerializer()


class StatsSerializer(serializers.Serializer):
    patients = UserCountsSerializer()
    doctors = UserCountsSerializer()
    appointments = AppointmentCountsSerializer()
