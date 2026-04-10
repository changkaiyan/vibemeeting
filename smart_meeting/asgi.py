import os

from django.core.asgi import get_asgi_application

from conference.speech_to_text.realtime import realtime_stt_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "smart_meeting.settings")

django_asgi_app = get_asgi_application()


async def application(scope, receive, send):
    if scope["type"] == "websocket" and scope.get("path", "").startswith("/ws/meetings/"):
        await realtime_stt_application(scope, receive, send)
        return
    await django_asgi_app(scope, receive, send)
