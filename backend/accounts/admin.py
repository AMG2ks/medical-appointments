from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin
from django.contrib.auth.forms import BaseUserCreationForm, UserChangeForm
from django.utils.translation import gettext_lazy as _

from .models import PatientProfile, User


class UserCreationForm(BaseUserCreationForm):
    class Meta:
        model = User
        fields = ("email", "first_name", "last_name", "role")


class UserChangeFormEmail(UserChangeForm):
    class Meta:
        model = User
        fields = "__all__"


@admin.register(User)
class UserAdmin(DjangoUserAdmin):
    """Adapted to email login (no username). Create doctors through the app, not here:
    this form would not create their DoctorProfile."""

    form = UserChangeFormEmail
    add_form = UserCreationForm
    ordering = ("email",)
    list_display = ("email", "first_name", "last_name", "role", "is_active")
    list_filter = ("role", "is_active", "preferred_language")
    search_fields = ("email", "first_name", "last_name")
    fieldsets = (
        (None, {"fields": ("email", "password")}),
        (
            _("Personal info"),
            {"fields": ("first_name", "last_name", "phone", "preferred_language")},
        ),
        (
            _("Permissions"),
            {"fields": ("role", "is_active", "is_superuser", "groups", "user_permissions")},
        ),
        (_("Important dates"), {"fields": ("last_login", "date_joined")}),
    )
    add_fieldsets = (
        (
            None,
            {
                "classes": ("wide",),
                "fields": ("email", "first_name", "last_name", "role", "password1", "password2"),
            },
        ),
    )


admin.site.register(PatientProfile)
