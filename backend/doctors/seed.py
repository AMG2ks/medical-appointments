"""Demo specialties, doctor profiles and weekly availability (idempotent).

Runs after accounts.seed, which creates the doctor users.
"""

from datetime import time

from accounts.models import User

from .models import DoctorProfile, Specialty, WeeklyAvailability

SPECIALTIES = [
    # (name_fr, name_en)
    ("Médecine générale", "General practice"),
    ("Cardiologie", "Cardiology"),
    ("Dermatologie", "Dermatology"),
    ("Pédiatrie", "Pediatrics"),
    ("Ophtalmologie", "Ophthalmology"),
]

# email -> (specialty name_en, bio, consultation minutes, [(weekday, start, end)])
WEEKDAYS = range(0, 5)  # Monday to Friday
DEMO_DOCTORS = {
    "dr.karim@medapp.local": (
        "General practice",
        "Médecin généraliste, 12 ans d'expérience. Consultations adultes et enfants.",
        30,
        [(d, time(9), time(12)) for d in WEEKDAYS] + [(d, time(14), time(17)) for d in WEEKDAYS],
    ),
    "dr.sarah@medapp.local": (
        "Cardiology",
        "Cardiologist focused on prevention and follow-up of chronic conditions.",
        20,
        [(d, time(10), time(13)) for d in (0, 2, 4)] + [(3, time(14), time(18))],
    ),
}


def run() -> None:
    specialties = {}
    for name_fr, name_en in SPECIALTIES:
        specialties[name_en], _ = Specialty.objects.get_or_create(
            name_en=name_en, defaults={"name_fr": name_fr}
        )

    for email, (specialty, bio, minutes, windows) in DEMO_DOCTORS.items():
        user = User.objects.filter(email=email, role=User.Role.DOCTOR).first()
        if user is None:  # accounts.seed did not create it
            continue
        profile, created = DoctorProfile.objects.get_or_create(
            user=user,
            defaults={
                "specialty": specialties[specialty],
                "bio": bio,
                "consultation_minutes": minutes,
            },
        )
        if created:
            WeeklyAvailability.objects.bulk_create(
                WeeklyAvailability(doctor=profile, weekday=day, start_time=start, end_time=end)
                for day, start, end in windows
            )
