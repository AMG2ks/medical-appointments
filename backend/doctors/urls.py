from django.urls import path

from . import views

# `doctors/me/...` must come before `doctors/<int:pk>/`.
urlpatterns = [
    path("specialties/", views.SpecialtyListCreateView.as_view()),
    path("specialties/<int:pk>/", views.SpecialtyDetailView.as_view()),
    path("doctors/", views.DoctorListCreateView.as_view()),
    path("doctors/me/", views.DoctorMeView.as_view()),
    path("doctors/me/availability/", views.AvailabilityListCreateView.as_view()),
    path("doctors/me/availability/<int:pk>/", views.AvailabilityDetailView.as_view()),
    path("doctors/me/time-off/", views.TimeOffListCreateView.as_view()),
    path("doctors/me/time-off/<int:pk>/", views.TimeOffDetailView.as_view()),
    path("doctors/<int:pk>/", views.DoctorDetailView.as_view()),
]
