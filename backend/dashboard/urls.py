from django.urls import path

from . import views

urlpatterns = [path("dashboard/stats/", views.StatsView.as_view())]
