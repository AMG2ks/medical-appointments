"""Signals other apps (notifications) listen to."""

from django.dispatch import Signal

# Sent with `appointment=<Appointment>` and `event="confirmed" | "cancelled"`, with
# `sender=Appointment`, INSIDE the booking / cancellation transaction. Receivers run in that
# transaction: they may create rows (outbox), and an exception they raise rolls the booking
# back. `automatic=True` is also passed for the cancels made by an account deactivation
# (patient or doctor); manual cancels pass nothing. Do slow work (email) later, not in the
# receiver. complete / no-show send nothing.
appointment_event = Signal()

EVENT_CONFIRMED = "confirmed"
EVENT_CANCELLED = "cancelled"
