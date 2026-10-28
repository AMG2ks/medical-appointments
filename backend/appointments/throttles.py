from rest_framework.throttling import UserRateThrottle

from accounts.models import User


class PatientCancelThrottle(UserRateThrottle):
    """Tighter cap on patient cancellations (rate `THROTTLE_APPOINTMENT_CANCEL`, per user):
    each one emails the doctor, so book-and-cancel loops must not flood their inbox. Doctors
    and admins are only under the general `appointment_write` scope."""

    scope = "appointment_cancel"

    def allow_request(self, request, view):
        if request.user.role != User.Role.PATIENT:
            return True
        return super().allow_request(request, view)
