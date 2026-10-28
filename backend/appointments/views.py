from datetime import datetime, time, timedelta

from django.db.models import Case, IntegerField, Q, Value, When
from django.utils import timezone
from django.utils.translation import gettext as _
from django_filters import rest_framework as filters
from drf_spectacular.utils import extend_schema
from rest_framework import generics, status
from rest_framework.exceptions import ErrorDetail, NotFound, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from accounts.models import User
from accounts.permissions import IsDoctor, IsPatient

from . import services
from .models import Appointment
from .serializers import (
    AppointmentSerializer,
    BookAppointmentSerializer,
    CancelAppointmentSerializer,
    SlotQuerySerializer,
    SlotsResponseSerializer,
)

TAG = ["appointments"]


class SlotsView(APIView):
    """Free slots of a doctor on a date (`?doctor=<id>&date=YYYY-MM-DD`)."""

    @extend_schema(
        tags=TAG, parameters=[SlotQuerySerializer], responses={200: SlotsResponseSerializer}
    )
    def get(self, request):
        query = SlotQuerySerializer(data=request.query_params)
        query.is_valid(raise_exception=True)
        doctor = services.bookable_doctor(request.user, query.validated_data["doctor"])
        if doctor is None:
            raise NotFound()
        day = query.validated_data["date"]
        slots = services.free_slots(doctor, day)
        return Response(
            SlotsResponseSerializer(
                {
                    "doctor": doctor.pk,
                    "date": day,
                    "consultation_minutes": doctor.consultation_minutes,
                    "slots": [{"start_at": s, "end_at": e} for s, e in slots],
                }
            ).data
        )


class AppointmentFilter(filters.FilterSet):
    scope = filters.ChoiceFilter(
        choices=[("upcoming", "upcoming"), ("past", "past")], method="filter_scope"
    )
    status = filters.ChoiceFilter(choices=Appointment.Status.choices)
    date = filters.DateFilter(method="filter_date")
    doctor = filters.NumberFilter(field_name="doctor_id")
    patient = filters.NumberFilter(field_name="patient_id")

    class Meta:
        model = Appointment
        fields = ["scope", "status", "date", "doctor", "patient"]

    def filter_scope(self, queryset, name, value):
        """upcoming = confirmed and not started yet (earliest first); past = everything else
        (started, or cancelled / completed / no-show), latest first."""
        now = services._now()
        upcoming = Q(status=Appointment.Status.CONFIRMED, start_at__gte=now)
        if value == "upcoming":
            return queryset.filter(upcoming)
        # Started-but-unclosed (still confirmed) first: the doctor has to close them.
        unclosed_first = Case(
            When(status=Appointment.Status.CONFIRMED, then=Value(0)),
            default=Value(1),
            output_field=IntegerField(),
        )
        return queryset.exclude(upcoming).order_by(unclosed_first, "-start_at", "-pk")

    def filter_date(self, queryset, name, value):
        """Appointments starting on calendar day `value` in TIME_ZONE."""
        try:
            start = timezone.make_aware(datetime.combine(value, time.min))
            end = timezone.make_aware(datetime.combine(value + timedelta(days=1), time.min))
        except (OverflowError, ValueError):  # year 1, 9999-12-31
            raise ValidationError(
                {"date": [ErrorDetail(_("Enter a valid date."), code="invalid")]}
            ) from None
        return queryset.filter(start_at__gte=start, start_at__lt=end)


class ScopedAppointmentsMixin:
    """Patient: own appointments. Doctor: own agenda. Admin: all. Others' objects are 404."""

    def get_queryset(self):
        queryset = Appointment.objects.select_related(
            "patient", "doctor__user", "doctor__specialty", "cancelled_by"
        )
        user = self.request.user
        if getattr(self, "swagger_fake_view", False) or user.role == User.Role.ADMIN:
            return queryset
        if user.role == User.Role.DOCTOR:
            return queryset.filter(doctor_id=user.pk)
        return queryset.filter(patient_id=user.pk)


class AppointmentListCreateView(ScopedAppointmentsMixin, generics.ListCreateAPIView):
    """GET: my appointments (`?scope=upcoming|past&status=&date=`; admin also `doctor`,
    `patient`). POST: a patient books a slot."""

    serializer_class = AppointmentSerializer
    filterset_class = AppointmentFilter

    @property
    def throttle_scope(self):
        # Only writes are throttled (rate: THROTTLE_APPOINTMENT_WRITE).
        return "appointment_write" if self.request.method == "POST" else None

    def get_permissions(self):
        return [IsPatient()] if self.request.method == "POST" else super().get_permissions()

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(
        tags=TAG, request=BookAppointmentSerializer, responses={201: AppointmentSerializer}
    )
    def post(self, request, *args, **kwargs):
        body = BookAppointmentSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        appointment = services.book(
            patient=request.user,
            doctor_id=body.validated_data["doctor"],
            start_at=body.validated_data["start_at"],
            reason=body.validated_data["reason"],
        )
        return Response(AppointmentSerializer(appointment).data, status=status.HTTP_201_CREATED)


class AppointmentDetailView(ScopedAppointmentsMixin, generics.RetrieveAPIView):
    serializer_class = AppointmentSerializer

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)


class _ActionView(ScopedAppointmentsMixin, generics.GenericAPIView):
    """POST on one appointment of the caller (404 when it is not theirs)."""

    serializer_class = AppointmentSerializer

    def act(self, appointment):
        raise NotImplementedError

    def post(self, request, *args, **kwargs):
        appointment = self.get_object()
        return Response(AppointmentSerializer(self.act(appointment)).data)


class CancelView(_ActionView):
    """Patient until CANCELLATION_MIN_HOURS before the start; doctor / admin until the
    start (a reason is required from them)."""

    throttle_scope = "appointment_write"

    def act(self, appointment):
        body = CancelAppointmentSerializer(data=self.request.data)
        body.is_valid(raise_exception=True)
        return services.cancel(
            appointment, actor=self.request.user, reason=body.validated_data["reason"]
        )

    @extend_schema(
        tags=TAG, request=CancelAppointmentSerializer, responses={200: AppointmentSerializer}
    )
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)


class CompleteView(_ActionView):
    permission_classes = [IsDoctor]

    def act(self, appointment):
        return services.complete(appointment, actor=self.request.user)

    @extend_schema(tags=TAG, request=None, responses={200: AppointmentSerializer})
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)


class NoShowView(_ActionView):
    permission_classes = [IsDoctor]

    def act(self, appointment):
        return services.mark_no_show(appointment, actor=self.request.user)

    @extend_schema(tags=TAG, request=None, responses={200: AppointmentSerializer})
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)
