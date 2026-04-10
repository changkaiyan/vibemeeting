import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "smart_meeting.settings")

from django.contrib.staticfiles.handlers import ASGIStaticFilesHandler
from django.core.asgi import get_asgi_application

django_asgi_app = ASGIStaticFilesHandler(get_asgi_application())

from conference.speech_to_text.realtime import realtime_stt_application


async def application(scope, receive, send):
    if scope["type"] == "websocket" and scope.get("path", "").startswith("/ws/meetings/"):
        await realtime_stt_application(scope, receive, send)
        return
    await django_asgi_app(scope, receive, send)
