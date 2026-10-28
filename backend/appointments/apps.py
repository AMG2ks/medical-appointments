from django.apps import AppConfig


class AppointmentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "appointments"

    def ready(self):
        from accounts.signals import user_deactivated
        from doctors import services as doctors_services

        from . import services

        # doctors cannot import appointments (one-way dependency): it asks registered guards
        # before saving a time off.
        doctors_services.register_time_off_guard(services.time_off_conflicts)
        user_deactivated.connect(
            services.cancel_future_appointments_of,
            dispatch_uid="appointments.cancel_future_appointments_of",
        )
