from django.conf import settings
from django.db import models
from django.db.models import F, Q

# Limits shared by the model, the serializers and the docs.
CONSULTATION_MINUTES_MIN = 5
CONSULTATION_MINUTES_MAX = 240
BIO_MAX_LENGTH = 2000


class Specialty(models.Model):
    """Names are data, not UI strings: stored in both languages, the app picks one."""

    name_fr = models.CharField(max_length=100, unique=True)
    name_en = models.CharField(max_length=100, unique=True)

    class Meta:
        ordering = ["name_fr"]
        verbose_name_plural = "specialties"

    def __str__(self):
        return self.name_en


class DoctorProfile(models.Model):
    """Professional data of a doctor. The user id is the doctor id everywhere."""

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        primary_key=True,
        on_delete=models.CASCADE,
        related_name="doctor_profile",
    )
    specialty = models.ForeignKey(Specialty, on_delete=models.PROTECT, related_name="doctors")
    bio = models.TextField(
        max_length=BIO_MAX_LENGTH, blank=True
    )  # free text written by the doctor, not translated
    consultation_minutes = models.PositiveSmallIntegerField(default=30)

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=Q(
                    consultation_minutes__gte=CONSULTATION_MINUTES_MIN,
                    consultation_minutes__lte=CONSULTATION_MINUTES_MAX,
                ),
                name="doctor_consultation_minutes_range",
            )
        ]

    def __str__(self):
        return f"Dr {self.user.last_name}"


class WeeklyAvailability(models.Model):
    """Recurring weekly window, in wall-clock time of settings.TIME_ZONE (0 = Monday)."""

    doctor = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, related_name="availabilities"
    )
    weekday = models.PositiveSmallIntegerField()
    start_time = models.TimeField()
    end_time = models.TimeField()

    class Meta:
        ordering = ["weekday", "start_time"]
        constraints = [
            models.CheckConstraint(
                condition=Q(weekday__gte=0, weekday__lte=6), name="availability_weekday_range"
            ),
            models.CheckConstraint(
                condition=Q(start_time__lt=F("end_time")), name="availability_start_before_end"
            ),
        ]


class TimeOff(models.Model):
    """Absolute period during which the doctor takes no appointments."""

    doctor = models.ForeignKey(DoctorProfile, on_delete=models.CASCADE, related_name="time_offs")
    start_at = models.DateTimeField()
    end_at = models.DateTimeField()
    reason = models.CharField(max_length=200, blank=True)

    class Meta:
        ordering = ["-start_at"]
        indexes = [models.Index(fields=["doctor", "start_at"])]
        constraints = [
            models.CheckConstraint(
                condition=Q(start_at__lt=F("end_at")), name="timeoff_start_before_end"
            )
        ]
