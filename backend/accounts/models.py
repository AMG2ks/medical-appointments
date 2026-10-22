from django.conf import settings
from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.core.validators import RegexValidator
from django.db import models
from django.utils import timezone

phone_validator = RegexValidator(r"^\+?[0-9]{8,15}$")


class UserManager(BaseUserManager):
    use_in_migrations = True

    def create_user(self, email, password=None, **extra):
        if not email:
            raise ValueError("The email must be set.")
        user = self.model(email=self.normalize_email(email).lower(), **extra)
        if password is None:
            user.set_unusable_password()  # e.g. invited doctors: they set it with a code
        else:
            user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password=None, **extra):
        extra.update(role=User.Role.ADMIN, is_staff=True, is_superuser=True)
        return self.create_user(email, password, **extra)

    def get_by_natural_key(self, email):
        # Makes login case-insensitive everywhere (API and Django admin).
        return self.get(email__iexact=email)


class User(AbstractUser):
    class Role(models.TextChoices):
        PATIENT = "patient"
        DOCTOR = "doctor"
        ADMIN = "admin"

    class Language(models.TextChoices):
        FR = "fr", "Français"
        EN = "en", "English"

    username = None
    email = models.EmailField(unique=True)  # stored lowercase
    phone = models.CharField(max_length=20, blank=True, validators=[phone_validator])
    role = models.CharField(
        max_length=10, choices=Role.choices, default=Role.PATIENT, db_index=True
    )
    preferred_language = models.CharField(
        max_length=2, choices=Language.choices, default=Language.FR
    )

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = ["first_name", "last_name"]
    objects = UserManager()

    def save(self, *args, **kwargs):
        self.email = self.email.lower()
        self.is_staff = self.role == self.Role.ADMIN  # Django admin access follows the role
        super().save(*args, **kwargs)

    def __str__(self):
        return self.email


class PatientProfile(models.Model):
    """Patient data owned by Auth. No medical data here."""

    user = models.OneToOneField(
        User, primary_key=True, on_delete=models.CASCADE, related_name="patient_profile"
    )
    date_of_birth = models.DateField(null=True, blank=True)


class PasswordResetCode(models.Model):
    class Purpose(models.TextChoices):
        RESET = "reset"
        INVITE = "invite"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="password_codes"
    )
    purpose = models.CharField(max_length=10, choices=Purpose.choices)
    code_hash = models.CharField(max_length=128)  # make_password(code), never the clear code
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    attempts = models.PositiveSmallIntegerField(default=0)
    used_at = models.DateTimeField(null=True, blank=True)

    def is_expired(self) -> bool:
        return self.expires_at <= timezone.now()
