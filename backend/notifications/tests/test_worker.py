"""Reminder rows and email sending (the worker's two steps)."""

import smtplib
from datetime import timedelta
from io import StringIO

import pytest
from django.core import mail
from django.core.management import call_command

from accounts.models import User
from appointments import services as appointment_services
from notifications import services
from notifications.management.commands import run_notification_worker
from notifications.models import Notification

from .conftest import NOW


@pytest.mark.django_db
class TestReminders:
    def test_created_for_confirmed_appointments_inside_the_window_only(
        self, make_appointment, patient
    ):
        soon = make_appointment(timedelta(hours=5))
        make_appointment(timedelta(hours=30))  # beyond REMINDER_MINUTES_BEFORE (24 h)
        make_appointment(timedelta(hours=6), status="cancelled")
        make_appointment(timedelta(hours=-1))  # already started
        assert services.create_due_reminders(NOW) == 1
        (note,) = Notification.objects.all()
        assert (note.user, note.kind) == (patient, "appointment_reminder")
        assert note.dedupe_key == f"reminder:{soon.pk}"
        assert note.data["appointment_id"] == soon.pk

    def test_idempotent_and_counts_only_new_rows(self, make_appointment):
        make_appointment(timedelta(hours=5))
        assert services.create_due_reminders(NOW) == 1
        assert services.create_due_reminders(NOW + timedelta(minutes=1)) == 0
        assert Notification.objects.count() == 1

    def test_none_for_an_inactive_doctor(self, make_appointment, doctor):
        make_appointment(timedelta(hours=5))
        User.objects.filter(pk=doctor.pk).update(is_active=False)
        assert services.create_due_reminders(NOW) == 0

    def test_window_follows_the_setting(self, make_appointment, settings):
        make_appointment(timedelta(hours=5))
        settings.REMINDER_MINUTES_BEFORE = 60
        services.create_due_reminders(NOW)
        assert Notification.objects.count() == 0
        settings.REMINDER_MINUTES_BEFORE = 6 * 60
        services.create_due_reminders(NOW)
        assert Notification.objects.count() == 1


@pytest.mark.django_db
class TestEmails:
    def test_sent_in_the_recipients_language(self, book, patient, doctor):
        User.objects.filter(pk=patient.pk).update(preferred_language="fr")
        User.objects.filter(pk=doctor.pk).update(preferred_language="en")
        book()
        assert services.send_pending_emails() == 2
        by_to = {m.to[0]: m for m in mail.outbox}
        fr, en = by_to[patient.email], by_to[doctor.email]
        assert fr.subject == "Rendez-vous confirmé"
        assert "Bonjour Pat," in fr.body
        assert "Dr Doc Tor" in fr.body
        assert "5 novembre 2026 10:00" in fr.body  # clinic time (Tunis), not UTC
        assert en.subject == "New appointment booked"
        assert "Pat Ient booked an appointment with you for Nov. 5, 2026, 10 a.m." in en.body
        assert set(Notification.objects.values_list("email_status", flat=True)) == {"sent"}

    def test_each_email_is_sent_once(self, book):
        book()
        services.send_pending_emails()
        services.send_pending_emails()
        assert len(mail.outbox) == 2

    def test_failure_retries_then_gives_up(self, book, monkeypatch, settings):
        book()

        def boom(*args, **kwargs):
            raise smtplib.SMTPDataError(554, b"smtp rejected")

        monkeypatch.setattr(services, "send_mail", boom)
        for expected in ("pending", "pending", "failed"):  # NOTIFICATION_MAX_ATTEMPTS = 3
            assert services.send_pending_emails() == 0
            statuses = set(Notification.objects.values_list("email_status", flat=True))
            assert statuses == {expected}
        note = Notification.objects.first()
        assert note.attempts == 3 and "smtp rejected" in note.last_error
        monkeypatch.undo()
        assert services.send_pending_emails() == 0  # failed rows are not retried
        assert mail.outbox == []

    def test_one_failure_does_not_block_the_others(self, book, monkeypatch, patient):
        book()
        real = services.send_mail

        def flaky(subject, body, sender, recipients):
            if recipients == [patient.email]:
                raise smtplib.SMTPRecipientsRefused({patient.email: (550, b"no")})
            return real(subject, body, sender, recipients)

        monkeypatch.setattr(services, "send_mail", flaky)
        assert services.send_pending_emails() == 1
        assert Notification.objects.get(user=patient).email_status == "pending"

    def test_reminder_of_a_cancelled_appointment_is_skipped(
        self, make_appointment, patient, admin_user
    ):
        appointment = make_appointment(timedelta(hours=5))
        services.create_due_reminders(NOW)
        appointment_services.cancel(appointment, actor=admin_user, reason="x")
        Notification.objects.exclude(kind="appointment_reminder").delete()
        services.send_pending_emails()
        assert mail.outbox == []
        assert Notification.objects.get().email_status == "skipped"

    def test_reminder_email_and_inactive_user(self, make_appointment, patient, french):
        make_appointment(timedelta(hours=5))
        services.create_due_reminders(NOW)
        services.send_pending_emails()
        assert mail.outbox[0].subject == "Rappel de rendez-vous"
        assert "Rappel" in mail.outbox[0].body

    def test_inactive_user_gets_no_reminder_email(self, make_appointment, patient):
        make_appointment(timedelta(hours=5))
        services.create_due_reminders(NOW)
        User.objects.filter(pk=patient.pk).update(is_active=False)
        services.send_pending_emails()
        assert mail.outbox == []
        assert Notification.objects.get().email_status == "skipped"

    def test_cancellation_wording(self, book, patient, doctor, admin_user, french):
        appointment = book()
        Notification.objects.all().delete()
        appointment_services.cancel(appointment, actor=admin_user, reason="Panne")
        services.send_pending_emails()
        by_to = {m.to[0]: m for m in mail.outbox}
        assert (
            "Le cabinet a annulé votre rendez-vous avec le Dr Doc Tor" in by_to[patient.email].body
        )
        assert "Le cabinet a annulé votre rendez-vous avec Pat Ient" in by_to[doctor.email].body
        assert "Motif indiqué par le cabinet : « Panne »" in by_to[patient.email].body

        mail.outbox.clear()
        Notification.objects.all().delete()
        # A doctor-initiated cancel names the doctor and gives the reason to the patient.
        other = book(11)
        appointment_services.cancel(other, actor=doctor, reason="Congé")
        Notification.objects.filter(kind="appointment_booked").delete()
        Notification.objects.filter(kind="appointment_confirmed").delete()
        services.send_pending_emails()
        (message,) = mail.outbox
        assert "Le Dr Doc Tor a annulé votre rendez-vous" in message.body
        assert "Motif indiqué par le médecin : « Congé »" in message.body


@pytest.mark.django_db
def test_worker_command_runs_one_cycle(book, make_appointment, monkeypatch):
    monkeypatch.setattr(services.timezone, "now", lambda: NOW)
    book()
    make_appointment(timedelta(hours=5))
    out = StringIO()
    call_command("run_notification_worker", "--once", stdout=out)
    assert "reminders created: 1, emails sent: 3" in out.getvalue()
    assert Notification.objects.filter(kind="appointment_reminder").count() == 1
    assert len(mail.outbox) == 3


@pytest.mark.django_db
class TestRelevanceAndFormat:
    def test_reminder_of_an_inactive_doctor_is_skipped(self, make_appointment, doctor):
        make_appointment(timedelta(hours=5))
        services.create_due_reminders(NOW)
        User.objects.filter(pk=doctor.pk).update(is_active=False)
        services.send_pending_emails()
        assert mail.outbox == []
        assert Notification.objects.get().email_status == "skipped"

    def test_emails_of_an_appointment_that_already_started_are_skipped(self, book):
        book()
        later = NOW + timedelta(days=10)
        mail.outbox.clear()
        original = services.timezone.now
        services.timezone.now = lambda: later
        try:
            services.send_pending_emails()
        finally:
            services.timezone.now = original
        assert mail.outbox == []
        assert set(Notification.objects.values_list("email_status", flat=True)) == {"skipped"}

    def test_cancel_reason_is_one_quoted_attributed_line(self, book, patient, doctor, french):
        appointment = book()
        Notification.objects.all().delete()
        appointment_services.cancel(appointment, actor=doctor, reason="Congé\nBcc: x@y.z")
        services.send_pending_emails()
        (message,) = mail.outbox
        assert "Motif indiqué par le médecin : « Congé Bcc: x@y.z »" in message.body

    def test_english_reason_attribution_and_manual_admin_reason(
        self, book, patient, admin_user, doctor
    ):
        User.objects.filter(pk__in=[patient.pk, doctor.pk]).update(preferred_language="en")
        appointment = book()
        Notification.objects.all().delete()
        appointment_services.cancel(appointment, actor=admin_user, reason="Panne")
        services.send_pending_emails()
        assert all('Reason given by the clinic: "Panne"' in m.body for m in mail.outbox)
        assert len(mail.outbox) == 2

    def test_doctor_greeting_uses_the_last_name(self, book, doctor):
        book()
        services.send_pending_emails()
        by_to = {m.to[0]: m for m in mail.outbox}
        assert "Dr Tor," in by_to[doctor.email].body  # last_name of the fixture doctor


@pytest.mark.django_db
class TestMailServerOutage:
    def test_connection_errors_do_not_use_up_attempts_and_stop_the_batch(self, book, monkeypatch):
        book()
        calls = []

        def down(*args, **kwargs):
            calls.append(1)
            raise ConnectionRefusedError("refused")

        monkeypatch.setattr(services, "send_mail", down)
        for _ in range(5):  # more cycles than NOTIFICATION_MAX_ATTEMPTS (3)
            assert services.send_pending_emails() == 0
        assert len(calls) == 5  # one try per cycle, not one per pending row
        rows = Notification.objects.all()
        assert {n.email_status for n in rows} == {"pending"}
        assert {n.attempts for n in rows} == {0}
        monkeypatch.undo()
        assert services.send_pending_emails() == 2  # recovers once the server is back

    @pytest.mark.parametrize(
        "error",
        [
            smtplib.SMTPServerDisconnected("gone"),
            smtplib.SMTPConnectError(421, "busy"),
            TimeoutError("slow"),
        ],
    )
    def test_other_connection_level_errors(self, book, monkeypatch, error):
        book()

        def down(*args, **kwargs):
            raise error

        monkeypatch.setattr(services, "send_mail", down)
        services.send_pending_emails()
        assert set(Notification.objects.values_list("attempts", flat=True)) == {0}

    def test_stop_flag_is_checked_between_rows(self, book):
        book()
        assert services.send_pending_emails(should_stop=lambda: True) == 0
        assert mail.outbox == []
        sent = []
        assert (
            services.send_pending_emails(should_stop=lambda: sent.append(1) or len(sent) > 1) == 1
        )


@pytest.mark.django_db
class TestPurge:
    def test_deletes_only_old_read_and_finished_rows(self, patient, settings):
        settings.NOTIFICATION_RETENTION_DAYS = 90
        old = NOW - timedelta(days=100)

        def make(key, **kw):
            n = Notification.objects.create(
                user=patient, kind="appointment_confirmed", dedupe_key=key, **kw
            )
            Notification.objects.filter(pk=n.pk).update(created_at=old)
            return n.pk

        gone = make("a", read_at=NOW, email_status="sent")
        unread = make("b", email_status="sent")
        pending = make("c", read_at=NOW)
        recent = Notification.objects.create(
            user=patient,
            kind="appointment_confirmed",
            dedupe_key="d",
            read_at=NOW,
            email_status="sent",
        ).pk
        assert services.purge_old() == 1
        remaining = set(Notification.objects.values_list("pk", flat=True))
        assert remaining == {unread, pending, recent} and gone not in remaining


@pytest.mark.django_db
class TestWorkerCommand:
    def test_each_loop_cycle_closes_stale_connections(self, monkeypatch):
        closed, cycles = [], []

        class StopsAfterTwoCycles:
            def __init__(self):
                self.checks = 0

            def is_set(self):
                self.checks += 1
                return self.checks > 2

            def set(self):
                pass

            def wait(self, timeout=None):
                pass

        module = run_notification_worker
        monkeypatch.setattr(module.threading, "Event", StopsAfterTwoCycles)
        monkeypatch.setattr(module.signal, "signal", lambda *args: None)
        monkeypatch.setattr(module, "close_old_connections", lambda: closed.append(1))
        monkeypatch.setattr(module.services, "run_cycle", lambda **kw: cycles.append(1) or (0, 0))
        call_command("run_notification_worker", stdout=StringIO())
        assert closed == [1, 1] and cycles == [1, 1]

    def test_once_always_prints_counts(self):
        out = StringIO()
        call_command("run_notification_worker", "--once", stdout=out)
        assert "reminders created: 0, emails sent: 0" in out.getvalue()
