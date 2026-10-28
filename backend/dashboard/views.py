from drf_spectacular.utils import extend_schema
from rest_framework.response import Response
from rest_framework.views import APIView

from accounts.permissions import IsAdmin

from . import services
from .serializers import StatsSerializer


class StatsView(APIView):
    permission_classes = [IsAdmin]

    @extend_schema(tags=["dashboard"], responses={200: StatsSerializer})
    def get(self, request):
        return Response(StatsSerializer(services.stats()).data)
