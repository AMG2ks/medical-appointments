"""Shared pytest fixtures (owned by M1). Use them in every module's tests."""

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from accounts.models import PatientProfile, User
from doctors.models import DoctorProfile, Specialty

PASSWORD = "S3cure-pass!"


@pytest.fixture(autouse=True)
def _clear_cache():
    """Throttle counters live in the cache: never let them leak between tests."""
    cache.clear()


@pytest.fixture(autouse=True)
def _fast_password_hasher(settings):
    """The default hasher is deliberately slow; tests do not need that."""
    settings.PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]


@pytest.fixture
def api_client():
    return APIClient()


@pytest.fixture
def auth_client():
    """`auth_client(user)` -> APIClient logged in as `user` (force_authenticate, no JWT)."""

    def make(user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    return make


@pytest.fixture
def patient(db):
    user = User.objects.create_user(
        "patient@example.com",
        PASSWORD,
        first_name="Pat",
        last_name="Ient",
        role=User.Role.PATIENT,
    )
    PatientProfile.objects.create(user=user)
    return user


@pytest.fixture
def specialty(db):
    return Specialty.objects.create(name_fr="Cardiologie", name_en="Cardiology")


@pytest.fixture
def doctor(db, specialty):
    """A doctor User with a DoctorProfile (same id). Use `doctor.doctor_profile`."""
    user = User.objects.create_user(
        "doctor@example.com", PASSWORD, first_name="Doc", last_name="Tor", role=User.Role.DOCTOR
    )
    DoctorProfile.objects.create(user=user, specialty=specialty)
    return user


@pytest.fixture
def admin_user(db):
    return User.objects.create_superuser(
        "admin@example.com", PASSWORD, first_name="Ad", last_name="Min"
    )
