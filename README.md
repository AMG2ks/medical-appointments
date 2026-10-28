# Medical Appointments

Esprit university project: Flutter app + Django REST Framework API + PostgreSQL.
Everything runs locally; all mail is captured by Mailpit. Read [`docs/TEAM_PLAN.md`](docs/TEAM_PLAN.md) first.

> **This repo is public.** Never commit `.env` files, `mobile/env/*.json`, keys or real passwords, and never `git add -f` an ignored file.

## Prerequisites

| Tool | Notes |
|---|---|
| Git | |
| Python 3.12 | backend and `scripts/check.py` |
| Docker Engine + Compose plugin, or Podman + `podman compose` | not Docker Desktop (proprietary, see TEAM_PLAN 4.7) |
| Flutter SDK **3.29.2** (same as CI; no fvm, just use this version) + Android SDK / emulator | Android SDK is the accepted non-open-source exception |
| GNU gettext | only if you edit backend translations |

## 1. Start Postgres and Mailpit

```bash
cp backend/.env.example backend/.env     # once; the file is gitignored
# then edit backend/.env: SECRET_KEY (required) and SEED_DEMO_PASSWORD (to run seed_demo), see below
docker compose up -d                     # or: podman compose up -d
docker compose ps                        # "db" should become (healthy)
```

- PostgreSQL: `localhost:5432` (user, password and database from `backend/.env`)
- Mailpit inbox (every email sent by the app lands here): <http://localhost:8025>
- Mailpit SMTP: `localhost:1025`

If a host port is already in use, create a root-level `.env` (gitignored, read by compose, not `backend/.env`) with e.g. `DB_PORT=55432` and update the port in `DATABASE_URL`. Overridable: `DB_PORT` (5432), `MAIL_SMTP_PORT` (1025, then also `EMAIL_PORT`), `MAIL_UI_PORT` (8025).

Stop with `docker compose down` (data is kept in the `pgdata` volume). Reset the database with `docker compose down -v`.

## 2. Backend

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate                # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
python manage.py migrate
python manage.py seed_demo               # demo users (password = SEED_DEMO_PASSWORD in .env)
python manage.py runserver --insecure 0.0.0.0:8000  # 0.0.0.0 so a phone can reach it
```

- Before the first run, in `backend/.env`:
  - `SECRET_KEY` (signs the login tokens; the app refuses to start without a real one, 50+ characters). Generate it with
    `python -c "from django.core.management.utils import get_random_secret_key as g; print(g())"`. Never commit it.
  - `SEED_DEMO_PASSWORD` for `seed_demo` (`seed_demo` refuses an empty, weak or placeholder value).
  - `DEBUG=False` is the default in `.env.example`. Django then does not serve static files by itself, so run
    `runserver --insecure` (dev only) to get the Swagger UI files at `/api/docs/`.
- API docs (Swagger, works offline): <http://localhost:8000/api/docs/>
- Django admin (`/admin/`) is **off by default**: set `DJANGO_ADMIN_ENABLED=True` in `backend/.env` when you need it, and turn it back off afterwards.
- Create an admin: `python manage.py createsuperuser`
- Demo accounts: `admin@medapp.local`, `dr.karim@medapp.local`, `dr.sarah@medapp.local`, `amira@medapp.local`, `john@medapp.local`
- Notification worker (second terminal; creates reminders and sends the emails to Mailpit): `python manage.py run_notification_worker`. LAN demo runbook: [`docs/DEMO.md`](docs/DEMO.md)
- Translations (needs GNU gettext): `python manage.py makemessages -l fr`, then `python manage.py compilemessages`; commit the `.po` **and** `.mo`.
- Tests: `pytest` (needs the Postgres container running).

## 3. Mobile

```bash
cd mobile
flutter pub get
flutter gen-l10n                                     # generates AppLocalizations from lib/l10n/*.arb
cp env/emulator.json.example env/emulator.json       # once; env/*.json is gitignored
flutter run --dart-define-from-file=env/emulator.json
# physical phone: cp env/device.json.example env/device.json, put your laptop IP in it, then
# flutter run --dart-define-from-file=env/device.json
```

Use a **debug** build for the LAN demo: plain HTTP is allowed only in the debug manifest. UI strings live in `lib/l10n/app_en.arb` and `app_fr.arb` (every key in both).

| Target | `API_BASE_URL` | Backend `ALLOWED_HOSTS` |
|---|---|---|
| Android emulator | `http://10.0.2.2:8000` (`mobile/env/emulator.json`) | includes `10.0.2.2` |
| Physical phone (same network/hotspot) | `http://<laptop LAN IP>:8000` (`mobile/env/device.json`) | add the LAN IP |

## Quality gate

```bash
# from the repo root, with the backend virtualenv active and the containers up
python scripts/check.py
```

Runs backend `ruff check`, `ruff format --check`, `pytest`, `makemigrations --check`, then mobile ARB fr/en completeness, `flutter gen-l10n`, `dart format`, `flutter analyze`, `flutter test`. Prints PASS/FAIL per step, runs every step, exits non-zero if any failed. Backend steps are skipped until `backend/manage.py` exists, mobile steps until `mobile/pubspec.yaml` exists. Works offline. The same script runs in GitHub Actions on PRs and pushes to `main` (`.github/workflows/check.yml`). Paste its summary in your PR.
