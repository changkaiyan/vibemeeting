import os
import asyncio
import sys

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "smart_meeting.settings")

from django.contrib.staticfiles.handlers import ASGIStaticFilesHandler
from django.core.asgi import get_asgi_application

django_asgi_app = ASGIStaticFilesHandler(get_asgi_application())

from conference.realtime_audio_ws import realtime_audio_ws_application
from conference.speech_to_text.realtime import realtime_stt_application

_loop_exception_filter_installed = False


def _install_windows_connection_reset_filter() -> None:
    global _loop_exception_filter_installed
    if _loop_exception_filter_installed:
        return
    if sys.platform != "win32":
        _loop_exception_filter_installed = True
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    default_handler = loop.get_exception_handler()

    def _handler(current_loop, context):
        exc = context.get("exception")
        message = str(context.get("message") or "")
        if isinstance(exc, ConnectionResetError) and "_ProactorBasePipeTransport._call_connection_lost" in message:
            return
        if default_handler is not None:
            default_handler(current_loop, context)
        else:
            current_loop.default_exception_handler(context)

    loop.set_exception_handler(_handler)
    _loop_exception_filter_installed = True


async def application(scope, receive, send):
    _install_windows_connection_reset_filter()
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
