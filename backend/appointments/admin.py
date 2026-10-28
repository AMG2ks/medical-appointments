from django.contrib import admin

from .models import Appointment


@admin.register(Appointment)
class AppointmentAdmin(admin.ModelAdmin):
    """Read-only back office: changes go through the API so rules, locks and events apply."""

    list_display = ("id", "start_at", "doctor", "patient", "status")
    list_filter = ("status",)
    raw_id_fields = ("patient", "doctor", "cancelled_by")

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
