"""Real concurrency against Postgres: threads with their own connections and transactions."""

import threading

import pytest
from django.db import connections

from appointments import services
from appointments.models import Appointment
from appointments.signals import appointment_event
from core.exceptions import BusinessError
from doctors import services as doctors_services
from doctors.models import TimeOff

from .conftest import DAY, at

TIMEOUT = 10


def run_in_thread(results, key, func):
    def target():
        try:
            results[key] = func()
        except Exception as exc:  # noqa: BLE001 - the test inspects what each thread raised
            results[key] = exc
        finally:
            connections.close_all()

    thread = threading.Thread(target=target)
    thread.start()
    return thread


@pytest.mark.django_db(transaction=True)
class TestDoubleBooking:
    def test_many_patients_racing_for_one_slot_yield_exactly_one_booking(
        self, patient, other_patient, profile, django_user_model
    ):
        from accounts.models import User

        racers = [patient, other_patient] + [
            User.objects.create_user(f"racer{i}@example.com", "x", role=User.Role.PATIENT)
            for i in range(4)
        ]
        barrier = threading.Barrier(len(racers))
        results: dict = {}

        def attempt(user):
            def go():
                barrier.wait(TIMEOUT)
                return services.book(patient=user, doctor_id=profile.pk, start_at=at(DAY, 10))

            return go

        threads = [run_in_thread(results, user.pk, attempt(user)) for user in racers]
        for thread in threads:
            thread.join(TIMEOUT * 2)

        outcomes = list(results.values())
        winners = [o for o in outcomes if isinstance(o, Appointment)]
        losers = [o for o in outcomes if isinstance(o, BusinessError)]
        assert len(outcomes) == len(racers)
        assert len(winners) == 1, outcomes
        assert len(losers) == len(racers) - 1
        assert {e.detail.code for e in losers} == {"slot_taken"}
        assert {e.status_code for e in losers} == {409}
        assert Appointment.objects.filter(status="confirmed").count() == 1

    def test_the_second_booking_waits_for_the_first_to_commit(
        self, patient, other_patient, profile
    ):
        """A is paused inside its transaction (row inserted, lock held); B must block on the
        doctor row and, once A commits, fail with slot_taken instead of double booking."""
        a_inside, release = threading.Event(), threading.Event()
        b_started = threading.Event()

        def pause(sender, appointment, **kwargs):
            if appointment.patient_id == patient.pk:
                a_inside.set()
                release.wait(TIMEOUT)

        appointment_event.connect(pause, weak=False)
        results: dict = {}
        try:
            t_a = run_in_thread(
                results,
                "a",
                lambda: services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10)),
            )
            assert a_inside.wait(TIMEOUT)

            def second():
                b_started.set()
                return services.book(
                    patient=other_patient, doctor_id=profile.pk, start_at=at(DAY, 10)
                )

            t_b = run_in_thread(results, "b", second)
            assert b_started.wait(TIMEOUT)
            t_b.join(0.5)
            assert t_b.is_alive(), "B should be blocked on the doctor row lock"
            release.set()
            t_a.join(TIMEOUT)
            t_b.join(TIMEOUT)
        finally:
            release.set()
            appointment_event.disconnect(pause)

        assert isinstance(results["a"], Appointment)
        assert isinstance(results["b"], BusinessError) and results["b"].detail.code == "slot_taken"
        assert Appointment.objects.count() == 1


@pytest.mark.django_db(transaction=True)
def test_time_off_waits_for_an_in_flight_booking_then_conflicts(patient, profile):
    """Booking and time off both take the doctor-row lock: the time off cannot be created
    around a booking that is not committed yet."""
    a_inside, release = threading.Event(), threading.Event()

    def pause(sender, **kwargs):
        a_inside.set()
        release.wait(TIMEOUT)

    appointment_event.connect(pause, weak=False)
    results: dict = {}
    try:
        t_book = run_in_thread(
            results,
            "book",
            lambda: services.book(patient=patient, doctor_id=profile.pk, start_at=at(DAY, 10)),
        )
        assert a_inside.wait(TIMEOUT)
        t_off = run_in_thread(
            results,
            "off",
            lambda: doctors_services.create_time_off(
                profile, start_at=at(DAY, 9), end_at=at(DAY, 12)
            ),
        )
        t_off.join(0.5)
        assert t_off.is_alive(), "the time off should wait for the doctor row lock"
        release.set()
        t_book.join(TIMEOUT)
        t_off.join(TIMEOUT)
    finally:
        release.set()
        appointment_event.disconnect(pause)

    assert isinstance(results["book"], Appointment)
    assert isinstance(results["off"], BusinessError)
    assert results["off"].detail.code == "time_off_conflict"
    assert TimeOff.objects.count() == 0
