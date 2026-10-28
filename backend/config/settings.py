"""Django settings. Every value that varies per machine comes from backend/.env."""

from datetime import timedelta
from pathlib import Path

import environ
from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env()
# Reads backend/.env if it exists (real environment variables win). SECRET_KEY and
# DATABASE_URL have no default: the app refuses to start without them.
environ.Env.read_env(BASE_DIR / ".env")

SECRET_KEY = env("SECRET_KEY")
# The key signs every JWT: refuse empty, short or placeholder values.
# Generate one with django.core.management.utils.get_random_secret_key (see README).
if len(SECRET_KEY) < 50 or any(
    marker in SECRET_KEY.lower() for marker in ("change-me", "dev-only", "django-insecure")
):
    raise ImproperlyConfigured(
        "SECRET_KEY is empty, shorter than 50 characters or a placeholder. Generate one with: "
        'python -c "from django.core.management.utils import get_random_secret_key as g; '
        'print(g())" and put it in backend/.env.'
    )
DEBUG = env.bool("DEBUG", default=False)
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS")
# Django admin (/admin/) is a back-office fallback: off unless explicitly enabled.
DJANGO_ADMIN_ENABLED = env.bool("DJANGO_ADMIN_ENABLED", default=False)

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    # third party
    "rest_framework",
    "rest_framework_simplejwt.token_blacklist",
    "drf_spectacular",
    "drf_spectacular_sidecar",
    "django_filters",
    # project apps (each module adds its own app here)
    "core",
    "accounts",
    "doctors",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.locale.LocaleMiddleware",  # must come right after SessionMiddleware
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

DATABASES = {"default": env.db("DATABASE_URL")}
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

AUTH_USER_MODEL = "accounts.User"
AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
        "OPTIONS": {"min_length": 8},
    },
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

# Internationalization (French default, English supported)
USE_I18N = True
LANGUAGE_CODE = "fr"
LANGUAGES = [("fr", "Français"), ("en", "English")]
LOCALE_PATHS = [BASE_DIR / "locale"]
USE_TZ = True
TIME_ZONE = env("APP_TIME_ZONE")

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

# Email: Mailpit in dev/demo (see docker-compose.yml)
EMAIL_HOST = env("EMAIL_HOST")
EMAIL_PORT = env.int("EMAIL_PORT")
EMAIL_USE_TLS = env.bool("EMAIL_USE_TLS")
EMAIL_TIMEOUT = env.int("EMAIL_TIMEOUT")
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL")

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["rest_framework_simplejwt.authentication.JWTAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_PAGINATION_CLASS": "core.pagination.DefaultPagination",
    "DEFAULT_FILTER_BACKENDS": ["django_filters.rest_framework.DjangoFilterBackend"],
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    "EXCEPTION_HANDLER": "core.exceptions.api_exception_handler",
    # Throttles key on REMOTE_ADDR only: X-Forwarded-For is client-controlled (no proxy here).
    "NUM_PROXIES": 0,
    "DEFAULT_THROTTLE_CLASSES": ["rest_framework.throttling.ScopedRateThrottle"],
    "DEFAULT_THROTTLE_RATES": {
        "auth_login": env("THROTTLE_LOGIN"),
        "auth_register": env("THROTTLE_REGISTER"),
        "password_reset": env("THROTTLE_PASSWORD_RESET"),
        "password_reset_confirm": env("THROTTLE_PASSWORD_RESET_CONFIRM"),
    },
}

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=env.int("JWT_ACCESS_MINUTES")),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=env.int("JWT_REFRESH_DAYS")),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
    "UPDATE_LAST_LOGIN": True,
    # Access tokens carry a hash of the password: changing it revokes them at once.
    "CHECK_REVOKE_TOKEN": True,
    "AUTH_HEADER_TYPES": ("Bearer",),
}

# Swagger UI / ReDoc files are served locally (sidecar), so /api/docs/ works offline.
SPECTACULAR_SETTINGS = {
    "TITLE": "Medical Appointments API",
    "VERSION": "1.0.0",
    "SERVE_INCLUDE_SCHEMA": False,
    "SWAGGER_UI_DIST": "SIDECAR",
    "SWAGGER_UI_FAVICON_HREF": "SIDECAR",
    "REDOC_DIST": "SIDECAR",
}

# Password codes (reset and doctor invite)
PASSWORD_RESET_CODE_TTL_MINUTES = env.int("PASSWORD_RESET_CODE_TTL_MINUTES")
PASSWORD_INVITE_CODE_TTL_HOURS = env.int("PASSWORD_INVITE_CODE_TTL_HOURS")
PASSWORD_CODE_MAX_ATTEMPTS = 5
# Failed code attempts per account over 24 h, across all its codes. At the limit even a
# correct code is refused and no new reset code is sent until the window passes.
RESET_MAX_FAILED_ATTEMPTS_PER_DAY = env.int("RESET_MAX_FAILED_ATTEMPTS_PER_DAY")

# Used only by `manage.py seed_demo`; empty means "not configured" (the command refuses).
SEED_DEMO_PASSWORD = env("SEED_DEMO_PASSWORD", default="")

# One line per sensitive action (logger "accounts.audit"). Never log passwords, codes or tokens.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"plain": {"format": "%(asctime)s %(levelname)s %(name)s %(message)s"}},
    "handlers": {"console": {"class": "logging.StreamHandler", "formatter": "plain"}},
    "loggers": {"accounts.audit": {"handlers": ["console"], "level": "INFO"}},
}
