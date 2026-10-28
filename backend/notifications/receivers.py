from . import services


def on_appointment_event(sender, appointment, event, **kwargs):
    """Runs INSIDE the booking / cancellation transaction (and, for a patient deactivation,
    inside the deactivation transaction): a raise would roll that back, so it only writes
    outbox rows, idempotently, and never sends anything."""
    services.record_appointment_event(appointment, event, automatic=bool(kwargs.get("automatic")))
