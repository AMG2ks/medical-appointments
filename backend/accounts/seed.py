"""Demo accounts for `manage.py seed_demo` (idempotent). Password: SEED_DEMO_PASSWORD."""

from django.conf import settings
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ImproperlyConfigured

from . import services
from .models import User

DEMO_USERS = [
    # (email, first_name, last_name, role, language)
    ("admin@medapp.local", "Admin", "MedApp", User.Role.ADMIN, "fr"),
    ("dr.karim@medapp.local", "Karim", "Haddad", User.Role.DOCTOR, "fr"),
    ("dr.sarah@medapp.local", "Sarah", "Miller", User.Role.DOCTOR, "en"),
    ("amira@medapp.local", "Amira", "Ben Salah", User.Role.PATIENT, "fr"),
    ("john@medapp.local", "John", "Smith", User.Role.PATIENT, "en"),
]


def run() -> None:
    password = settings.SEED_DEMO_PASSWORD
    if not password or any(marker in password.lower() for marker in ("change-me", "dev-only")):
        raise ImproperlyConfigured(
            "Set SEED_DEMO_PASSWORD in backend/.env to a real password (not a placeholder)."
        )
    validate_password(password)  # demo accounts are real accounts: same rules as users
    for email, first_name, last_name, role, language in DEMO_USERS:
        if User.objects.filter(email=email).exists():
            continue
        if role == User.Role.PATIENT:
            services.register_patient(
                data={
                    "email": email,
                    "password": password,
                    "first_name": first_name,
                    "last_name": last_name,
                    "preferred_language": language,
                }
            )
        elif role == User.Role.ADMIN:
            User.objects.create_superuser(
                email,
                password,
                first_name=first_name,
                last_name=last_name,
                preferred_language=language,
            )
        else:
            services.create_user(
                email=email,
                first_name=first_name,
                last_name=last_name,
                role=role,
                preferred_language=language,
                password=password,
            )
