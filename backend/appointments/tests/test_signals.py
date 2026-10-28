"""`appointment_event` is sent INSIDE the booking / cancellation transaction."""

from datetime import timedelta

import pytest
from django.db import connection

from appointments import services
from appointments.models import Appointment
from appointments.signals import appointment_event
from core.exceptions import BusinessError

from .conftest import DAY, NOW, at


@pytest.fixture
def received():
    events = []

    def receiver(sender, appointment, event, **kwargs):
        events.append((event, appointment.pk, appointment.status, connection.in_atomic_block))

    appointment_event.connect(receiver, weak=False)
    yield events
    appointment_event.disconnect(receiver)


@pytest.mark.django_db(transaction=True)
class TestSignal:
    def test_confirmed_is_sent_inside_the_transaction(self, patient, profile, received):
        appointment = services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10))
        # in_atomic_block is only true here if the receiver ran in book()'s own transaction
        # (the test itself is not wrapped in one).
        assert received == [("confirmed", appointment.pk, "confirmed", True)]
        assert not connection.in_atomic_block

    def test_a_failing_receiver_rolls_the_booking_back(self, patient, profile):
        def boom(sender, **kwargs):
            raise RuntimeError("outbox down")

        appointment_event.connect(boom, weak=False)
        try:
            with pytest.raises(RuntimeError):
                services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10))
        finally:
            appointment_event.disconnect(boom)
        assert Appointment.objects.count() == 0

    def test_not_sent_when_the_booking_fails(self, patient, other_patient, profile, received):
        services.book(patient=other_patient, doctor_id=profile.pk, start_at=at(DAY, 10))
        received.clear()
        with pytest.raises(BusinessError):  # slot_taken
            services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10))
        with pytest.raises(BusinessError):  # slot_not_available
            services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 14))
        assert received == []

    def test_cancelled_is_sent_inside_the_transaction(
        self, patient, profile, make_appointment, received
    ):
        appointment = make_appointment(at(DAY, 10))
        services.cancel(appointment, actor=patient, reason="x")
        assert received == [("cancelled", appointment.pk, "cancelled", True)]

    def test_not_sent_when_the_cancellation_fails(
        self, patient, profile, make_appointment, received
    ):
        too_late = make_appointment(NOW + timedelta(hours=2))
        with pytest.raises(BusinessError):
            services.cancel(too_late, actor=patient)
        done = make_appointment(at(DAY, 10), status="completed")
        with pytest.raises(BusinessError):
            services.cancel(done, actor=patient)
        assert received == []

    def test_complete_and_no_show_send_nothing(self, doctor, profile, make_appointment, received):
        services.complete(make_appointment(NOW - timedelta(hours=1)), actor=doctor)
        services.mark_no_show(make_appointment(NOW - timedelta(hours=2)), actor=doctor)
        assert received == []
