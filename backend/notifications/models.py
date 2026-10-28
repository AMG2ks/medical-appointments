from django.conf import settings
from django.db import models


class Notification(models.Model):
    """One thing to tell one user, both as an in-app entry and as an email (outbox row).

    No title / body is stored: the app builds the text from `kind` + `data` with its own
    translations, and the email is rendered when it is sent, in the user's language.
    `data` holds the appointment id (no FK: this app stays a leaf) and a snapshot of what the
    text needs (names, start instant in clinic time with offset, ...).
    """

    class Kind(models.TextChoices):
        APPOINTMENT_CONFIRMED = "appointment_confirmed"  # to the patient who booked
        APPOINTMENT_BOOKED = "appointment_booked"  # to the doctor: new booking
        APPOINTMENT_CANCELLED = "appointment_cancelled"  # to patient and/or doctor
        APPOINTMENT_REMINDER = "appointment_reminder"  # to the patient

    class EmailStatus(models.TextChoices):
        PENDING = "pending"
        SENT = "sent"
        FAILED = "failed"  # gave up after NOTIFICATION_MAX_ATTEMPTS
        SKIPPED = "skipped"  # no longer relevant when its turn came (cancelled, inactive user)

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="notifications"
    )
    kind = models.CharField(max_length=32, choices=Kind.choices)
    data = models.JSONField(default=dict)
    # Makes creation idempotent: `confirmed:<apt>`, `booked:<apt>`, `reminder:<apt>`,
    # `cancelled:<apt>:<user_id>`.
    dedupe_key = models.CharField(max_length=100, unique=True, null=True, blank=True)
    read_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    email_status = models.CharField(
        max_length=10, choices=EmailStatus.choices, default=EmailStatus.PENDING
    )
    attempts = models.PositiveSmallIntegerField(default=0)
    last_error = models.CharField(max_length=300, blank=True)

    class Meta:
        ordering = ["-created_at", "-pk"]
        indexes = [
            models.Index(fields=["user", "read_at"]),
            models.Index(fields=["email_status", "id"]),
        ]

    def __str__(self):
        return f"#{self.pk} {self.kind} -> user {self.user_id}"
