from datetime import date, datetime, time
from zoneinfo import ZoneInfo

import pytest

from core.exceptions import BusinessError
from doctors import services
from doctors.models import TimeOff, WeeklyAvailability

TUNIS = ZoneInfo("Africa/Tunis")
MONDAY = date(2026, 11, 2)  # weekday 0


def at(day: date, hour: int, minute: int = 0, tz=TUNIS) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=tz)


@pytest.fixture
def profile(doctor):
    return doctor.doctor_profile


def real_seconds(start: datetime, end: datetime) -> float:
    """Elapsed time. Python subtracts same-zone aware datetimes by wall clock (ignoring DST),
    so go through UTC."""
    utc = ZoneInfo("UTC")
    return (end.astimezone(utc) - start.astimezone(utc)).total_seconds()


def window(profile, weekday, start, end):
    return WeeklyAvailability.objects.create(
        doctor=profile, weekday=weekday, start_time=start, end_time=end
    )


def off(profile, start, end, reason=""):
    return TimeOff.objects.create(doctor=profile, start_at=start, end_at=end, reason=reason)


@pytest.mark.django_db
class TestWorkingIntervals:
    def test_no_availability_for_that_weekday(self, profile):
        window(profile, 1, time(9), time(12))
        assert services.working_intervals(profile, MONDAY) == []

    def test_returns_aware_sorted_windows_in_configured_zone(self, profile, settings):
        window(profile, 0, time(14), time(17))
        window(profile, 0, time(9), time(12))
        result = services.working_intervals(profile, MONDAY)
        assert result == [(at(MONDAY, 9), at(MONDAY, 12)), (at(MONDAY, 14), at(MONDAY, 17))]
        assert all(s.tzinfo is not None and e.tzinfo is not None for s, e in result)
        assert result[0][0].utcoffset().total_seconds() == 3600  # Tunis is UTC+1

    def test_other_doctors_are_ignored(self, profile, doctor, specialty):
        from accounts.models import User
        from doctors.models import DoctorProfile

        other_user = User.objects.create_user("o@example.com", "x", role=User.Role.DOCTOR)
        other = DoctorProfile.objects.create(user=other_user, specialty=specialty)
        window(other, 0, time(8), time(9))
        assert services.working_intervals(profile, MONDAY) == []

    def test_time_off_in_the_middle_splits_window(self, profile):
        window(profile, 0, time(9), time(12))
        off(profile, at(MONDAY, 10), at(MONDAY, 10, 30))
        assert services.working_intervals(profile, MONDAY) == [
            (at(MONDAY, 9), at(MONDAY, 10)),
            (at(MONDAY, 10, 30), at(MONDAY, 12)),
        ]

    def test_time_off_covering_everything(self, profile):
        window(profile, 0, time(9), time(12))
        off(profile, at(MONDAY, 8), at(MONDAY, 13))
        assert services.working_intervals(profile, MONDAY) == []

    def test_time_off_clipping_start_and_end(self, profile):
        window(profile, 0, time(9), time(12))
        off(profile, at(MONDAY, 8), at(MONDAY, 9, 30))
        off(profile, at(MONDAY, 11, 30), at(MONDAY, 13))
        assert services.working_intervals(profile, MONDAY) == [
            (at(MONDAY, 9, 30), at(MONDAY, 11, 30))
        ]

    def test_overlapping_time_offs(self, profile):
        window(profile, 0, time(9), time(17))
        off(profile, at(MONDAY, 10), at(MONDAY, 12))
        off(profile, at(MONDAY, 11), at(MONDAY, 13))
        off(profile, at(MONDAY, 10, 30), at(MONDAY, 11, 15))  # nested in the others
        assert services.working_intervals(profile, MONDAY) == [
            (at(MONDAY, 9), at(MONDAY, 10)),
            (at(MONDAY, 13), at(MONDAY, 17)),
        ]

    def test_time_off_touching_window_edges_changes_nothing(self, profile):
        window(profile, 0, time(9), time(12))
        off(profile, at(MONDAY, 8), at(MONDAY, 9))
        off(profile, at(MONDAY, 12), at(MONDAY, 13))
        assert services.working_intervals(profile, MONDAY) == [(at(MONDAY, 9), at(MONDAY, 12))]

    def test_time_off_spanning_several_days(self, profile):
        tuesday = date(2026, 11, 3)
        wednesday = date(2026, 11, 4)
        for weekday in (0, 1, 2):
            window(profile, weekday, time(9), time(12))
        off(profile, at(MONDAY, 11), at(wednesday, 10))
        assert services.working_intervals(profile, MONDAY) == [(at(MONDAY, 9), at(MONDAY, 11))]
        assert services.working_intervals(profile, tuesday) == []
        assert services.working_intervals(profile, wednesday) == [
            (at(wednesday, 10), at(wednesday, 12))
        ]

    def test_time_off_on_another_day_is_ignored(self, profile):
        window(profile, 0, time(9), time(12))
        off(profile, at(date(2026, 11, 3), 0), at(date(2026, 11, 3), 23))
        assert services.working_intervals(profile, MONDAY) == [(at(MONDAY, 9), at(MONDAY, 12))]

    def test_time_off_given_in_another_timezone(self, profile):
        window(profile, 0, time(9), time(12))
        utc = ZoneInfo("UTC")  # 09:00-10:00 UTC is 10:00-11:00 in Tunis
        off(profile, at(MONDAY, 9, tz=utc), at(MONDAY, 10, tz=utc))
        assert services.working_intervals(profile, MONDAY) == [
            (at(MONDAY, 9), at(MONDAY, 10)),
            (at(MONDAY, 11), at(MONDAY, 12)),
        ]

    def test_dst_spring_forward_keeps_wall_clock(self, profile, settings):
        settings.TIME_ZONE = "Europe/Paris"
        paris = ZoneInfo("Europe/Paris")
        sunday = date(2026, 3, 29)  # clocks go 02:00 -> 03:00; weekday 6
        window(profile, 6, time(1), time(5))
        ((start, end),) = services.working_intervals(profile, sunday)
        assert start == at(sunday, 1, tz=paris) and end == at(sunday, 5, tz=paris)
        assert real_seconds(start, end) == 3 * 3600  # only 3 real hours that day
        assert end.utcoffset().total_seconds() == 2 * 3600

    def test_window_inside_the_dst_gap_is_empty_not_inverted(self, profile, settings):
        settings.TIME_ZONE = "Europe/Paris"
        sunday = date(2026, 3, 29)  # 02:00-03:00 does not exist
        window(profile, 6, time(2, 30), time(3, 15))
        assert services.working_intervals(profile, sunday) == []

    def test_window_across_the_dst_gap_loses_the_missing_hour(self, profile, settings):
        settings.TIME_ZONE = "Europe/Paris"
        paris = ZoneInfo("Europe/Paris")
        sunday = date(2026, 3, 29)
        window(profile, 6, time(1, 30), time(3, 30))
        ((start, end),) = services.working_intervals(profile, sunday)
        assert (start, end) == (at(sunday, 1, 30, tz=paris), at(sunday, 3, 30, tz=paris))
        assert real_seconds(start, end) == 3600

    def test_dst_fall_back_day_has_extra_hour_and_time_off_uses_real_instants(
        self, profile, settings
    ):
        settings.TIME_ZONE = "Europe/Paris"
        paris = ZoneInfo("Europe/Paris")
        sunday = date(2026, 10, 25)  # 03:00 -> 02:00
        window(profile, 6, time(1), time(5))
        ((start, end),) = services.working_intervals(profile, sunday)
        assert real_seconds(start, end) == 5 * 3600
        # Block the first 02:xx hour (UTC+2): 00:00Z-01:00Z
        utc = ZoneInfo("UTC")
        off(
            profile,
            datetime(2026, 10, 25, 0, 0, tzinfo=utc),
            datetime(2026, 10, 25, 1, 0, tzinfo=utc),
        )
        result = services.working_intervals(profile, sunday)
        assert result[0] == (at(sunday, 1, tz=paris), at(sunday, 2, tz=paris))  # 01:00-02:00 CEST
        assert result[1][1] == at(sunday, 5, tz=paris)
        assert sum(real_seconds(s, e) for s, e in result) == 4 * 3600


@pytest.mark.django_db
class TestSaveAvailability:
    def test_overlap_is_rejected_but_touching_is_fine(self, profile):
        services.save_availability(profile, weekday=0, start_time=time(9), end_time=time(12))
        services.save_availability(profile, weekday=0, start_time=time(12), end_time=time(14))
        services.save_availability(profile, weekday=1, start_time=time(9), end_time=time(12))
        with pytest.raises(BusinessError) as exc:
            services.save_availability(profile, weekday=0, start_time=time(11), end_time=time(13))
        assert exc.value.get_codes() == "availability_overlap"

    def test_update_ignores_itself(self, profile):
        item = services.save_availability(profile, weekday=0, start_time=time(9), end_time=time(12))
        item = services.save_availability(
            profile, weekday=0, start_time=time(10), end_time=time(12), instance=item
        )
        assert item.start_time == time(10)
