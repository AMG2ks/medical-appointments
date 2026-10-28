from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import generics
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services
from .models import Notification
from .serializers import NotificationSerializer, ReadAllSerializer, UnreadCountSerializer

TAG = ["notifications"]


class OwnNotificationsMixin:
    """Everyone sees only their own notifications; others' ids are 404."""

    def get_queryset(self):
        if getattr(self, "swagger_fake_view", False):
            return Notification.objects.none()
        return Notification.objects.filter(user=self.request.user)


class NotificationListView(OwnNotificationsMixin, generics.ListAPIView):
    """My notifications, newest first (`?unread=true` for the unread ones only)."""

    serializer_class = NotificationSerializer

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.request.query_params.get("unread", "").lower() in ("true", "1"):
            queryset = queryset.filter(read_at__isnull=True)
        return queryset

    @extend_schema(
        tags=TAG, parameters=[OpenApiParameter("unread", bool, description="Unread ones only")]
    )
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)


class UnreadCountView(APIView):
    @extend_schema(tags=TAG, responses={200: UnreadCountSerializer})
    def get(self, request):
        return Response({"count": services.unread_count(request.user)})


class MarkReadView(OwnNotificationsMixin, generics.GenericAPIView):
    serializer_class = NotificationSerializer

    @extend_schema(tags=TAG, request=None, responses={200: NotificationSerializer})
    def post(self, request, *args, **kwargs):
        notification = services.mark_read(self.get_object())
        return Response(NotificationSerializer(notification).data)


class MarkAllReadView(APIView):
    @extend_schema(tags=TAG, request=None, responses={200: ReadAllSerializer})
    def post(self, request):
        return Response({"updated": services.mark_all_read(request.user)})
