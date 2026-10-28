from django.urls import path

from . import views

urlpatterns = [
    path("notifications/", views.NotificationListView.as_view()),
    path("notifications/unread-count/", views.UnreadCountView.as_view()),
    path("notifications/read-all/", views.MarkAllReadView.as_view()),
    path("notifications/<int:pk>/read/", views.MarkReadView.as_view()),
]
