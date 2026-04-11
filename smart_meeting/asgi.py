import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "smart_meeting.settings")

from django.contrib.staticfiles.handlers import ASGIStaticFilesHandler
from django.core.asgi import get_asgi_application

django_asgi_app = ASGIStaticFilesHandler(get_asgi_application())

from conference.realtime_audio_ws import realtime_audio_ws_application
from conference.speech_to_text.realtime import realtime_stt_application


async def application(scope, receive, send):
    if scope["type"] == "websocket":
        path = scope.get("path", "")
        normalized_path = path.rstrip("/") or path
        if normalized_path.startswith("/ws/meetings/") and normalized_path.endswith("/stt"):
            await realtime_stt_application(scope, receive, send)
            return
        if normalized_path.startswith("/ws/meetings/") or normalized_path.startswith("/ws/my/meetings/"):
            await realtime_audio_ws_application(scope, receive, send)
            return
        await send({"type": "websocket.close", "code": 1008})
        return
    await django_asgi_app(scope, receive, send)
