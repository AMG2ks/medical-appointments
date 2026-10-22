import pytest
from django.db import IntegrityError, transaction

from accounts.models import User
from conftest import PASSWORD


@pytest.mark.django_db
def test_email_is_lowercased():
    user = User.objects.create_user("Mixed.Case@Example.COM", PASSWORD)
    assert user.email == "mixed.case@example.com"


@pytest.mark.django_db
def test_duplicate_email_in_other_case_is_rejected():
    User.objects.create_user("a@example.com", PASSWORD)
    with pytest.raises(IntegrityError), transaction.atomic():
        User.objects.create_user("A@example.com", PASSWORD)


@pytest.mark.django_db
def test_create_user_without_password_is_unusable():
    user = User.objects.create_user("invited@example.com")
    assert not user.has_usable_password()


@pytest.mark.django_db
def test_create_superuser_is_admin_and_staff():
    user = User.objects.create_superuser("root@example.com", PASSWORD)
    assert user.role == User.Role.ADMIN
    assert user.is_staff and user.is_superuser


@pytest.mark.django_db
def test_staff_follows_role():
    user = User.objects.create_user("d@example.com", PASSWORD, role=User.Role.DOCTOR)
    assert not user.is_staff
    user.role = User.Role.ADMIN
    user.save()
    assert user.is_staff


@pytest.mark.django_db
def test_login_lookup_is_case_insensitive():
    user = User.objects.create_user("lower@example.com", PASSWORD)
    assert User.objects.get_by_natural_key("LOWER@example.com") == user


@pytest.mark.django_db
def test_preferred_language_defaults_to_fr():
    assert User.objects.create_user("x@example.com", PASSWORD).preferred_language == "fr"
