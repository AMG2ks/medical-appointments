from django.contrib import admin

from .models import Notification


@admin.register(Notification)
class NotificationAdmin(admin.ModelAdmin):
    """Read-only back office: rows are created by the receiver / worker only."""

    list_display = ("id", "created_at", "user", "kind", "email_status", "attempts", "read_at")
    list_filter = ("kind", "email_status")
    raw_id_fields = ("user",)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
