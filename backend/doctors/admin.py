from django.contrib import admin

from .models import DoctorProfile, Specialty, TimeOff, WeeklyAvailability

admin.site.register(Specialty)
admin.site.register(DoctorProfile)
admin.site.register(WeeklyAvailability)
admin.site.register(TimeOff)
