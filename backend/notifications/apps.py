from django.apps import AppConfig


class NotificationsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "notifications"

    def ready(self):
        from appointments.signals import appointment_event

        from . import receivers

        appointment_event.connect(
            receivers.on_appointment_event, dispatch_uid="notifications.on_appointment_event"
        )
