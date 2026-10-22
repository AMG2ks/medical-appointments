import os
import subprocess
import sys

import pytest
from django.core.exceptions import ImproperlyConfigured, ValidationError
from django.core.management import call_command

from accounts.models import User
from config.settings import BASE_DIR


@pytest.mark.django_db
def test_swagger_and_schema_are_served(api_client):
    assert api_client.get("/api/docs/").status_code == 200
    schema = api_client.get("/api/schema/?format=json")
    assert schema.status_code == 200
    paths = schema.json()["paths"]
    for path in ["/api/v1/auth/login/", "/api/v1/auth/me/", "/api/v1/users/{id}/"]:
        assert path in paths


@pytest.mark.django_db
def test_seed_demo_is_idempotent(settings):
    settings.SEED_DEMO_PASSWORD = "Demo-pass-2026-xyz"
    call_command("seed_demo")
    call_command("seed_demo")
    assert User.objects.count() == 5
    assert User.objects.filter(role=User.Role.DOCTOR).count() == 2
    assert User.objects.get(email="amira@medapp.local").patient_profile is not None


@pytest.mark.django_db
@pytest.mark.parametrize("password", ["", "change-me-too", "short", "12345678"])
def test_seed_demo_refuses_weak_or_placeholder_password(settings, password):
    settings.SEED_DEMO_PASSWORD = password
    with pytest.raises((ImproperlyConfigured, ValidationError)):
        call_command("seed_demo")
    assert User.objects.count() == 0


def test_django_admin_is_off_by_default(client):
    assert client.get("/admin/").status_code == 404


@pytest.mark.parametrize("key", ["", "short", "change-me-" + "x" * 60, "dev-only-" + "x" * 60])
def test_settings_refuse_bad_secret_key(key):
    env = {**os.environ, "SECRET_KEY": key}
    result = subprocess.run(
        [sys.executable, "-c", "import config.settings"],
        cwd=BASE_DIR,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "SECRET_KEY" in result.stderr
