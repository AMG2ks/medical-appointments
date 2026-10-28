"""Rows written by the `appointment_event` receiver (outbox)."""

from datetime import timedelta

import pytest

from accounts import services as account_services
from appointments import services
from appointments.models import Appointment
from appointments.signals import appointment_event
from core.exceptions import BusinessError
from notifications.models import Notification

from .conftest import DAY, at


def rows():
    return {(n.user.email, n.kind): n for n in Notification.objects.select_related("user")}


@pytest.mark.django_db
class TestConfirmed:
    def test_patient_and_doctor_are_notified(self, book, patient, doctor):
        appointment = book()
        found = rows()
        assert set(found) == {
            (patient.email, "appointment_confirmed"),
            (doctor.email, "appointment_booked"),
        }
        data = found[(patient.email, "appointment_confirmed")].data
        assert data == {
            "appointment_id": appointment.pk,
            "start_at": "2026-11-05T10:00:00+01:00",  # clinic time (Tunis, UTC+1)
            "doctor_name": "Doc Tor",
            "patient_name": "Pat Ient",
        }
        assert all(n.email_status == "pending" and n.read_at is None for n in found.values())

    def test_a_failed_booking_leaves_no_row(self, book, patient, profile):
        book()
        Notification.objects.all().delete()
        with pytest.raises(BusinessError):  # slot_taken
            services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10))
        assert Notification.objects.count() == 0

    def test_the_same_event_twice_does_not_duplicate(self, book):
        appointment = book()
        appointment_event.send(sender=Appointment, appointment=appointment, event="confirmed")
        assert Notification.objects.count() == 2


@pytest.mark.django_db
class TestCancelled:
    def test_by_patient_only_the_doctor_is_told(self, book, patient, doctor):
        appointment = book()
        Notification.objects.all().delete()
        services.cancel(appointment, actor=patient, reason="Empêchement")
        (note,) = Notification.objects.all()
        assert (note.user, note.kind) == (doctor, "appointment_cancelled")
        assert note.data["cancelled_by"] == "patient"
        assert note.data["reason"] == "Empêchement"

    def test_by_doctor_only_the_patient_is_told(self, book, patient, doctor):
        appointment = book()
        Notification.objects.all().delete()
        services.cancel(appointment, actor=doctor, reason="Congé")
        (note,) = Notification.objects.all()
        assert (note.user, note.kind) == (patient, "appointment_cancelled")
        assert note.data["cancelled_by"] == "doctor"
        assert note.data["reason"] == "Congé"

    def test_by_admin_both_are_told_and_the_reason_is_kept(self, book, patient, doctor, admin_user):
        appointment = book()
        Notification.objects.all().delete()
        services.cancel(appointment, actor=admin_user, reason="Panne\n  de   courant")
        notes = Notification.objects.all()
        assert {n.user for n in notes} == {patient, doctor}
        assert all(n.data["cancelled_by"] == "admin" for n in notes)
        assert {n.data["reason"] for n in notes} == {"Panne de courant"}  # one line

    def test_deactivating_a_patient_notifies_each_cancellation(
        self, book, make_appointment, patient, doctor, admin_user
    ):
        book(10)
        make_appointment(timedelta(days=4))
        Notification.objects.all().delete()
        account_services.set_user_active(patient, False, by=admin_user)
        notes = Notification.objects.all()
        assert notes.count() == 4  # patient + doctor, for each of the two appointments
        assert {n.data["cancelled_by"] for n in notes} == {"admin"}
        assert all("reason" not in n.data for n in notes)  # automatic cancels carry none
        assert {n.user for n in notes} == {patient, doctor}
        assert not Appointment.objects.filter(status="confirmed").exists()

    def test_deactivating_a_doctor_cancels_and_notifies_both_sides(
        self, book, make_appointment, patient, doctor, admin_user
    ):
        first = book(10)
        later = make_appointment(timedelta(days=4))
        Notification.objects.all().delete()
        account_services.set_user_active(doctor, False, by=admin_user)
        for appointment in (first, later):
            appointment.refresh_from_db()
            assert appointment.status == "cancelled"
            assert appointment.cancelled_by_id == admin_user.pk
        notes = Notification.objects.all()
        assert notes.count() == 4
        assert {n.user for n in notes} == {patient, doctor}
        assert {n.data["cancelled_by"] for n in notes} == {"admin"}
        assert all("reason" not in n.data for n in notes)

    def test_unknown_actor_is_treated_as_the_clinic(self, book, patient, doctor):
        appointment = book()
        Notification.objects.all().delete()
        appointment.cancelled_by = None
        appointment.status = "cancelled"
        appointment_event.send(sender=Appointment, appointment=appointment, event="cancelled")
        assert Notification.objects.count() == 2
        assert {n.data["cancelled_by"] for n in Notification.objects.all()} == {"admin"}
