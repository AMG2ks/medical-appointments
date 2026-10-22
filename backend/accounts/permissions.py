"""Role checks exported to every module. Combine with DRF operators:
`permission_classes = [IsPatient | IsAdmin]`.

They check the role only. Object-level ownership ("is this my appointment?") is each
module's job: filter querysets by `request.user` so other people's objects return 404.
"""

from rest_framework.permissions import BasePermission

from .models import User


class _HasRole(BasePermission):
    role: str

    def has_permission(self, request, view):
        user = request.user
        return bool(user and user.is_authenticated and user.role == self.role)


class IsPatient(_HasRole):
    role = User.Role.PATIENT


class IsDoctor(_HasRole):
    role = User.Role.DOCTOR


class IsAdmin(_HasRole):
    role = User.Role.ADMIN
