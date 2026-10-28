from django.urls import path

from . import views

# `appointments/slots/` must come before `appointments/<int:pk>/`.
urlpatterns = [
    path("appointments/slots/", views.SlotsView.as_view()),
    path("appointments/", views.AppointmentListCreateView.as_view()),
    path("appointments/<int:pk>/", views.AppointmentDetailView.as_view()),
    path("appointments/<int:pk>/cancel/", views.CancelView.as_view()),
    path("appointments/<int:pk>/complete/", views.CompleteView.as_view()),
    path("appointments/<int:pk>/no-show/", views.NoShowView.as_view()),
]
