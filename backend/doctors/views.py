from django.shortcuts import get_object_or_404
from django_filters import rest_framework as filters
from drf_spectacular.utils import OpenApiResponse, extend_schema
from rest_framework import generics, status
from rest_framework.filters import SearchFilter
from rest_framework.response import Response

from accounts.permissions import IsAdmin, IsDoctor

from . import services
from .models import DoctorProfile, Specialty, TimeOff, WeeklyAvailability
from .serializers import (
    CreateDoctorSerializer,
    DoctorMeSerializer,
    DoctorSerializer,
    SpecialtySerializer,
    TimeOffSerializer,
    WeeklyAvailabilitySerializer,
)
from .services import visible_doctors  # also importable from here (kept for older imports)

TAG = ["doctors"]


# --- specialties ---


class SpecialtyListCreateView(generics.ListCreateAPIView):
    """Any logged-in user lists; only an admin creates."""

    serializer_class = SpecialtySerializer
    queryset = Specialty.objects.all()

    def get_permissions(self):
        return [IsAdmin()] if self.request.method == "POST" else super().get_permissions()

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(tags=TAG)
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)


class SpecialtyDetailView(generics.UpdateAPIView, generics.DestroyAPIView):
    """Admin: PATCH / DELETE (409 `specialty_in_use` while doctors use it)."""

    permission_classes = [IsAdmin]
    serializer_class = SpecialtySerializer
    queryset = Specialty.objects.all()
    http_method_names = ["patch", "delete", "options"]

    @extend_schema(tags=TAG)
    def patch(self, request, *args, **kwargs):
        return super().patch(request, *args, **kwargs)

    @extend_schema(tags=TAG, responses={204: None})
    def delete(self, request, *args, **kwargs):
        return super().delete(request, *args, **kwargs)

    def perform_destroy(self, instance):
        services.delete_specialty(instance)


# --- doctors ---


class DoctorFilter(filters.FilterSet):
    specialty = filters.NumberFilter(field_name="specialty_id")

    class Meta:
        model = DoctorProfile
        fields = ["specialty"]


SEARCH_MAX_LENGTH = 100
SEARCH_MAX_TERMS = 5


class BoundedSearchFilter(SearchFilter):
    """Caps the search text (length and number of words): each word is one JOIN-free
    `icontains` clause, so an unbounded query string would build a huge WHERE."""

    def get_search_terms(self, request):
        value = request.query_params.get(self.search_param, "")[:SEARCH_MAX_LENGTH]
        return value.replace(",", " ").split()[:SEARCH_MAX_TERMS]


class DoctorListCreateView(generics.ListCreateAPIView):
    """GET: visible doctors (`?specialty=<id>&search=<name>`). POST: admin creates a doctor."""

    filterset_class = DoctorFilter
    filter_backends = [filters.DjangoFilterBackend, BoundedSearchFilter]
    search_fields = ["user__first_name", "user__last_name"]

    def get_queryset(self):
        return visible_doctors(self.request.user).order_by(
            "user__last_name", "user__first_name", "pk"
        )

    def get_permissions(self):
        return [IsAdmin()] if self.request.method == "POST" else super().get_permissions()

    def get_serializer_class(self):
        return CreateDoctorSerializer if self.request.method == "POST" else DoctorSerializer

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(tags=TAG, request=CreateDoctorSerializer, responses={201: DoctorMeSerializer})
    def post(self, request, *args, **kwargs):
        serializer = CreateDoctorSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        profile = services.create_doctor(data=serializer.validated_data)
        return Response(DoctorMeSerializer(profile).data, status=status.HTTP_201_CREATED)


class DoctorDetailView(generics.RetrieveAPIView):
    serializer_class = DoctorSerializer

    def get_queryset(self):
        return visible_doctors(self.request.user)

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)


class DoctorMeMixin:
    """Everything under /doctors/me/ is for the logged-in doctor and scoped to them."""

    permission_classes = [IsDoctor]

    def get_doctor(self) -> DoctorProfile:
        return get_object_or_404(
            DoctorProfile.objects.select_related("user", "specialty"), pk=self.request.user.pk
        )


class DoctorMeView(DoctorMeMixin, generics.RetrieveUpdateAPIView):
    serializer_class = DoctorMeSerializer
    http_method_names = ["get", "patch", "head", "options"]

    def get_object(self):
        return self.get_doctor()

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(tags=TAG)
    def patch(self, request, *args, **kwargs):
        return super().patch(request, *args, **kwargs)


# --- weekly availability ---


class AvailabilityListCreateView(DoctorMeMixin, generics.ListCreateAPIView):
    serializer_class = WeeklyAvailabilitySerializer

    def get_queryset(self):
        return WeeklyAvailability.objects.filter(doctor_id=self.request.user.pk)

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(tags=TAG)
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)

    def perform_create(self, serializer):
        data = serializer.validated_data
        serializer.instance = services.save_availability(
            self.get_doctor(),
            weekday=data["weekday"],
            start_time=data["start_time"],
            end_time=data["end_time"],
        )


class AvailabilityDetailView(DoctorMeMixin, generics.UpdateAPIView, generics.DestroyAPIView):
    serializer_class = WeeklyAvailabilitySerializer
    http_method_names = ["patch", "delete", "options"]

    def get_queryset(self):
        # Other doctors' rows are simply not found (404).
        return WeeklyAvailability.objects.filter(doctor_id=self.request.user.pk)

    @extend_schema(tags=TAG)
    def patch(self, request, *args, **kwargs):
        return super().patch(request, *args, **kwargs)

    @extend_schema(tags=TAG, responses={204: None})
    def delete(self, request, *args, **kwargs):
        return super().delete(request, *args, **kwargs)

    def perform_update(self, serializer):
        current = serializer.instance
        data = serializer.validated_data
        serializer.instance = services.save_availability(
            self.get_doctor(),
            weekday=data.get("weekday", current.weekday),
            start_time=data.get("start_time", current.start_time),
            end_time=data.get("end_time", current.end_time),
            instance=current,
        )


# --- time off ---


class TimeOffListCreateView(DoctorMeMixin, generics.ListCreateAPIView):
    serializer_class = TimeOffSerializer

    def get_queryset(self):
        return TimeOff.objects.filter(doctor_id=self.request.user.pk)

    @extend_schema(tags=TAG)
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(
        tags=TAG,
        responses={
            201: TimeOffSerializer,
            409: OpenApiResponse(
                description="`time_off_conflict`: confirmed appointments overlap the period "
                "(`error.details` lists them)."
            ),
        },
    )
    def post(self, request, *args, **kwargs):
        return super().post(request, *args, **kwargs)

    def perform_create(self, serializer):
        # 409 `time_off_conflict` while confirmed appointments fall in the period.
        data = serializer.validated_data
        serializer.instance = services.create_time_off(
            self.get_doctor(),
            start_at=data["start_at"],
            end_at=data["end_at"],
            reason=data.get("reason", ""),
        )


class TimeOffDetailView(DoctorMeMixin, generics.DestroyAPIView):
    serializer_class = TimeOffSerializer

    def get_queryset(self):
        return TimeOff.objects.filter(doctor_id=self.request.user.pk)

    @extend_schema(tags=TAG, responses={204: None})
    def delete(self, request, *args, **kwargs):
        return super().delete(request, *args, **kwargs)
