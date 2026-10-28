"""Per-patient booking limits and the throttle, extreme dates, admin, deactivation."""

import threading
from datetime import time, timedelta

import pytest
from django.contrib import admin as django_admin
from django.db import connections
from rest_framework.throttling import ScopedRateThrottle

from accounts import services as accounts_services
from accounts.models import User
from appointments import services
from appointments.admin import AppointmentAdmin
from appointments.models import Appointment
from appointments.signals import appointment_event
from core.exceptions import BusinessError
from doctors.models import DoctorProfile, WeeklyAvailability

from .conftest import APPOINTMENTS, DAY, NOW, SLOTS, at, code
from .test_booking import book


def make_doctor(email, specialty):
    user = User.objects.create_user(email, "x", first_name="D", last_name=email[:3], role="doctor")
    profile = DoctorProfile.objects.create(user=user, specialty=specialty)
    WeeklyAvailability.objects.bulk_create(
        WeeklyAvailability(doctor=profile, weekday=d, start_time=time(9), end_time=time(12))
        for d in range(7)
    )
    return profile


@pytest.mark.django_db
class TestBookingLimits:
    def test_one_upcoming_appointment_per_doctor(self, auth_client, patient, profile):
        client = auth_client(patient)
        assert book(client, profile, at(DAY, 10)).status_code == 201
        response = book(client, profile, at(DAY + timedelta(days=1), 10))
        assert response.status_code == 409
        assert code(response) == "booking_limit_reached"
        assert response.data["error"]["details"] == {"reason": "same_doctor"}

    def test_a_past_or_cancelled_appointment_does_not_count(
        self, auth_client, patient, profile, make_appointment
    ):
        make_appointment(NOW - timedelta(days=2))  # started: not upcoming
        make_appointment(at(DAY, 9), status="cancelled")
        assert book(auth_client(patient), profile, at(DAY, 10)).status_code == 201

    def test_no_overlap_with_my_own_appointments_with_another_doctor(
        self, auth_client, patient, profile, specialty
    ):
        other = make_doctor("o1@example.com", specialty)
        client = auth_client(patient)
        assert book(client, profile, at(DAY, 10)).status_code == 201
        response = book(client, other, at(DAY, 10))
        assert code(response) == "booking_limit_reached"
        assert response.data["error"]["details"] == {"reason": "overlap"}
        assert book(client, other, at(DAY, 10, 30)).status_code == 201

    def test_at_most_n_upcoming(self, auth_client, patient, specialty, settings):
        settings.MAX_UPCOMING_APPOINTMENTS_PER_PATIENT = 2
        doctors = [make_doctor(f"d{i}@example.com", specialty) for i in range(3)]
        client = auth_client(patient)
        assert book(client, doctors[0], at(DAY, 9)).status_code == 201
        assert book(client, doctors[1], at(DAY, 10)).status_code == 201
        response = book(client, doctors[2], at(DAY, 11))
        assert response.status_code == 409
        assert response.data["error"]["details"] == {"reason": "max_upcoming"}
        # cancelling frees the quota
        first = Appointment.objects.filter(patient=patient).first()
        assert client.post(f"{APPOINTMENTS}{first.pk}/cancel/").status_code == 200
        assert book(client, doctors[2], at(DAY, 11)).status_code == 201

    def test_limits_are_per_patient(self, auth_client, patient, other_patient, profile, specialty):
        assert book(auth_client(patient), profile, at(DAY, 10)).status_code == 201
        assert book(auth_client(other_patient), profile, at(DAY, 10, 30)).status_code == 201


@pytest.mark.django_db(transaction=True)
def test_a_patient_booking_several_doctors_in_parallel_cannot_exceed_the_cap(
    patient, specialty, settings
):
    """The doctor lock does not serialize one patient across doctors: the patient-row lock does."""
    settings.MAX_UPCOMING_APPOINTMENTS_PER_PATIENT = 1
    doctors = [make_doctor(f"p{i}@example.com", specialty) for i in range(4)]
    barrier = threading.Barrier(len(doctors))
    results: dict = {}

    def attempt(index, doctor):
        try:
            barrier.wait(10)
            results[index] = services.book(
                patient=patient, doctor_id=doctor.pk, start_at=at(DAY + timedelta(days=index), 10)
            )
        except Exception as exc:  # noqa: BLE001 - inspected below
            results[index] = exc
        finally:
            connections.close_all()

    threads = [threading.Thread(target=attempt, args=(i, d)) for i, d in enumerate(doctors)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(20)
    winners = [r for r in results.values() if isinstance(r, Appointment)]
    losers = [r for r in results.values() if isinstance(r, BusinessError)]
    assert len(winners) == 1, results
    assert len(losers) == 3 and {e.detail.code for e in losers} == {"booking_limit_reached"}
    assert Appointment.objects.filter(patient=patient).count() == 1


@pytest.mark.django_db
class TestExtremeDates:
    @pytest.mark.parametrize("day", ["0001-01-01", "9999-12-31"])
    def test_slots(self, auth_client, patient, profile, day):
        response = auth_client(patient).get(SLOTS, {"doctor": profile.pk, "date": day})
        assert response.status_code == 200
        assert response.data["slots"] == []

    @pytest.mark.parametrize("day", ["0001-01-01", "9999-12-31"])
    def test_list_date_filter(self, auth_client, patient, day):
        response = auth_client(patient).get(APPOINTMENTS, {"date": day})
        assert response.status_code in (200, 400)
        if response.status_code == 400:
            assert response.data["error"]["fields"]["date"][0]["code"] == "invalid"

    @pytest.mark.parametrize(
        "start", ["0001-01-01T00:00:00+01:00", "0001-01-01T00:00:00", "9999-12-31T23:59:59-05:00"]
    )
    def test_booking(self, auth_client, patient, profile, start):
        response = auth_client(patient).post(
            APPOINTMENTS, {"doctor": profile.pk, "start_at": start}, format="json"
        )
        assert response.status_code == 400
        assert code(response) in ("slot_not_available", "validation_error")


@pytest.mark.django_db
def test_writes_are_throttled_reads_are_not(auth_client, patient, profile, monkeypatch):
    monkeypatch.setattr(ScopedRateThrottle, "THROTTLE_RATES", {"appointment_write": "2/hour"})
    client = auth_client(patient)
    for _ in range(2):
        assert book(client, profile, at(DAY, 10)).status_code in (201, 409)
    assert book(client, profile, at(DAY, 10)).status_code == 429
    assert client.get(APPOINTMENTS).status_code == 200
    assert client.post(f"{APPOINTMENTS}1/cancel/").status_code == 429


def test_admin_is_read_only(rf, admin_user):
    model_admin = AppointmentAdmin(Appointment, django_admin.site)
    request = rf.get("/")
    request.user = admin_user
    assert not model_admin.has_add_permission(request)
    assert not model_admin.has_change_permission(request)
    assert not model_admin.has_delete_permission(request)
    assert "patient" in model_admin.raw_id_fields


@pytest.mark.django_db
class TestDeactivation:
    def test_future_confirmed_appointments_are_cancelled_by_the_admin(
        self, auth_client, admin_user, patient, other_patient, profile, make_appointment
    ):
        future = make_appointment(at(DAY, 10))
        later = make_appointment(at(DAY + timedelta(days=1), 10))
        done = make_appointment(NOW - timedelta(days=1), status="completed")
        started = make_appointment(NOW - timedelta(minutes=5))
        done_cancelled = make_appointment(at(DAY, 11), status="cancelled")
        others = make_appointment(at(DAY, 11, 30), patient_=other_patient)
        events = []

        def receiver(sender, appointment, event, **kwargs):
            events.append((appointment.pk, event, appointment.cancelled_by_id))

        appointment_event.connect(receiver, weak=False)
        try:
            response = auth_client(admin_user).patch(
                f"/api/v1/users/{patient.pk}/", {"is_active": False}, format="json"
            )
        finally:
            appointment_event.disconnect(receiver)
        assert response.status_code == 200
        for appointment in (future, later):
            appointment.refresh_from_db()
            assert appointment.status == "cancelled"
            assert appointment.cancelled_by_id == admin_user.pk
            assert appointment.cancellation_reason
        for untouched, status in (
            (done, "completed"),
            (started, "confirmed"),
            (done_cancelled, "cancelled"),
            (others, "confirmed"),
        ):
            untouched.refresh_from_db()
            assert untouched.status == status
        assert done_cancelled.cancelled_by_id is None
        assert sorted(events) == sorted(
            [(future.pk, "cancelled", admin_user.pk), (later.pk, "cancelled", admin_user.pk)]
        )

    def test_slots_are_freed(
        self, auth_client, admin_user, patient, other_patient, profile, make_appointment
    ):
        make_appointment(at(DAY, 10))
        accounts_services.set_user_active(patient, False, by=admin_user)
        response = auth_client(other_patient).get(
            SLOTS, {"doctor": profile.pk, "date": DAY.isoformat()}
        )
        assert "2026-11-05T10:00:00+01:00" in [s["start_at"] for s in response.data["slots"]]

    def test_reactivating_or_deactivating_a_doctor_cancels_nothing(
        self, admin_user, doctor, patient, profile, make_appointment
    ):
        appointment = make_appointment(at(DAY, 10))
        accounts_services.set_user_active(doctor, False, by=admin_user)
        accounts_services.set_user_active(patient, True, by=admin_user)
        appointment.refresh_from_db()
        assert appointment.status == "confirmed"

    def test_a_failing_receiver_rolls_the_deactivation_back(
        self, admin_user, patient, profile, make_appointment
    ):
        appointment = make_appointment(at(DAY, 10))

        def boom(sender, **kwargs):
            raise RuntimeError("outbox down")

        appointment_event.connect(boom, weak=False)
        try:
            with pytest.raises(RuntimeError):
                accounts_services.set_user_active(patient, False, by=admin_user)
        finally:
            appointment_event.disconnect(boom)
        patient.refresh_from_db()
        appointment.refresh_from_db()
        assert patient.is_active and appointment.status == "confirmed"
