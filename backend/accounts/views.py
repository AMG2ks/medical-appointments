from django.utils.translation import gettext as _
from django_filters.rest_framework import DjangoFilterBackend
from drf_spectacular.utils import extend_schema
from rest_framework import generics, status
from rest_framework.filters import SearchFilter
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from . import services
from .models import User
from .permissions import IsAdmin
from .serializers import (
    AuthResponseSerializer,
    ChangePasswordSerializer,
    LoginSerializer,
    PasswordResetConfirmSerializer,
    PasswordResetRequestSerializer,
    RefreshSerializer,
    RefreshTokenSerializer,
    RegisterSerializer,
    TokenPairSerializer,
    UserActiveSerializer,
    UserSerializer,
)


def _ip(request) -> str | None:
    """Client address for audit lines (REMOTE_ADDR: X-Forwarded-For can be forged)."""
    return request.META.get("REMOTE_ADDR")


class PublicView:
    """Public endpoints skip authentication too, otherwise a stale Authorization header
    would make DRF answer 401 even though the endpoint is open."""

    permission_classes = [AllowAny]
    authentication_classes = []


class RegisterView(PublicView, APIView):
    throttle_scope = "auth_register"

    @extend_schema(
        request=RegisterSerializer, responses={201: AuthResponseSerializer}, tags=["auth"]
    )
    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = services.register_patient(data=serializer.validated_data)
        body = {**services.issue_tokens(user), "user": UserSerializer(user).data}
        return Response(body, status=status.HTTP_201_CREATED)


@extend_schema(responses={200: AuthResponseSerializer}, tags=["auth"])
class LoginView(PublicView, TokenObtainPairView):
    serializer_class = LoginSerializer
    throttle_scope = "auth_login"


@extend_schema(responses={200: TokenPairSerializer}, tags=["auth"])
class RefreshView(PublicView, TokenRefreshView):
    """Rotation: the answer carries a NEW refresh token; the old one is blacklisted."""

    serializer_class = RefreshSerializer


class LogoutView(PublicView, APIView):
    """Public on purpose: the refresh token is the proof, and it must work even when the
    access token has expired. Idempotent."""

    @extend_schema(request=RefreshTokenSerializer, responses={204: None}, tags=["auth"])
    def post(self, request):
        serializer = RefreshTokenSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            RefreshToken(serializer.validated_data["refresh"]).blacklist()
        except TokenError:
            pass  # expired, already blacklisted or bad signature: nothing left to revoke
        return Response(status=status.HTTP_204_NO_CONTENT)


class MeView(generics.RetrieveUpdateAPIView):
    serializer_class = UserSerializer
    http_method_names = ["get", "patch", "head", "options"]

    def get_object(self):
        return self.request.user

    @extend_schema(tags=["auth"])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(tags=["auth"])
    def patch(self, request, *args, **kwargs):
        return super().patch(request, *args, **kwargs)


class ChangePasswordView(APIView):
    @extend_schema(
        request=ChangePasswordSerializer, responses={200: TokenPairSerializer}, tags=["auth"]
    )
    def post(self, request):
        serializer = ChangePasswordSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        tokens = services.change_password(
            request.user,
            serializer.validated_data["old_password"],
            serializer.validated_data["new_password"],
            ip=_ip(request),
        )
        return Response(tokens)


class PasswordResetRequestView(PublicView, APIView):
    throttle_scope = "password_reset"

    @extend_schema(request=PasswordResetRequestSerializer, responses={202: None}, tags=["auth"])
    def post(self, request):
        serializer = PasswordResetRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        services.request_password_reset(serializer.validated_data["email"])
        # Same answer whether or not the account exists.
        detail = _("If an account exists for this email, a code was sent.")
        return Response({"detail": detail}, status=status.HTTP_202_ACCEPTED)


class PasswordResetConfirmView(PublicView, APIView):
    throttle_scope = "password_reset_confirm"

    @extend_schema(request=PasswordResetConfirmSerializer, responses={204: None}, tags=["auth"])
    def post(self, request):
        serializer = PasswordResetConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        services.confirm_password_code(**serializer.validated_data, ip=_ip(request))
        return Response(status=status.HTTP_204_NO_CONTENT)


class UserListView(generics.ListAPIView):
    """Admin: GET users/?role=doctor&is_active=true&search=amira"""

    permission_classes = [IsAdmin]
    serializer_class = UserSerializer
    queryset = User.objects.select_related("patient_profile").order_by("-date_joined")
    filter_backends = [DjangoFilterBackend, SearchFilter]
    filterset_fields = ["role", "is_active"]
    search_fields = ["email", "first_name", "last_name"]

    @extend_schema(tags=["users (admin)"])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)


class UserDetailView(generics.RetrieveAPIView):
    """Admin: GET users/{id}/ and PATCH users/{id}/ {"is_active": false}"""

    permission_classes = [IsAdmin]
    serializer_class = UserSerializer
    queryset = User.objects.select_related("patient_profile")

    @extend_schema(tags=["users (admin)"])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    @extend_schema(
        request=UserActiveSerializer, responses={200: UserSerializer}, tags=["users (admin)"]
    )
    def patch(self, request, *args, **kwargs):
        user = self.get_object()
        serializer = UserActiveSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = services.set_user_active(
            user, serializer.validated_data["is_active"], by=request.user
        )
        return Response(UserSerializer(user).data)
