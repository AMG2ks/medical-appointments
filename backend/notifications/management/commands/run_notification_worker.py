import logging
import signal
import threading
import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db import close_old_connections

from notifications import services

logger = logging.getLogger(__name__)

PURGE_EVERY_SECONDS = 3600


class Command(BaseCommand):
    help = (
        "Notification worker: every NOTIFICATION_POLL_SECONDS creates the reminder rows that "
        "are due and sends the pending emails; about hourly purges old read notifications. "
        "Stop with Ctrl+C. --once runs a single cycle."
    )

    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true", help="run one cycle and exit")

    def handle(self, *args, once=False, **options):
        stop = threading.Event()
        if not once:
            for sig in (signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, lambda *_: stop.set())
            self.stdout.write(f"Worker started (every {settings.NOTIFICATION_POLL_SECONDS}s).")
        last_purge: float | None = None
        while not stop.is_set():
            try:
                if not once:
                    # Drop a connection the database closed (restart, idle timeout): Django
                    # reconnects on the next query. Without this a long-lived loop keeps
                    # failing. (A one-shot run starts with a fresh connection.)
                    close_old_connections()
                reminders, sent = services.run_cycle(should_stop=stop.is_set)
                if once or reminders or sent:
                    self.stdout.write(f"reminders created: {reminders}, emails sent: {sent}")
                if last_purge is None or time.monotonic() - last_purge >= PURGE_EVERY_SECONDS:
                    purged = services.purge_old()
                    last_purge = time.monotonic()
                    if purged:
                        self.stdout.write(f"purged notifications: {purged}")
            except Exception:  # keep the loop alive (DB restart, ...); the next cycle retries
                logger.exception("notification cycle failed")
                if once:
                    raise
            if once:
                break
            stop.wait(settings.NOTIFICATION_POLL_SECONDS)
        if not once:
            self.stdout.write("Worker stopped.")
