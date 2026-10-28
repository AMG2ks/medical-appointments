"""Signals other apps listen to (accounts imports nothing from them)."""

from django.dispatch import Signal

# Sent with `user=<User>` and `by=<User>` (the acting admin) right after an account was
# deactivated, INSIDE the deactivation transaction: a receiver that raises rolls the
# deactivation back. appointments cancels the patient's future appointments with it.
user_deactivated = Signal()
