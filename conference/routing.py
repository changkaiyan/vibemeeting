from django.urls import re_path

from conference.consumers import MeetingRealtimeAudioIngressConsumer


websocket_urlpatterns = [
    re_path(
        r"^ws/meetings/(?P<meeting_id>\d+)/ai-controls/realtime-audio/?$",
        MeetingRealtimeAudioIngressConsumer.as_asgi(),
    ),
    re_path(
        r"^ws/my/meetings/(?P<meeting_ref>[^/]+)/ai-controls/realtime-audio/?$",
        MeetingRealtimeAudioIngressConsumer.as_asgi(),
    ),
]

