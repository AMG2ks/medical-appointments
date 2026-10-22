from django.conf import settings
from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView

urlpatterns = [
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="docs"),
    # Each module adds its own include here.
    path("api/v1/", include("accounts.urls")),
]

if settings.DJANGO_ADMIN_ENABLED:
    urlpatterns.append(path("admin/", admin.site.urls))
