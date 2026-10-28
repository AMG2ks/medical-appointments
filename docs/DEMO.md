# Demo runbook (LAN, offline)

Everything runs on the presenter's laptop: Postgres and Mailpit in containers, the Django API, the notification worker, and the Flutter app on an Android emulator or a real phone on the same network. **No internet is needed** once dependencies and images are downloaded (no CDN, no Firebase, no real SMTP, no web fonts). Rehearse once with Wi-Fi/internet off.

Related: [`../README.md`](../README.md) (first-time setup), [`TEAM_PLAN.md`](TEAM_PLAN.md) §4.7, [`modules/NOTIFICATIONS.md`](modules/NOTIFICATIONS.md).

## 0. Before the day (needs internet, once)

- [ ] `docker compose pull` (or `podman compose pull`), `pip install -r backend/requirements-dev.txt`, `flutter pub get`, an Android debug build done once (`flutter run`) so Gradle caches are filled.
- [ ] `backend/.env` exists with a real `SECRET_KEY` and `SEED_DEMO_PASSWORD` (README §2).
- [ ] The phone has USB debugging enabled (or wireless debugging) and the emulator image is installed.

## 1. Start the stack (4 terminals)

Terminal 1, containers (repo root):
```bash
docker compose up -d            # or: podman compose up -d
docker compose ps               # db must be (healthy); Mailpit UI: http://localhost:8025
```
- The database port is whatever `DB_PORT` says (README §1: e.g. `55432` when 5432 is taken), and `DATABASE_URL` in `backend/.env` must use the same port. Do not assume 5432.
- **Mailpit keeps its inbox in memory (no volume): restarting its container wipes every email.** Do not stop or restart it during a rehearsal or the demo, and do not demo the "mail server is down" scenario live (the worker would simply wait and retry; the emails of that moment are lost if Mailpit restarts).

Terminal 2, API (repo root). `backend/.env` needs a **`SECRET_KEY` of 50+ characters**: shorter or placeholder values make the backend refuse to start. Generate one:
```bash
python -c "from django.core.management.utils import get_random_secret_key as g; print(g())"
```
then:
```bash
cd backend && source .venv/bin/activate
python manage.py migrate
python manage.py seed_demo                          # safe to repeat
python manage.py runserver --insecure 0.0.0.0:8000  # 0.0.0.0: reachable from the phone
```
Check: <http://localhost:8000/api/docs/> opens (Swagger, served locally).

Terminal 3, notification worker (same venv):
```bash
cd backend && source .venv/bin/activate
python manage.py run_notification_worker            # Ctrl+C to stop; --once runs a single cycle
```
It creates reminder rows and sends the pending emails every `NOTIFICATION_POLL_SECONDS`: **emails arrive in Mailpit within that delay** (default 30 s; use 5 for the demo, see below). Without the worker nothing reaches Mailpit (booking still works, the emails wait).

Terminal 4: the app, see §2 or §3.

### Demo-friendly backend settings (`backend/.env`, restart server and worker after editing)

| Key | Demo value | Why |
|---|---|---|
| `ALLOWED_HOSTS` | add `10.0.2.2` (emulator) and the laptop LAN IP (phone) | otherwise `400 Bad Request` (DisallowedHost) |
| `NOTIFICATION_POLL_SECONDS` | `5` (default is `30`) | emails appear in Mailpit within this many seconds of the action |
| `REMINDER_MINUTES_BEFORE` | `55` (just under `BOOKING_MIN_LEAD_MINUTES=60`) | book the first free slot (>= 60 min ahead): the reminder fires 5+ minutes later instead of "tomorrow" |

Use the **same** `REMINDER_MINUTES_BEFORE` in the app's env file (§2/§3): the server uses it for the reminder email and row, the app for the on-device notification. Put them back to `1440` afterwards.

## 2. App on the Android emulator

```bash
cd mobile
cp env/emulator.json.example env/emulator.json     # once (git-ignored)
# env/emulator.json: API_BASE_URL http://10.0.2.2:8000, NOTIFICATIONS_POLL_SECONDS 5 (optional), REMINDER_MINUTES_BEFORE 55 (optional)
flutter run --dart-define-from-file=env/emulator.json
```
`10.0.2.2` is the emulator's alias for the laptop. Run the **debug** build: plain HTTP is allowed only there. `NOTIFICATIONS_POLL_SECONDS` and `REMINDER_MINUTES_BEFORE` are optional (defaults 30 / 1440).

## 3. App on a real phone (same Wi-Fi)

1. Put the phone and the laptop on the **same network**. University Wi-Fi often blocks device-to-device traffic: use the laptop's hotspot or a phone hotspot (the laptop joins it).
2. Find the laptop IP: `ip addr` (Linux) / `ipconfig` (Windows), e.g. `192.168.43.20`.
3. Add that IP to `ALLOWED_HOSTS` in `backend/.env`, restart `runserver`.
4. Allow inbound TCP 8000 in the laptop firewall (e.g. `sudo ufw allow 8000/tcp`; Windows: allow Python on private networks).
5. `cp env/device.json.example env/device.json`, set `"API_BASE_URL": "http://192.168.43.20:8000"` (and the optional keys above).
6. `flutter run --dart-define-from-file=env/device.json` with the phone connected by USB (debug build).
7. Quick check from the phone's browser: `http://<laptop IP>:8000/api/docs/` loads. If not, it is the network or the firewall, not the app.
8. The first booking asks for the **notification permission** (Android 13+): accept it. If it was refused: Settings > Apps > MedApp > Notifications.

Phone battery saver / Doze can delay the on-device reminder by a few minutes (inexact alarms, no exact-alarm permission). Keep the phone unplugged-but-awake or disable battery optimisation for MedApp for the demo.

## 4. Demo accounts

`seed_demo` creates (password = `SEED_DEMO_PASSWORD` from `backend/.env`):

| Role | Email | Language |
|---|---|---|
| Admin | `admin@medapp.local` | fr |
| Doctor | `dr.karim@medapp.local` (Karim Haddad) | fr |
| Doctor | `dr.sarah@medapp.local` (Sarah Miller) | en |
| Patient | `amira@medapp.local` (Amira Ben Salah, has appointments) | fr |
| Patient | `john@medapp.local` (John Smith) | en |

`seed_demo` never overwrites an existing demo user: a language you saved in the app (profile > language) is kept, and the app follows the **saved** language at login (the language buttons on the login screen only apply until then). Emails use the saved language too, so check it before showing a flow in French or English.

Emails (invites, confirmations, reminders...) are **not** sent to real inboxes: open Mailpit at <http://localhost:8025>.

## 5. Demo flows (TEAM_PLAN §7)

Tip: with one device, log out and log in as the next role; the other side's effects are visible in Mailpit and in the in-app list after the next poll (or pull to refresh).

1. **Admin creates a doctor.** Log in as admin (the admin shell has 5 tabs: **Dashboard** (home) / **Users** / **Doctors** / **Specialties** / **Profile**), Doctors tab > new doctor (pick a language). Mailpit: invite email in that language with a 6-digit code. In the app: Log out > Login > "Forgot password?" > **"I already have a code"** > enter the doctor's email, the code and a new password > log in as the doctor > Availability tab: add e.g. today's weekday 09:00-12:00.
2. **Patient books.** Sign up a new patient in French (or use `amira`) > Doctors > pick the doctor > Book > date > slot > confirm. Mailpit: two emails within seconds (confirmation to the patient in the patient's language, "new appointment" to the doctor in the doctor's language). Log in as the doctor: the Notifications tab shows a badge and the booking; while logged in, a snackbar appears within `NOTIFICATIONS_POLL_SECONDS` when a new one arrives.
3. **Reminders.** With the demo values of §1, after booking the first free slot: the **on-device** notification appears `REMINDER_MINUTES_BEFORE` before the start (a few minutes after booking), and the worker sends the **reminder email** at the same time (visible in Mailpit, and as a "reminder" entry in the in-app list). Cancelling the appointment removes the on-device reminder at the next sync (the list is refetched right after a cancel).
4. **Language switch and cancel.** Profile > switch to English: the notification list, dates and the on-device reminder text now follow English. Patient cancels an upcoming appointment (allowed up to `CANCELLATION_MIN_HOURS` before the start): the doctor gets the email and the in-app entry (the patient is not notified about their own cancel). Doctor cancels one with a reason: the patient is notified with the reason. Doctor opens a *past* appointment and marks it completed.
5. **Admin deactivates a user.** Admin > Users > deactivate the patient (deactivating a *doctor* does the same for the doctor's future appointments): the future appointments are cancelled ("the clinic cancelled ..." emails to the patient and the doctor), and on the patient's phone the next request returns to the login screen. Dashboard tab: counts per role and appointments (today / this week / by status), pull to refresh.

Specialties (admin): tap a row to rename it (both languages); the add button creates one; deleting one that doctors use is refused.

## 6. Offline rehearsal checklist

- [ ] Turn internet off (keep only the local network or the hotspot), then run §1 from scratch: nothing tries to download anything.
- [ ] Swagger at `/api/docs/` renders (served by the sidecar package).
- [ ] Mailpit UI loads at `localhost:8025`.
- [ ] Flows 1-5 work on the phone, in both languages.
- [ ] `python manage.py run_notification_worker --once` always prints `reminders created: N, emails sent: M` and exits.
- [ ] After the demo: `docker compose down` (keeps the data), restore `REMINDER_MINUTES_BEFORE` / `NOTIFICATION_POLL_SECONDS` if you changed them.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App says "Cannot reach the server" | wrong `API_BASE_URL`, backend not on `0.0.0.0`, firewall, or phone on another network; test `/api/docs/` from the phone browser |
| `Bad Request` / `DisallowedHost` | IP missing in `ALLOWED_HOSTS` |
| App refuses `http://` | you ran a release/profile build; use `flutter run` (debug) |
| Nothing in Mailpit | worker not running (terminal 3), or `EMAIL_HOST`/`EMAIL_PORT` do not point to Mailpit (1025) |
| An email stays pending/failed | `last_error` and `attempts` are visible in Django admin (`DJANGO_ADMIN_ENABLED=True`, Notifications); the worker retries up to `NOTIFICATION_MAX_ATTEMPTS` |
| No on-device reminder | permission refused; appointment starts sooner than `REMINDER_MINUTES_BEFORE` (no reminder is scheduled in the past); app env value differs from the one you expect; Doze delay of a few minutes |
| Badge does not move | the app is in the background (polling stops there; it refreshes on resume), or the worker is not creating the notification (booking rows are created by the API itself, no worker needed for in-app entries) |
| Port 5432/1025/8025 busy | see the README (`DB_PORT`, `MAIL_SMTP_PORT`, `MAIL_UI_PORT`) |
