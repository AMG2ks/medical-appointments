"""Business rules of the notifications module (plain functions, no HTTP).

Outbox pattern: `record_appointment_event` (receiver of `appointment_event`) writes rows in the
booking transaction; the worker (`run_notification_worker`) creates reminder rows and sends
the emails afterwards, so a failing SMTP server never breaks a booking.
"""

import logging
import smtplib
from collections.abc import Callable
from datetime import datetime, timedelta

from django.conf import settings
from django.core.mail import send_mail
from django.db import transaction
from django.template.loader import render_to_string
from django.utils import timezone, translation
from django.utils.dateformat import time_format
from django.utils.formats import date_format
from django.utils.translation import gettext
from django.utils.translation import gettext_lazy as _

from accounts.models import User
from appointments.models import Appointment
from appointments.signals import EVENT_CANCELLED, EVENT_CONFIRMED

from .models import Notification

logger = logging.getLogger(__name__)

Kind = Notification.Kind
Status = Notification.EmailStatus

SUBJECTS = {
    Kind.APPOINTMENT_CONFIRMED: _("Appointment confirmed"),
    Kind.APPOINTMENT_BOOKED: _("New appointment booked"),
    Kind.APPOINTMENT_CANCELLED: _("Appointment cancelled"),
    Kind.APPOINTMENT_REMINDER: _("Appointment reminder"),
}
# Who gave a cancel reason, as a phrase for "Reason given by ...".
REASON_BY = {
    "patient": _("the patient"),
    "doctor": _("the doctor"),
    "admin": _("the clinic"),
}
SEND_BATCH = 100
LAST_ERROR_MAX = 300


def _name(user: User) -> str:
    return f"{user.first_name} {user.last_name}".strip()


def _data(appointment: Appointment) -> dict:
    """Snapshot stored in `Notification.data` (the app and the email build their text from it)."""
    return {
        "appointment_id": appointment.pk,
        # Clinic time with its offset (same shape as the appointments API): an absolute instant
        # whose wall clock the app can show as is.
        "start_at": timezone.localtime(appointment.start_at).isoformat(),
        "doctor_name": _name(appointment.doctor.user),
        "patient_name": _name(appointment.patient),
    }


def _row(user: User, kind: str, data: dict, key: str) -> Notification:
    return Notification(user=user, kind=kind, data=data, dedupe_key=key)


# --- outbox: appointment events ---


def _flat(text: str) -> str:
    """One line: a reason is user text going into an email and a notification."""
    return " ".join(text.split())


def record_appointment_event(appointment: Appointment, event: str, *, automatic: bool = False):
    """Who is told what:

    - confirmed: the patient (`appointment_confirmed`) and the doctor (`appointment_booked`);
    - cancelled: the patient and the doctor (`appointment_cancelled`), except whoever did the
      cancel. `data.cancelled_by` is the actor's role (`admin` when unknown), so a cancel made
      by an admin reads "the clinic cancelled it". The cancel reason (flattened to one line)
      is kept for every manual cancel, and dropped for `automatic` ones (the cancels of an
      account deactivation: their reason is a fixed sentence in the admin's language).

    Idempotent (`dedupe_key`), so a repeated event never duplicates a row."""
    patient, doctor = appointment.patient, appointment.doctor.user
    data = _data(appointment)
    rows: list[Notification] = []
    if event == EVENT_CONFIRMED:
        rows.append(_row(patient, Kind.APPOINTMENT_CONFIRMED, data, f"confirmed:{appointment.pk}"))
        rows.append(_row(doctor, Kind.APPOINTMENT_BOOKED, data, f"booked:{appointment.pk}"))
    elif event == EVENT_CANCELLED:
        actor = appointment.cancelled_by
        data["cancelled_by"] = actor.role if actor else User.Role.ADMIN
        reason = _flat(appointment.cancellation_reason)
        if reason and not automatic:
            data["reason"] = reason
        for user in (patient, doctor):
            if actor is None or user.pk != actor.pk:
                key = f"cancelled:{appointment.pk}:{user.pk}"
                rows.append(_row(user, Kind.APPOINTMENT_CANCELLED, data, key))
    Notification.objects.bulk_create(rows, ignore_conflicts=True)


# --- worker, step a: reminders ---


def create_due_reminders(now: datetime | None = None) -> int:
    """One reminder row per confirmed appointment starting within REMINDER_MINUTES_BEFORE
    (active patient and doctor). Idempotent (`reminder:<appointment_id>`). Returns the number
    of rows created by this call."""
    now = now or timezone.now()
    horizon = now + timedelta(minutes=settings.REMINDER_MINUTES_BEFORE)
    due = list(
        Appointment.objects.filter(
            status=Appointment.Status.CONFIRMED,
            start_at__gt=now,
            start_at__lte=horizon,
            patient__is_active=True,
            doctor__user__is_active=True,
        )
        .select_related("patient", "doctor__user")
        .order_by("start_at")
    )
    keys = {a.pk: f"reminder:{a.pk}" for a in due}
    existing = set(
        Notification.objects.filter(dedupe_key__in=keys.values()).values_list(
            "dedupe_key", flat=True
        )
    )
    rows = [
        _row(a.patient, Kind.APPOINTMENT_REMINDER, _data(a), keys[a.pk])
        for a in due
        if keys[a.pk] not in existing
    ]
    Notification.objects.bulk_create(rows, ignore_conflicts=True)
    return len(rows)


# --- worker, step b: emails ---


def _when(start: datetime) -> str:
    """`Nov. 5, 2026 at 10:00` / `5 novembre 2026 à 10:00`: the same 24 h shape in both
    languages, and it never ends with a period (the sentence adds its own)."""
    return gettext("%(date)s at %(time)s") % {
        "date": date_format(start, "DATE_FORMAT"),
        "time": time_format(start, "H:i"),
    }


def render_email(notification: Notification) -> tuple[str, str]:
    """(subject, body) in the recipient's preferred language."""
    user = notification.user
    data = notification.data
    start = timezone.localtime(datetime.fromisoformat(data["start_at"]))
    with translation.override(user.preferred_language):
        context = {
            "user": user,
            "doctor_name": data.get("doctor_name", ""),
            "patient_name": data.get("patient_name", ""),
            "when": _when(start),
            "cancelled_by": data.get("cancelled_by", ""),
            "reason": _flat(data.get("reason", "")),
            "reason_by": REASON_BY.get(data.get("cancelled_by", ""), ""),
            "is_doctor": user.role == User.Role.DOCTOR,
        }
        body = render_to_string(f"notifications/email/{notification.kind}.txt", context)
        return str(SUBJECTS[notification.kind]), body


def _still_relevant(notification: Notification, now: datetime) -> bool:
    """Skip what no longer makes sense when its turn comes. A cancellation always goes out
    (that is how a deactivated patient learns it); everything else needs an active user, an
    appointment that has not started, and for a reminder a confirmed appointment with an
    active doctor."""
    if notification.kind == Kind.APPOINTMENT_CANCELLED:
        return True
    if not notification.user.is_active:
        return False
    start = notification.data.get("start_at")
    if start and datetime.fromisoformat(start) <= now:
        return False
    if notification.kind == Kind.APPOINTMENT_REMINDER:
        return Appointment.objects.filter(
            pk=notification.data.get("appointment_id"),
            status=Appointment.Status.CONFIRMED,
            doctor__user__is_active=True,
        ).exists()
    return True


def _is_connection_error(exc: Exception) -> bool:
    """The server is unreachable (nothing to do with this message): refused, unresolvable,
    timed out, dropped. A rejection of the message itself (`SMTPRecipientsRefused`,
    `SMTPDataError`, ...) is also an `OSError` subclass, hence the explicit check."""
    if isinstance(exc, smtplib.SMTPServerDisconnected | smtplib.SMTPConnectError):
        return True
    return isinstance(exc, OSError) and not isinstance(exc, smtplib.SMTPException)


# Returned by `send_one` when the mail server cannot be reached.
UNAVAILABLE = "unavailable"


def send_one(pk: int) -> str | None:
    """Send the email of one pending row (row-locked, so two workers never double send).
    Returns the new status, `UNAVAILABLE` if the mail server cannot be reached (the row is
    untouched: an outage must not use up the attempts of every pending email), or None if
    the row is gone / not pending / locked."""
    with transaction.atomic():
        notification = (
            Notification.objects.select_for_update(skip_locked=True, of=("self",))
            .select_related("user")
            .filter(pk=pk, email_status=Status.PENDING)
            .first()
        )
        if notification is None:
            return None
        if not _still_relevant(notification, timezone.now()):
            notification.email_status = Status.SKIPPED
        else:
            try:
                subject, body = render_email(notification)
                send_mail(subject, body, None, [notification.user.email])
            except Exception as exc:  # one bad email must not stop the others
                if _is_connection_error(exc):
                    # Class name only in the logs: SMTP messages can echo the address.
                    logger.warning("mail server unreachable (%s)", type(exc).__name__)
                    return UNAVAILABLE
                notification.attempts += 1
                notification.last_error = f"{type(exc).__name__}: {exc}"[:LAST_ERROR_MAX]
                if notification.attempts >= settings.NOTIFICATION_MAX_ATTEMPTS:
                    notification.email_status = Status.FAILED
                logger.warning(
                    "notification %s email attempt %s failed (%s)",
                    notification.pk,
                    notification.attempts,
                    type(exc).__name__,
                )
            else:
                notification.attempts += 1
                notification.email_status = Status.SENT
                notification.last_error = ""
        notification.save(update_fields=["email_status", "attempts", "last_error"])
        return notification.email_status


def send_pending_emails(
    limit: int = SEND_BATCH, should_stop: Callable[[], bool] | None = None
) -> int:
    """Try every pending email once (oldest first, at most `limit`). Returns how many were
    sent. Stops early when the mail server is unreachable (the rest would fail the same way)
    or when `should_stop()` turns true (the worker is being shut down)."""
    ids = list(
        Notification.objects.filter(
            email_status=Status.PENDING, attempts__lt=settings.NOTIFICATION_MAX_ATTEMPTS
        )
        .order_by("pk")
        .values_list("pk", flat=True)[:limit]
    )
    sent = 0
    for pk in ids:
        if should_stop and should_stop():
            break
        result = send_one(pk)
        if result == UNAVAILABLE:
            break
        sent += result == Status.SENT
    return sent


def purge_old(now: datetime | None = None) -> int:
    """Delete notifications that are read, whose email is done (not pending) and that are
    older than NOTIFICATION_RETENTION_DAYS. Returns how many were deleted."""
    cutoff = (now or timezone.now()) - timedelta(days=settings.NOTIFICATION_RETENTION_DAYS)
    old = Notification.objects.filter(read_at__isnull=False, created_at__lt=cutoff)
    return old.exclude(email_status=Status.PENDING).delete()[0]


def run_cycle(should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """One worker iteration: (reminder rows created, emails sent)."""
    return create_due_reminders(), send_pending_emails(should_stop=should_stop)


# --- in-app list ---


def unread_count(user: User) -> int:
    return Notification.objects.filter(user=user, read_at__isnull=True).count()


def mark_read(notification: Notification) -> Notification:
    if notification.read_at is None:
        notification.read_at = timezone.now()
        notification.save(update_fields=["read_at"])
    return notification


def mark_all_read(user: User) -> int:
    return Notification.objects.filter(user=user, read_at__isnull=True).update(
        read_at=timezone.now()
    )
