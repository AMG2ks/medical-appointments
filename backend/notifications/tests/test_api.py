import pytest

from notifications.models import Notification

from .conftest import NOTIFICATIONS


def note(user, kind="appointment_confirmed", read=False, key=None):
    from django.utils import timezone

    return Notification.objects.create(
        user=user,
        kind=kind,
        data={"appointment_id": 1},
        dedupe_key=key,
        read_at=timezone.now() if read else None,
    )


@pytest.mark.django_db
class TestAuth:
    @pytest.mark.parametrize(
        "method,path",
        [
            ("get", NOTIFICATIONS),
            ("get", f"{NOTIFICATIONS}unread-count/"),
            ("post", f"{NOTIFICATIONS}1/read/"),
            ("post", f"{NOTIFICATIONS}read-all/"),
        ],
    )
    def test_anonymous_is_401(self, api_client, method, path):
        response = getattr(api_client, method)(path)
        assert response.status_code == 401
        assert response.data["error"]["code"] == "not_authenticated"


@pytest.mark.django_db
class TestList:
    def test_only_my_notifications_newest_first_and_paginated(self, auth_client, patient, doctor):
        first = note(patient, key="a")
        second = note(patient, "appointment_cancelled", key="b")
        note(doctor, key="c")
        response = auth_client(patient).get(NOTIFICATIONS)
        assert response.status_code == 200
        assert set(response.data) == {"count", "next", "previous", "results"}
        assert [r["id"] for r in response.data["results"]] == [second.pk, first.pk]
        assert set(response.data["results"][0]) == {"id", "kind", "data", "read_at", "created_at"}

    def test_unread_filter(self, auth_client, patient):
        note(patient, read=True, key="a")
        unread = note(patient, key="b")
        client = auth_client(patient)
        assert client.get(NOTIFICATIONS).data["count"] == 2
        results = client.get(NOTIFICATIONS, {"unread": "true"}).data["results"]
        assert [r["id"] for r in results] == [unread.pk]

    def test_every_role_can_list(self, auth_client, admin_user, doctor):
        assert auth_client(admin_user).get(NOTIFICATIONS).data["count"] == 0
        assert auth_client(doctor).get(NOTIFICATIONS).status_code == 200


@pytest.mark.django_db
class TestUnreadCount:
    def test_counts_my_unread_only(self, auth_client, patient, doctor):
        note(patient, key="a")
        note(patient, read=True, key="b")
        note(doctor, key="c")
        response = auth_client(patient).get(f"{NOTIFICATIONS}unread-count/")
        assert response.status_code == 200
        assert response.data == {"count": 1}


@pytest.mark.django_db
class TestRead:
    def test_marks_one_as_read_and_is_idempotent(self, auth_client, patient):
        target = note(patient, key="a")
        other = note(patient, key="b")
        client = auth_client(patient)
        response = client.post(f"{NOTIFICATIONS}{target.pk}/read/")
        assert response.status_code == 200
        assert response.data["read_at"] is not None
        first = Notification.objects.get(pk=target.pk).read_at
        client.post(f"{NOTIFICATIONS}{target.pk}/read/")
        assert Notification.objects.get(pk=target.pk).read_at == first
        assert Notification.objects.get(pk=other.pk).read_at is None

    def test_someone_elses_notification_is_404(self, auth_client, patient, doctor):
        theirs = note(doctor, key="a")
        response = auth_client(patient).post(f"{NOTIFICATIONS}{theirs.pk}/read/")
        assert response.status_code == 404
        assert response.data["error"]["code"] == "not_found"
        assert Notification.objects.get(pk=theirs.pk).read_at is None

    def test_read_all_touches_only_mine(self, auth_client, patient, doctor):
        note(patient, key="a")
        note(patient, key="b")
        theirs = note(doctor, key="c")
        response = auth_client(patient).post(f"{NOTIFICATIONS}read-all/")
        assert response.status_code == 200
        assert response.data == {"updated": 2}
        assert Notification.objects.get(pk=theirs.pk).read_at is None
        count = auth_client(patient).get(f"{NOTIFICATIONS}unread-count/").data
        assert count == {"count": 0}
