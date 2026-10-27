import os
from django.utils.html import format_html

SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
DEBUG = os.environ.get("DEBUG", "false")


def link(name):
    return format_html("<a>{}</a>", name)
