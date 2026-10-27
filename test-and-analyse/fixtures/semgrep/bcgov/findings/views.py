import os
from django.utils.safestring import mark_safe

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "insecure")  # env fallback


def link(name):
    return mark_safe("<a>" + name + "</a>")  # mark_safe
