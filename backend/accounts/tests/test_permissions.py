from types import SimpleNamespace

import pytest
from django.contrib.auth.models import AnonymousUser

from accounts.permissions import IsAdmin, IsDoctor, IsPatient


def allowed(permission, user):
    return permission().has_permission(SimpleNamespace(user=user), None)


@pytest.mark.django_db
def test_each_role_only_passes_its_own_class(patient, doctor, admin_user):
    expected = {
        IsPatient: patient,
        IsDoctor: doctor,
        IsAdmin: admin_user,
    }
    for permission, owner in expected.items():
        for user in (patient, doctor, admin_user):
            assert allowed(permission, user) is (user == owner)


def test_anonymous_is_refused():
    for permission in (IsPatient, IsDoctor, IsAdmin):
        assert allowed(permission, AnonymousUser()) is False


@pytest.mark.django_db
def test_operators_combine(patient, doctor):
    either = IsPatient | IsDoctor
    assert either().has_permission(SimpleNamespace(user=patient), None)
    assert either().has_permission(SimpleNamespace(user=doctor), None)
