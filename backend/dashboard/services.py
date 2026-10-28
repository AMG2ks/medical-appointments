"""Admin dashboard figures. Read-only, computed in TIME_ZONE."""

from datetime import datetime, time, timedelta

from django.db.models import Count, Q
from django.utils import timezone

from accounts.models import User
from appointments.models import Appointment


def _now() -> datetime:
    """The one clock of this module (tests patch it)."""
    return timezone.now()


def _day_bounds(day) -> tuple[datetime, datetime]:
    start = timezone.make_aware(datetime.combine(day, time.min))
    return start, timezone.make_aware(datetime.combine(day + timedelta(days=1), time.min))


def _users(role: str) -> dict:
    users = User.objects.filter(role=role)
    return {"total": users.count(), "active": users.filter(is_active=True).count()}


def stats() -> dict:
    """Counts of patients, doctors and appointments.

    `today` / `this_week` count appointments (any status) that start on the current calendar
    day / ISO week (Monday to Sunday) in TIME_ZONE; `by_status` covers all appointments ever
    (every status is present, 0 when empty)."""
    today = timezone.localdate(_now())
    day_start, day_end = _day_bounds(today)
    week_start, _ = _day_bounds(today - timedelta(days=today.weekday()))
    _, week_end = _day_bounds(today - timedelta(days=today.weekday()) + timedelta(days=6))

    def starting(start, end):
        return Count("pk", filter=Q(start_at__gte=start, start_at__lt=end))

    aggregates = Appointment.objects.order_by().aggregate(
        total=Count("pk"),
        today=starting(day_start, day_end),
        this_week=starting(week_start, week_end),
        **{s: Count("pk", filter=Q(status=s)) for s in Appointment.Status.values},
    )
    return {
        "patients": _users(User.Role.PATIENT),
        "doctors": _users(User.Role.DOCTOR),
        "appointments": {
            "total": aggregates["total"],
            "today": aggregates["today"],
            "this_week": aggregates["this_week"],
            "by_status": {s: aggregates[s] for s in Appointment.Status.values},
        },
    }
