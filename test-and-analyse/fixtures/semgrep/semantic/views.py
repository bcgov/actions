import os

JWT_SECRET = os.environ.get("JWT_SECRET", "dev-secret")


class PublicOrdersViewSet:
    permission_classes = [AllowAny]

    def create(self, request):
        return None
