from importlib import import_module
from importlib.util import find_spec

from django.core.management.base import BaseCommand

# Dependency order. A module without a seed.py yet is skipped.
SEED_MODULES = [
    "accounts.seed",
    "doctors.seed",
    "appointments.seed",
    "notifications.seed",
]


class Command(BaseCommand):
    help = "Create demo data (safe to run several times). Each app provides seed.run()."

    def handle(self, *args, **options):
        for name in SEED_MODULES:
            try:
                available = find_spec(name) is not None
            except ModuleNotFoundError:  # the whole app does not exist yet
                available = False
            if not available:
                self.stdout.write(f"skip {name} (not found)")
                continue
            import_module(name).run()
            self.stdout.write(self.style.SUCCESS(f"seeded {name}"))
