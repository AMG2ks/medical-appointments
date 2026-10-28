from django.conf import settings
from django.db import models
from django.db.models import F, Q

REASON_MAX_LENGTH = 500


class Appointment(models.Model):
    """A booking. Confirmed at once; `confirmed -> cancelled | completed | no_show` only."""

    class Status(models.TextChoices):
        CONFIRMED = "confirmed"
        CANCELLED = "cancelled"
        COMPLETED = "completed"
        NO_SHOW = "no_show"

    # PROTECT: users are deactivated, never deleted, and history must survive.
    patient = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="appointments"
    )
    doctor = models.ForeignKey(
        "doctors.DoctorProfile", on_delete=models.PROTECT, related_name="appointments"
    )
    start_at = models.DateTimeField()
    end_at = models.DateTimeField()
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.CONFIRMED)
    reason = models.CharField(max_length=REASON_MAX_LENGTH, blank=True)
    cancelled_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="+"
    )
    cancellation_reason = models.CharField(max_length=REASON_MAX_LENGTH, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["start_at", "pk"]
        indexes = [
            models.Index(fields=["doctor", "start_at"]),
            models.Index(fields=["patient", "start_at"]),
        ]
        constraints = [
            # DB backstop of the double-booking rule (the transaction + doctor row lock is the
            # real guard, and also catches overlaps between slots of different lengths).
            models.UniqueConstraint(
                fields=["doctor", "start_at"],
                condition=Q(status="confirmed"),
                name="appointment_one_confirmed_per_doctor_start",
            ),
            models.CheckConstraint(
                condition=Q(start_at__lt=F("end_at")), name="appointment_start_before_end"
            ),
        ]

    def __str__(self):
        return f"#{self.pk} {self.start_at:%Y-%m-%d %H:%M} ({self.status})"
