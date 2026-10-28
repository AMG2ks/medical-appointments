from rest_framework import serializers

from .models import Notification


class NotificationSerializer(serializers.ModelSerializer):
    """No text: the app builds it from `kind` + `data`. Email bookkeeping stays internal."""

    class Meta:
        model = Notification
        fields = ["id", "kind", "data", "read_at", "created_at"]
        read_only_fields = fields


class UnreadCountSerializer(serializers.Serializer):
    count = serializers.IntegerField()


class ReadAllSerializer(serializers.Serializer):
    updated = serializers.IntegerField()
