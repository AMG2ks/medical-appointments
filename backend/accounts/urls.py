from django.urls import path

from . import views

urlpatterns = [
    path("auth/register/", views.RegisterView.as_view()),
    path("auth/login/", views.LoginView.as_view()),
    path("auth/token/refresh/", views.RefreshView.as_view()),
    path("auth/logout/", views.LogoutView.as_view()),
    path("auth/me/", views.MeView.as_view()),
    path("auth/password/change/", views.ChangePasswordView.as_view()),
    path("auth/password/reset/", views.PasswordResetRequestView.as_view()),
    path("auth/password/reset/confirm/", views.PasswordResetConfirmView.as_view()),
    path("users/", views.UserListView.as_view()),
    path("users/<int:pk>/", views.UserDetailView.as_view()),
]
