from datetime import timedelta

import pytest
from django.core import mail
from django.db import transaction
from django.utils import timezone

from accounts.models import PasswordResetCode, User
from doctors import services
from doctors.models import DoctorProfile, Specialty, TimeOff, WeeklyAvailability

SPECIALTIES = "/api/v1/specialties/"
DOCTORS = "/api/v1/doctors/"
ME = "/api/v1/doctors/me/"
AVAILABILITY = "/api/v1/doctors/me/availability/"
TIME_OFF = "/api/v1/doctors/me/time-off/"


def code(response):
    return response.data["error"]["code"]


def make_doctor(email, specialty, first="Zed", last="Alpha", active=True):
    user = User.objects.create_user(
        email, "x", first_name=first, last_name=last, role=User.Role.DOCTOR, is_active=active
    )
    return DoctorProfile.objects.create(user=user, specialty=specialty)


# --- specialties ---


@pytest.mark.django_db
class TestSpecialties:
    def test_anonymous_is_401(self, api_client):
        assert api_client.get(SPECIALTIES).status_code == 401

    def test_any_logged_in_user_lists_with_both_names(self, auth_client, patient, specialty):
        response = auth_client(patient).get(SPECIALTIES)
        assert response.status_code == 200
        assert response.data["results"] == [
            {"id": specialty.id, "name_fr": "Cardiologie", "name_en": "Cardiology"}
        ]

    @pytest.mark.parametrize("who", ["patient", "doctor"])
    def test_write_requires_admin(self, auth_client, request, who, specialty):
        client = auth_client(request.getfixturevalue(who))
        body = {"name_fr": "Dermatologie", "name_en": "Dermatology"}
        assert client.post(SPECIALTIES, body, format="json").status_code == 403
        assert client.patch(f"{SPECIALTIES}{specialty.id}/", body, format="json").status_code == 403
        assert client.delete(f"{SPECIALTIES}{specialty.id}/").status_code == 403

    def test_admin_crud(self, auth_client, admin_user):
        client = auth_client(admin_user)
        created = client.post(
            SPECIALTIES, {"name_fr": "Pédiatrie", "name_en": "Pediatrics"}, format="json"
        )
        assert created.status_code == 201
        url = f"{SPECIALTIES}{created.data['id']}/"
        assert (
            client.patch(url, {"name_en": "Paediatrics"}, format="json").data["name_en"]
            == "Paediatrics"
        )
        assert client.delete(url).status_code == 204
        assert not Specialty.objects.filter(pk=created.data["id"]).exists()

    def test_validation_and_unique(self, auth_client, admin_user, specialty):
        client = auth_client(admin_user)
        response = client.post(
            SPECIALTIES, {"name_fr": "Cardiologie", "name_en": ""}, format="json"
        )
        assert response.status_code == 400
        assert code(response) == "validation_error"
        fields = response.data["error"]["fields"]
        assert fields["name_fr"][0]["code"] == "unique"
        assert fields["name_en"][0]["code"] == "blank"

    def test_delete_in_use_is_409(self, auth_client, admin_user, doctor, specialty):
        response = auth_client(admin_user).delete(f"{SPECIALTIES}{specialty.id}/")
        assert response.status_code == 409
        assert code(response) == "specialty_in_use"
        assert Specialty.objects.filter(pk=specialty.pk).exists()

    def test_patch_unknown_is_404(self, auth_client, admin_user):
        assert (
            auth_client(admin_user).patch(f"{SPECIALTIES}999/", {}, format="json").status_code
            == 404
        )


# --- doctors list / detail ---


@pytest.mark.django_db
class TestDoctorList:
    def test_anonymous_is_401(self, api_client):
        assert api_client.get(DOCTORS).status_code == 401

    def test_paginated_public_card_without_contact_data(
        self, auth_client, patient, doctor, specialty
    ):
        response = auth_client(patient).get(DOCTORS)
        assert response.status_code == 200
        assert set(response.data) == {"count", "next", "previous", "results"}
        assert response.data["results"] == [
            {
                "id": doctor.id,
                "first_name": "Doc",
                "last_name": "Tor",
                "specialty": {
                    "id": specialty.id,
                    "name_fr": "Cardiologie",
                    "name_en": "Cardiology",
                },
                "bio": "",
                "consultation_minutes": 30,
                "invite_pending": False,
            }
        ]

    def test_inactive_doctors_are_hidden(self, auth_client, patient, doctor, specialty):
        hidden = make_doctor("off@example.com", specialty, active=False)
        client = auth_client(patient)
        assert client.get(DOCTORS).data["count"] == 1
        assert client.get(f"{DOCTORS}{hidden.pk}/").status_code == 404

    def test_filter_by_specialty_and_search(self, auth_client, patient, doctor, specialty):
        derm = Specialty.objects.create(name_fr="Dermatologie", name_en="Dermatology")
        other = make_doctor("amira@example.com", derm, first="Amira", last="Zouari")
        client = auth_client(patient)
        assert [d["id"] for d in client.get(DOCTORS, {"specialty": derm.id}).data["results"]] == [
            other.pk
        ]
        assert client.get(DOCTORS, {"search": "zoua"}).data["count"] == 1
        assert (
            client.get(DOCTORS, {"search": "AMIRA", "specialty": specialty.id}).data["count"] == 0
        )
        assert client.get(DOCTORS, {"specialty": "abc"}).status_code == 400

    def test_detail(self, auth_client, patient, doctor):
        response = auth_client(patient).get(f"{DOCTORS}{doctor.id}/")
        assert response.status_code == 200
        assert response.data["id"] == doctor.id
        assert "email" not in response.data

    def test_detail_unknown_is_404(self, auth_client, patient):
        response = auth_client(patient).get(f"{DOCTORS}999/")
        assert response.status_code == 404
        assert code(response) == "not_found"


# --- admin creates a doctor ---


@pytest.mark.django_db
class TestCreateDoctor:
    def body(self, specialty, **extra):
        return {
            "email": "New.Doc@Example.com",
            "first_name": "New",
            "last_name": "Doc",
            "specialty_id": specialty.id,
            "preferred_language": "en",
            **extra,
        }

    def test_admin_creates_doctor_and_invite_is_sent(
        self, auth_client, admin_user, specialty, django_capture_on_commit_callbacks
    ):
        with django_capture_on_commit_callbacks(execute=True):
            response = auth_client(admin_user).post(
                DOCTORS, self.body(specialty, bio="Hi", consultation_minutes=20), format="json"
            )
        assert response.status_code == 201
        assert response.data["email"] == "new.doc@example.com"
        assert response.data["consultation_minutes"] == 20
        user = User.objects.get(email="new.doc@example.com")
        assert user.role == User.Role.DOCTOR
        assert user.preferred_language == "en"
        assert not user.has_usable_password()
        assert user.doctor_profile.specialty_id == specialty.id
        assert PasswordResetCode.objects.get(user=user).purpose == "invite"
        assert [m.to for m in mail.outbox] == [["new.doc@example.com"]]

    def test_invite_not_sent_when_creation_rolls_back(
        self, specialty, django_capture_on_commit_callbacks
    ):
        data = {
            "email": "rb@example.com",
            "first_name": "R",
            "last_name": "B",
            "specialty": specialty,
        }
        with django_capture_on_commit_callbacks(execute=True) as callbacks:
            with pytest.raises(RuntimeError), transaction.atomic():
                services.create_doctor(data=data)
                raise RuntimeError("outer transaction fails after the doctor was created")
        assert callbacks == []  # the invite was registered, then discarded by the rollback
        assert not User.objects.filter(email="rb@example.com").exists()
        assert mail.outbox == []

    def test_mail_failure_after_commit_still_returns_201(
        self, auth_client, admin_user, specialty, monkeypatch, django_capture_on_commit_callbacks
    ):
        def smtp_down(*args, **kwargs):
            raise OSError("smtp down")

        monkeypatch.setattr("accounts.services.send_mail", smtp_down)
        with django_capture_on_commit_callbacks(execute=True):
            response = auth_client(admin_user).post(DOCTORS, self.body(specialty), format="json")
        assert response.status_code == 201
        assert DoctorProfile.objects.filter(user__email="new.doc@example.com").exists()

    def test_duplicate_email_race_is_a_unique_error(
        self, auth_client, admin_user, specialty, doctor, monkeypatch
    ):
        # Both requests passed the serializer check; the DB constraint decides.
        monkeypatch.setattr(
            "doctors.serializers.CreateDoctorSerializer.validate_email", lambda self, v: v.lower()
        )
        response = auth_client(admin_user).post(
            DOCTORS, self.body(specialty, email=doctor.email.upper()), format="json"
        )
        assert response.status_code == 400
        assert code(response) == "validation_error"
        assert response.data["error"]["fields"]["email"][0]["code"] == "unique"

    def test_bio_is_length_limited(self, auth_client, admin_user, specialty):
        response = auth_client(admin_user).post(
            DOCTORS, self.body(specialty, bio="x" * 2001), format="json"
        )
        assert response.status_code == 400
        assert response.data["error"]["fields"]["bio"][0]["code"] == "max_length"

    @pytest.mark.parametrize("who", ["patient", "doctor"])
    def test_non_admin_is_403(self, auth_client, request, who, specialty):
        response = auth_client(request.getfixturevalue(who)).post(
            DOCTORS, self.body(specialty), format="json"
        )
        assert response.status_code == 403
        assert code(response) == "permission_denied"

    def test_anonymous_is_401(self, api_client, specialty):
        assert api_client.post(DOCTORS, self.body(specialty), format="json").status_code == 401

    def test_validation_errors(
        self, auth_client, admin_user, doctor, django_capture_on_commit_callbacks
    ):
        with django_capture_on_commit_callbacks(execute=True) as callbacks:
            response = self._post_invalid(auth_client, admin_user, doctor)
        assert callbacks == []  # nothing was even registered for sending
        assert mail.outbox == []
        self._check_invalid(response)

    def _post_invalid(self, auth_client, admin_user, doctor):
        return auth_client(admin_user).post(
            DOCTORS,
            {
                "email": doctor.email,
                "first_name": "",
                "specialty_id": 999,
                "consultation_minutes": 1,
            },
            format="json",
        )

    def _check_invalid(self, response):
        assert response.status_code == 400
        fields = response.data["error"]["fields"]
        assert fields["email"][0]["code"] == "unique"
        assert fields["first_name"][0]["code"] == "blank"
        assert fields["last_name"][0]["code"] == "required"
        assert fields["specialty_id"][0]["code"] == "does_not_exist"
        assert fields["consultation_minutes"][0]["code"] == "min_value"


# --- my profile ---


@pytest.mark.django_db
class TestMe:
    def test_roles(self, api_client, auth_client, patient, admin_user):
        assert api_client.get(ME).status_code == 401
        assert auth_client(patient).get(ME).status_code == 403
        assert auth_client(admin_user).patch(ME, {}, format="json").status_code == 403

    def test_get_includes_private_fields(self, auth_client, doctor):
        response = auth_client(doctor).get(ME)
        assert response.status_code == 200
        assert response.data["email"] == doctor.email
        assert response.data["id"] == doctor.id

    def test_patch_professional_fields(self, auth_client, doctor):
        derm = Specialty.objects.create(name_fr="Dermatologie", name_en="Dermatology")
        response = auth_client(doctor).patch(
            ME,
            {"bio": "New bio", "consultation_minutes": 45, "specialty_id": derm.id},
            format="json",
        )
        assert response.status_code == 200
        assert response.data["specialty"]["name_en"] == "Dermatology"
        profile = DoctorProfile.objects.get(pk=doctor.pk)
        assert (profile.bio, profile.consultation_minutes, profile.specialty_id) == (
            "New bio",
            45,
            derm.id,
        )

    def test_cannot_change_identity_fields(self, auth_client, doctor):
        auth_client(doctor).patch(
            ME, {"first_name": "X", "email": "x@x.com", "id": 99}, format="json"
        )
        doctor.refresh_from_db()
        assert (doctor.first_name, doctor.email) == ("Doc", "doctor@example.com")

    @pytest.mark.parametrize("minutes", [0, 4, 241])
    def test_consultation_minutes_range(self, auth_client, doctor, minutes):
        response = auth_client(doctor).patch(ME, {"consultation_minutes": minutes}, format="json")
        assert response.status_code == 400
        assert code(response) == "validation_error"

    def test_doctor_user_without_profile_is_404(self, auth_client, db):
        user = User.objects.create_user("np@example.com", "x", role=User.Role.DOCTOR)
        assert auth_client(user).get(ME).status_code == 404


# --- availability ---


@pytest.mark.django_db
class TestAvailability:
    def test_roles(self, api_client, auth_client, patient, admin_user):
        assert api_client.get(AVAILABILITY).status_code == 401
        assert auth_client(patient).get(AVAILABILITY).status_code == 403
        assert auth_client(admin_user).post(AVAILABILITY, {}, format="json").status_code == 403

    def test_create_list_update_delete(self, auth_client, doctor):
        client = auth_client(doctor)
        body = {"weekday": 0, "start_time": "09:00", "end_time": "12:00"}
        created = client.post(AVAILABILITY, body, format="json")
        assert created.status_code == 201
        assert created.data == {
            "id": created.data["id"],
            "weekday": 0,
            "start_time": "09:00:00",
            "end_time": "12:00:00",
        }
        assert client.get(AVAILABILITY).data["results"] == [created.data]

        url = f"{AVAILABILITY}{created.data['id']}/"
        updated = client.patch(url, {"end_time": "13:00"}, format="json")
        assert updated.status_code == 200
        assert updated.data["end_time"] == "13:00:00"
        assert client.delete(url).status_code == 204
        assert client.get(AVAILABILITY).data["count"] == 0

    def test_overlap_is_rejected_with_code(self, auth_client, doctor):
        client = auth_client(doctor)
        client.post(
            AVAILABILITY, {"weekday": 0, "start_time": "09:00", "end_time": "12:00"}, format="json"
        )
        response = client.post(
            AVAILABILITY, {"weekday": 0, "start_time": "11:00", "end_time": "13:00"}, format="json"
        )
        assert response.status_code == 400
        assert code(response) == "availability_overlap"
        # touching and other weekdays are fine
        assert (
            client.post(
                AVAILABILITY,
                {"weekday": 0, "start_time": "12:00", "end_time": "13:00"},
                format="json",
            ).status_code
            == 201
        )
        assert (
            client.post(
                AVAILABILITY,
                {"weekday": 1, "start_time": "11:00", "end_time": "13:00"},
                format="json",
            ).status_code
            == 201
        )

    def test_patch_into_overlap_is_rejected(self, auth_client, doctor):
        client = auth_client(doctor)
        client.post(
            AVAILABILITY, {"weekday": 0, "start_time": "09:00", "end_time": "12:00"}, format="json"
        )
        second = client.post(
            AVAILABILITY, {"weekday": 0, "start_time": "14:00", "end_time": "16:00"}, format="json"
        )
        response = client.patch(
            f"{AVAILABILITY}{second.data['id']}/", {"start_time": "11:00"}, format="json"
        )
        assert response.status_code == 400
        assert code(response) == "availability_overlap"
        assert (
            client.patch(
                f"{AVAILABILITY}{second.data['id']}/", {"weekday": 3}, format="json"
            ).status_code
            == 200
        )

    def test_other_doctors_overlap_does_not_matter(self, auth_client, doctor, specialty):
        other = make_doctor("o@example.com", specialty)
        WeeklyAvailability.objects.create(
            doctor=other, weekday=0, start_time="09:00", end_time="12:00"
        )
        response = auth_client(doctor).post(
            AVAILABILITY, {"weekday": 0, "start_time": "09:00", "end_time": "12:00"}, format="json"
        )
        assert response.status_code == 201

    @pytest.mark.parametrize(
        "body, field, field_code",
        [
            ({"weekday": 7, "start_time": "09:00", "end_time": "10:00"}, "weekday", "max_value"),
            ({"weekday": -1, "start_time": "09:00", "end_time": "10:00"}, "weekday", "min_value"),
            ({"weekday": 0, "start_time": "10:00", "end_time": "10:00"}, "end_time", "invalid"),
            ({"weekday": 0, "start_time": "11:00", "end_time": "10:00"}, "end_time", "invalid"),
            ({"weekday": 0, "start_time": "nope", "end_time": "10:00"}, "start_time", "invalid"),
            ({"weekday": 0, "end_time": "10:00"}, "start_time", "required"),
        ],
    )
    def test_validation(self, auth_client, doctor, body, field, field_code):
        response = auth_client(doctor).post(AVAILABILITY, body, format="json")
        assert response.status_code == 400
        assert code(response) == "validation_error"
        assert response.data["error"]["fields"][field][0]["code"] == field_code

    def test_cannot_touch_another_doctors_row(self, auth_client, doctor, specialty):
        other = make_doctor("o@example.com", specialty)
        row = WeeklyAvailability.objects.create(
            doctor=other, weekday=0, start_time="09:00", end_time="12:00"
        )
        client = auth_client(doctor)
        assert (
            client.patch(
                f"{AVAILABILITY}{row.id}/", {"end_time": "10:00"}, format="json"
            ).status_code
            == 404
        )
        assert client.delete(f"{AVAILABILITY}{row.id}/").status_code == 404
        assert WeeklyAvailability.objects.filter(pk=row.pk).exists()


# --- time off ---


@pytest.mark.django_db
class TestTimeOff:
    def body(self, **extra):
        start = timezone.now() + timedelta(days=1)
        return {
            "start_at": start.isoformat(),
            "end_at": (start + timedelta(days=2)).isoformat(),
            **extra,
        }

    def test_roles(self, api_client, auth_client, patient, admin_user):
        assert api_client.get(TIME_OFF).status_code == 401
        assert auth_client(patient).get(TIME_OFF).status_code == 403
        assert auth_client(admin_user).post(TIME_OFF, self.body(), format="json").status_code == 403

    def test_create_list_delete(self, auth_client, doctor):
        client = auth_client(doctor)
        created = client.post(TIME_OFF, self.body(reason="Holidays"), format="json")
        assert created.status_code == 201
        assert created.data["reason"] == "Holidays"
        listed = client.get(TIME_OFF)
        assert listed.data["count"] == 1
        assert listed.data["results"][0]["id"] == created.data["id"]
        assert client.delete(f"{TIME_OFF}{created.data['id']}/").status_code == 204
        assert client.get(TIME_OFF).data["count"] == 0

    def test_end_must_be_after_start(self, auth_client, doctor):
        body = self.body()
        body["end_at"] = body["start_at"]
        response = auth_client(doctor).post(TIME_OFF, body, format="json")
        assert response.status_code == 400
        assert response.data["error"]["fields"]["end_at"][0]["code"] == "invalid"

    def test_required_fields(self, auth_client, doctor):
        response = auth_client(doctor).post(TIME_OFF, {}, format="json")
        assert response.data["error"]["fields"]["start_at"][0]["code"] == "required"

    def test_only_own_time_off(self, auth_client, doctor, specialty):
        other = make_doctor("o@example.com", specialty)
        now = timezone.now()
        row = TimeOff.objects.create(doctor=other, start_at=now, end_at=now + timedelta(hours=1))
        client = auth_client(doctor)
        assert client.get(TIME_OFF).data["count"] == 0
        assert client.delete(f"{TIME_OFF}{row.id}/").status_code == 404
        assert TimeOff.objects.filter(pk=row.pk).exists()


@pytest.mark.django_db
def test_fixture_doctor_has_profile(doctor):
    assert doctor.doctor_profile.pk == doctor.pk


@pytest.mark.django_db
def test_business_error_message_follows_accept_language(auth_client, doctor, specialty, admin_user):
    response = auth_client(admin_user).delete(
        f"{SPECIALTIES}{specialty.id}/", HTTP_ACCEPT_LANGUAGE="fr"
    )
    assert response.status_code == 409
    assert response.data["error"]["message"] == "Cette spécialité est utilisée par des médecins."


# --- invited-but-not-accepted doctors, role filter, search limits ---


def make_pending(email, specialty):
    """A doctor created by an admin who has not set a password yet."""
    user = User.objects.create_user(
        email, None, first_name="Pen", last_name="Ding", role=User.Role.DOCTOR
    )
    return DoctorProfile.objects.create(user=user, specialty=specialty)


@pytest.mark.django_db
class TestPendingInvite:
    def test_hidden_from_patients_and_doctors(self, auth_client, patient, doctor, specialty):
        pending = make_pending("pending@example.com", specialty)
        for viewer in (patient, doctor):
            client = auth_client(viewer)
            assert [d["id"] for d in client.get(DOCTORS).data["results"]] == [doctor.id]
            response = client.get(f"{DOCTORS}{pending.pk}/")
            assert response.status_code == 404
            assert code(response) == "not_found"

    def test_admin_sees_them_with_a_flag(self, auth_client, admin_user, doctor, specialty):
        pending = make_pending("pending@example.com", specialty)
        client = auth_client(admin_user)
        flags = {d["id"]: d["invite_pending"] for d in client.get(DOCTORS).data["results"]}
        assert flags == {doctor.id: False, pending.pk: True}
        assert client.get(f"{DOCTORS}{pending.pk}/").data["invite_pending"] is True

    def test_visible_once_the_invite_is_accepted(self, auth_client, patient, specialty):
        pending = make_pending("pending@example.com", specialty)
        pending.user.set_password("S3cure-pass!")
        pending.user.save()
        assert auth_client(patient).get(f"{DOCTORS}{pending.pk}/").status_code == 200

    def test_new_doctor_is_hidden_until_password_is_set(
        self, auth_client, admin_user, patient, specialty
    ):
        body = {
            "email": "fresh@example.com",
            "first_name": "Fresh",
            "last_name": "Doc",
            "specialty_id": specialty.id,
        }
        created = auth_client(admin_user).post(DOCTORS, body, format="json")
        assert created.status_code == 201
        assert auth_client(patient).get(DOCTORS).data["count"] == 0


@pytest.mark.django_db
class TestOnlyDoctorAccounts:
    def test_profile_of_a_non_doctor_user_is_never_listed(
        self, auth_client, patient, admin_user, specialty
    ):
        stray = DoctorProfile.objects.create(user=admin_user, specialty=specialty)
        client = auth_client(patient)
        assert client.get(DOCTORS).data["count"] == 0
        assert client.get(f"{DOCTORS}{stray.pk}/").status_code == 404
        assert auth_client(admin_user).get(DOCTORS).data["count"] == 0


@pytest.mark.django_db
class TestSearchLimits:
    def test_only_the_first_terms_are_used(self, auth_client, patient, doctor):
        client = auth_client(patient)
        # "doc" and "tor" match; five more terms would match nothing if they were applied.
        assert client.get(DOCTORS, {"search": "d o c t o"}).data["count"] == 1
        assert client.get(DOCTORS, {"search": "d o c t o zzz"}).data["count"] == 1
        assert client.get(DOCTORS, {"search": "zzz d o c t"}).data["count"] == 0

    def test_search_text_is_truncated(self, auth_client, patient, doctor):
        client = auth_client(patient)
        response = client.get(DOCTORS, {"search": "doc" + " " * 200 + "zzz"})
        assert response.status_code == 200
        assert response.data["count"] == 1  # "zzz" lies beyond the cap
        assert client.get(DOCTORS, {"search": "x" * 5000}).status_code == 200


# --- anonymous / wrong role gaps ---


@pytest.mark.django_db
class TestAccessGaps:
    def test_specialty_writes_and_doctor_detail_need_login(self, api_client, doctor, specialty):
        url = f"{SPECIALTIES}{specialty.id}/"
        assert api_client.post(SPECIALTIES, {}, format="json").status_code == 401
        assert api_client.patch(url, {}, format="json").status_code == 401
        assert api_client.delete(url).status_code == 401
        assert api_client.get(f"{DOCTORS}{doctor.id}/").status_code == 401

    @pytest.mark.parametrize("who", ["patient", "admin_user"])
    def test_availability_and_time_off_item_routes_need_a_doctor(
        self, auth_client, request, who, doctor
    ):
        row = WeeklyAvailability.objects.create(
            doctor=doctor.doctor_profile, weekday=0, start_time="09:00", end_time="10:00"
        )
        now = timezone.now()
        off = TimeOff.objects.create(
            doctor=doctor.doctor_profile, start_at=now, end_at=now + timedelta(hours=1)
        )
        client = auth_client(request.getfixturevalue(who))
        assert client.patch(f"{AVAILABILITY}{row.id}/", {}, format="json").status_code == 403
        assert client.delete(f"{AVAILABILITY}{row.id}/").status_code == 403
        assert client.delete(f"{TIME_OFF}{off.id}/").status_code == 403
        assert WeeklyAvailability.objects.filter(pk=row.pk).exists()
        assert TimeOff.objects.filter(pk=off.pk).exists()

    def test_anonymous_item_routes_are_401(self, api_client, doctor):
        assert api_client.patch(f"{AVAILABILITY}1/", {}, format="json").status_code == 401
        assert api_client.delete(f"{AVAILABILITY}1/").status_code == 401
        assert api_client.delete(f"{TIME_OFF}1/").status_code == 401


@pytest.mark.django_db
def test_my_bio_is_length_limited(auth_client, doctor):
    client = auth_client(doctor)
    assert client.patch(ME, {"bio": "x" * 2000}, format="json").status_code == 200
    response = client.patch(ME, {"bio": "x" * 2001}, format="json")
    assert response.status_code == 400
    assert response.data["error"]["fields"]["bio"][0]["code"] == "max_length"
