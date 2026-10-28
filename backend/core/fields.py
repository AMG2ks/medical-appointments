from rest_framework import serializers


class SafeDateTimeField(serializers.DateTimeField):
    """DRF raises OverflowError (a 500) on naive year-1 / year-9999 values: make it `invalid`."""

    def enforce_timezone(self, value):
        try:
            return super().enforce_timezone(value)
        except OverflowError:
            self.fail("invalid", format="ISO 8601")
