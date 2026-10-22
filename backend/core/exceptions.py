"""One error shape for the whole API (TEAM_PLAN 4.3).

    {"error": {"code": "...", "message": "...", "fields": {"email": [{"code", "message"}]}}}

Never build this by hand: raise a DRF exception or `BusinessError` and let the handler
format it. The mobile app translates by `code`; `message` is only a fallback.
"""

from django.core.exceptions import PermissionDenied as DjangoPermissionDenied
from django.http import Http404
from django.utils.translation import gettext as _
from rest_framework.exceptions import APIException, NotFound, PermissionDenied, ValidationError
from rest_framework.views import exception_handler


class BusinessError(APIException):
    """A rule of the domain was broken, e.g. BusinessError("slot_taken", _("..."), 409)."""

    def __init__(self, code: str, message: str, status_code: int = 400):
        super().__init__(detail=message, code=code)
        self.status_code = status_code


def _is_leaf(details) -> bool:
    return isinstance(details, dict) and set(details) == {"message", "code"}


def _normalize(details):
    """Make every field value a list of {message, code}; nested serializers stay nested."""
    if _is_leaf(details):
        return [details]
    if isinstance(details, dict):
        return {key: _normalize(value) for key, value in details.items()}
    return [item if _is_leaf(item) else _normalize(item) for item in details]


def _validation_fields(exc: ValidationError) -> dict:
    fields = _normalize(exc.get_full_details())
    if isinstance(fields, list):  # e.g. raise ValidationError("...") in a view
        return {"non_field_errors": fields}
    return fields


def _code_and_message(exc: APIException) -> tuple[str, str]:
    detail = exc.detail
    if isinstance(detail, dict):
        # simplejwt's InvalidToken: {"detail": "...", "code": "token_not_valid", "messages": [...]}
        return str(detail.get("code", exc.default_code)), str(detail.get("detail", ""))
    code = exc.get_codes()
    return (code if isinstance(code, str) else exc.default_code), str(detail)


def api_exception_handler(exc, context):
    if isinstance(exc, Http404):
        exc = NotFound()
    elif isinstance(exc, DjangoPermissionDenied):
        exc = PermissionDenied()

    response = exception_handler(exc, context)
    if response is None:
        return None  # unexpected error: Django answers 500, nothing is leaked

    if isinstance(exc, ValidationError):
        code, message, fields = "validation_error", _("Invalid input."), _validation_fields(exc)
    else:
        (code, message), fields = _code_and_message(exc), {}
    response.data = {"error": {"code": code, "message": str(message), "fields": fields}}
    return response
